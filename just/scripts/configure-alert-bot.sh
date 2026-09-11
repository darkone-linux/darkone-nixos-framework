#!/usr/bin/env bash
#
# Idempotent provisioning of the Matrix alert bot + rooms for DNF alerting.
#
# Run via `just configure-alert-bot` (which sets WORKDIR and fixes fs perms).
# Re-running is safe: each step checks current state before acting.
#  - bot account      : created once with `dnf-mas manage register-user`.
#  - access token     : reused while valid (whoami), re-issued otherwise with
#                       `dnf-mas manage issue-compatibility-token`; kept in sops.
#  - webhook secret   : generated once, kept in sops.
#  - rooms            : resolved by alias, created only if missing; the bot
#                       (their creator) is a member, the admins are invited.
#  - bot + room IDs   : written to var/generated/matrix.nix (NOT config.yaml,
#                       which stays manual-only). Merged into network.matrix.*
#                       by dnf/lib/mk-configuration.nix.
#
# Source of truth: etc/config.yaml `network.matrix.admins` and `network.domain`
# (manual). The bot local part defaults to `alertbot` (override with ALERT_BOT).
# The Matrix host is read from the generated network. Client API calls go to
# https://matrix.<domain>.
#
# The bot has no password: auth is delegated to MAS, whose account lifecycle
# lives on the host (`dnf-mas`, root-only, reads the sops secrets from
# systemd credentials). Every account operation is therefore an ssh call as
# the `nix` deploy user, like `just hardware-config` does.

set -euo pipefail

workDir="${WORKDIR:-$PWD}"
cfg="$workDir/etc/config.yaml"
secrets="$workDir/usr/secrets/secrets.yaml"

log() { printf '[ \033[36mMTX\033[0m ] %s\n' "$*" >&2; }
die() { printf '[ \033[31mMTX\033[0m ] %s\n' "$*" >&2; exit 1; }

# The public Matrix vhost runs Caddy's bad-bots filter, which 403s a `curl`
# User-Agent (and empty/bot-like ones). Use a neutral UA for every request so
# client calls through the reverse proxy are not rejected.
UA="DNF-Setup"
mx() { curl -A "$UA" "$@"; }

[ -f "$cfg" ] || die "config.yaml not found ($cfg)."
[ -f "$secrets" ] || die "secrets file not found ($secrets) — run 'just configure-admin-host' first."
for bin in yq jq curl openssl sops nix; do
  command -v "$bin" >/dev/null 2>&1 || die "missing dependency: $bin (enter 'nix develop')."
done

# Admin age key auto-discovered by sops; set it explicitly when present so the
# script works regardless of the caller's environment.
adminKey="$HOME/.config/sops/age/keys.txt"
[ -f "$adminKey" ] && export SOPS_AGE_KEY_FILE="$adminKey"

# --- auto-detected variables ------------------------------------------------
domain="$(yq -r '.network.domain' "$cfg")"
bot="${ALERT_BOT:-alertbot}"
[ -n "$domain" ] && [ "$domain" != "null" ] || die "network.domain missing in config.yaml."

mapfile -t ADMINS < <(yq -r '.network.matrix.admins[]? // empty' "$cfg")
[ "${#ADMINS[@]}" -gt 0 ] || die "Set network.matrix.admins (local parts) in config.yaml."

BOT_USER="@${bot}:${domain}"
PUBLIC_HS="https://matrix.${domain}"

matrixHost="$(nix eval --impure --raw --extra-experimental-features 'nix-command flakes' --expr \
  "let n = import $workDir/var/generated/network.nix; s = builtins.filter (x: x.name == \"matrix\") n.services; in if s == [ ] then \"\" else (builtins.head s).host" \
  2>/dev/null || true)"

[ -n "$matrixHost" ] || die "matrix service not found in var/generated/network.nix — run 'just generate'."

log "Domain=$domain  bot=$BOT_USER  admins=${ADMINS[*]}  matrixHost=$matrixHost"

# --- sops helpers (admin key) ----------------------------------------------
sops_get() { sops -d --extract "[\"$1\"]" "$secrets" 2>/dev/null || true; }
sops_set() { sops set "$secrets" "[\"$1\"]" "\"$2\""; }

# --- HTTP helpers -----------------------------------------------------------
# whoami: true when $TOKEN is a valid session for the bot.
token_valid() {
  [ -n "${TOKEN:-}" ] || return 1
  mx -fsS "$PUBLIC_HS/_matrix/client/v3/account/whoami" -H "Authorization: Bearer $TOKEN" 2>/dev/null \
    | jq -e --arg u "$BOT_USER" '.user_id == $u' >/dev/null 2>&1
}

# --- MAS host helpers -------------------------------------------------------
# `dnf-mas` is root-only on the matrix host (cf. header). One ssh round-trip
# per call; `$1` is the argument string, already shell-safe (local parts).
mas_remote() {
  sudo -i -u nix ssh -o BatchMode=yes "nix@${matrixHost}" "sudo dnf-mas $1" 2>&1
}

# register-user is not idempotent: an existing account is the nominal
# re-run case, not a failure.
ensure_bot_account() {
  local out
  out="$(mas_remote "manage register-user --yes --display-name Alertes $bot")" || true
  case "$out" in
    *"User registered"*) log "Bot account $BOT_USER created." ;;
    *"already exists"*)  log "Bot account $BOT_USER already present." ;;
    *) die "bot registration failed: $out" ;;
  esac
}

# Compatibility token: what a legacy client API call expects, and the only
# credential the bot ever holds. Random device id, so re-issuing never
# invalidates a session still in use.
issue_token() {
  mas_remote "manage issue-compatibility-token $bot" \
    | sed -n 's/^Compatibility token issued: //p' | tr -d '[:space:]'
}

# --- 1. Bot credentials (idempotent) ---------------------------------------
TOKEN="$(sops_get alertmanager-matrix-token)"

if token_valid; then
  log "Existing bot token still valid — keeping it."
else
  log "Bot token missing/invalid — provisioning..."
  ensure_bot_account
  TOKEN="$(issue_token)"
  [ -n "$TOKEN" ] || die "could not issue a compatibility token for $BOT_USER."
  sops_set alertmanager-matrix-token "$TOKEN"
  log "Token issued and stored in sops."
fi

# --- 2. Webhook secret (idempotent) ----------------------------------------
if [ -z "$(sops_get alertmanager-webhook-secret)" ]; then
  log "Generating Alertmanager webhook secret..."
  sops_set alertmanager-webhook-secret "$(openssl rand -hex 32)"
else
  log "Webhook secret already present."
fi

# --- 3. Rooms (idempotent via alias) ---------------------------------------
ensure_room() { # $1 alias local part, $2 display name -> echoes room_id
  local alias="$1" name="$2" enc rid
  enc="%23${alias}:${domain}"
  rid="$(mx -fsS "$PUBLIC_HS/_matrix/client/v3/directory/room/$enc" -H "Authorization: Bearer $TOKEN" 2>/dev/null \
    | jq -r '.room_id // empty')"
  if [ -z "$rid" ]; then
    rid="$(mx -fsS -XPOST "$PUBLIC_HS/_matrix/client/v3/createRoom" -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' \
      -d "{\"room_alias_name\":\"$alias\",\"name\":\"$name\",\"preset\":\"private_chat\",\"visibility\":\"private\"}" \
      | jq -r '.room_id // empty')"
  fi
  # Join (no-op if already a member) so the bot can always post.
  [ -n "$rid" ] && mx -fsS -XPOST "$PUBLIC_HS/_matrix/client/v3/join/$rid" \
    -H "Authorization: Bearer $TOKEN" -d '{}' >/dev/null 2>&1 || true
  printf '%s' "$rid"
}

log "Ensuring rooms..."
WARN_ID="$(ensure_room alert-warnings 'Alertes — warnings')"
INC_ID="$(ensure_room alert-incidents 'Alertes — incidents')"
[ -n "$WARN_ID" ] && [ -n "$INC_ID" ] || die "room creation/resolution failed."
log "warnings  = $WARN_ID"
log "incidents = $INC_ID"

# Invite every declared admin (tolerant: already-invited/joined errors out).
for R in "$WARN_ID" "$INC_ID"; do
  for A in "${ADMINS[@]}"; do
    mx -fsS -XPOST "$PUBLIC_HS/_matrix/client/v3/rooms/$R/invite" -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' -d "{\"user_id\":\"@${A}:${domain}\"}" >/dev/null 2>&1 || true
  done
done

# --- 4. Persist bot + room IDs into var/generated/matrix.nix ----------------
# Kept out of config.yaml (manual-only); merged into network.matrix.* by
# dnf/lib/mk-configuration.nix. Atomic write so a partial file is never read.
gen="$workDir/var/generated"
mkdir -p "$gen"
tmp="$(mktemp "$gen/.matrix.XXXXXX")"
cat > "$tmp" <<EOF
# Generated by \`just configure-alert-bot\` — do not edit by hand.
# Merged into \`network.matrix\` by dnf/lib/mk-configuration.nix.
{
  matrix = {
    bot = "${bot}";
    warningsRoom = "${WARN_ID}";
    incidentsRoom = "${INC_ID}";
  };
}
EOF
mv -f "$tmp" "$gen/matrix.nix"
chmod 644 "$gen/matrix.nix"
log "Bot + room IDs written to var/generated/matrix.nix."
log "Done. Alerting auto-enables on the prometheus host (rooms now provisioned)."
log "Run 'just apply <host>' to deploy."
