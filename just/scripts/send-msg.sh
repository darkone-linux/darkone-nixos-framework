#!/usr/bin/env bash
#
# DNF — sends one message to a Matrix alert room, body read on stdin (markdown).
#
# Run via `just send-msg <room>`, which sets WORKDIR. Transport only: the caller
# owns the text. Rooms and bot come from `var/generated/matrix.nix`
# (`just configure-alert-bot`), the domain from `var/generated/network.nix`.
#
# The sops age keys belong to the deploy user `nix` (`just configure-admin-host`
# creates the admin key in its home), so the token is read through it, as
# `just sops` does.
#
# Exit codes, a contract with the callers (fleet-update `--send-report`):
#   0   sent
#   10  not configured here: no room, no token, missing program
#   11  the homeserver refused the message

set -euo pipefail

workDir="${WORKDIR:-$PWD}"
room="${1:-}"
secrets="$workDir/usr/secrets/secrets.yaml"
generated="$workDir/var/generated"

log() { printf '[ \033[36mDNF\033[0m ] \033[35mMTX\033[0m • %s\n' "$*" >&2; }
fail() { printf '[ \033[36mDNF\033[0m ] \033[31mMTX\033[0m • %s\n' "$*" >&2; exit "${2:-10}"; }

case "$room" in
  warnings | incidents) ;;
  *) fail "usage: just send-msg [warnings|incidents] < message.md" ;;
esac

for bin in curl jq nix sudo; do
  command -v "$bin" >/dev/null 2>&1 || fail "missing dependency: $bin."
done
[ -f "$secrets" ] || fail "secrets file not found ($secrets)."
[ -f "$generated/matrix.nix" ] || fail "no matrix.nix — run 'just configure-alert-bot' first."

# The public vhost runs Caddy's bad-bots filter, which 403s a `curl` agent.
UA="DNF-Alerts"

nixEval() { nix eval --impure --raw --extra-experimental-features 'nix-command flakes' --expr "$1"; }

roomId="$(nixEval "(import $generated/matrix.nix).matrix.${room}Room" 2>/dev/null || true)"
[ -n "$roomId" ] || fail "no $room room in matrix.nix — run 'just configure-alert-bot'."
domain="$(nixEval "(import $generated/network.nix).domain" 2>/dev/null || true)"
[ -n "$domain" ] || fail "network.domain not found — run 'just generate'."

body="$(cat)"
[ -n "$body" ] || fail "empty message on stdin."

# Deploy identity: the age keys are readable by `nix` only.
token="$(sudo -n -u nix -H -- /bin/sh -lc 'exec "$0" "$@"' \
  sops -d --extract "[\"alertmanager-matrix-token\"]" "$secrets" 2>/dev/null || true)"
[ -n "$token" ] || fail "alertmanager-matrix-token not readable (sops, deploy user nix)."

# Transaction id: a retried PUT does not post the message twice.
txn="$(date +%s%N)-$$"
encoded="$(jq -rn --arg id "$roomId" '$id|@uri')"
url="https://matrix.$domain/_matrix/client/v3/rooms/$encoded/send/m.room.message/$txn"

# A client renders `formatted_body`, never `body`: without it the markdown is
# shown verbatim. Subset built here: headings, bullets, bold, code, links.
# No italics on purpose: a lone `*` is a host glob (`gw-*, srv-*`).
#
# shellcheck disable=SC2016 # $body is a jq variable, bound by --arg
toHtml='
def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
def inline:
  esc
  | gsub("`(?<t>[^`]+)`"; "<code>\(.t)</code>")
  | gsub("\\[(?<t>[^\\]]*)\\]\\((?<u>[^)\\s]+)\\)"; "<a href=\"\(.u)\">\(.t)</a>")
  | gsub("\\*\\*(?<t>[^*]+)\\*\\*"; "<strong>\(.t)</strong>");
def html:
  split("\n")
  | map(sub("\\s+$"; ""))
  | reduce .[] as $l ({ out: [], li: false };
      ([$l | capture("^(?<h>#{1,6}) +(?<t>.+)$")] | first) as $head
      | ([$l | capture("^[-*] +(?<t>.+)$")] | first) as $item
      | if $item then
          { out: (.out + (if .li then [] else ["<ul>"] end) + ["<li>\($item.t | inline)</li>"]),
            li: true }
        else
          (if .li then { out: (.out + ["</ul>"]), li: false } else . end)
          | if $head then (($head.h | length) | tostring) as $n
              | .out += ["<h\($n)>\($head.t | inline)</h\($n)>"]
            elif $l == "" then .
            else .out += ["<p>\($l | inline)</p>"]
            end
        end)
  | (if .li then .out + ["</ul>"] else .out end)
  | join("");
{ msgtype: "m.text", body: $body,
  format: "org.matrix.custom.html", formatted_body: ($body | html) }
'

code="$(jq -n --arg body "$body" "$toHtml" \
  | curl -sS -A "$UA" -o /dev/null -w '%{http_code}' -X PUT "$url" \
      -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
      --data-binary @- || true)"

case "$code" in
  2??) log "message sent to the $room room." ;;
  *) fail "homeserver refused the message (HTTP ${code:-none})." 11 ;;
esac
