#!/usr/bin/env bash
#
# Idempotent provisioning of the Matrix bot of an AI space (OpenClaw channel).
#
# Last step of `just space-init <host>` on an openclaw space, as `nix` with the
# admin age key. Same MAS flow as `configure-alert-bot.sh`, without rooms
# (members talk to it in DM). No Matrix on the network: skipped, not an error.
#  - bot account  : `@<host>:<domain>`, created once (`dnf-mas register-user`);
#  - access token : reused while valid (whoami), else re-issued
#                   (`dnf-mas issue-compatibility-token`); kept in the space's
#                   own sops file (`usr/secrets/hosts/<host>.yaml`);
#  - profile      : display name and avatar of `identity`
#                   (`darkone.service.openclaw.matrixProfile`), the avatar
#                   uploaded once per source;
#  - marker       : `var/generated/spaces/<host>.nix`, which turns the
#                   OpenClaw Matrix channel on at the next deploy, with the
#                   avatar's `mxc://` URI the gateway re-applies.

set -euo pipefail

workDir="${WORKDIR:?}"
host="${SPACE_HOST:?}"
cfg="$workDir/etc/config.yaml"
secrets="$workDir/usr/secrets/hosts/$host.yaml"

log() { printf '[ \033[36mMTX\033[0m ] %s\n' "$*" >&2; }
die() { printf '[ \033[31mMTX\033[0m ] %s\n' "$*" >&2; exit 1; }

# The public Matrix vhost 403s `curl` and empty User-Agents (bad-bots filter).
UA="DNF-Setup"
mx() { curl -A "$UA" "$@"; }

[ -f "$secrets" ] || die "No secrets file for $host: run 'just space-init $host' first."
for bin in yq jq curl sops nix ssh; do
  command -v "$bin" >/dev/null 2>&1 || die "missing dependency: $bin (enter 'nix develop')."
done

domain="$(yq -r '.network.domain' "$cfg")"
[ -n "$domain" ] && [ "$domain" != "null" ] || die "network.domain missing in config.yaml."
bot="$host"
BOT_USER="@${bot}:${domain}"
PUBLIC_HS="https://matrix.${domain}"

# `just generate` output: the matrix host.
gen() {
  nix eval --impure --raw --extra-experimental-features 'nix-command flakes' --expr "$1" 2>/dev/null || true
}
matrixHost="$(gen "let s = builtins.filter (x: x.name == \"matrix\") (import $workDir/var/generated/network.nix).services; in if s == [ ] then \"\" else (builtins.head s).host")"
marker="$workDir/var/generated/spaces/$host.nix"
if [ -z "$matrixHost" ] ;then
  log "No matrix service on the network: no bot for $host."
  [ ! -f "$marker" ] || log "Stale marker $marker ignored by the deploy: delete it (and openclaw-matrix-token with 'just space-sops $host')."
  exit 0
fi
profileAttr="$workDir#nixosConfigurations.$host.config.darkone.service.openclaw.matrixProfile"
profile="$(nix eval --json "$profileAttr")" || die "cannot evaluate the Matrix profile of $host."
displayName="$(jq -r .displayName <<<"$profile")"

log "Space=$host  bot=$BOT_USER  matrixHost=$matrixHost"

sops_get() { sops -d --extract "[\"$1\"]" "$secrets" 2>/dev/null || true; }
sops_set() { sops set "$secrets" "[\"$1\"]" "\"$2\""; }

token_valid() {
  [ -n "${TOKEN:-}" ] || return 1
  mx -fsS "$PUBLIC_HS/_matrix/client/v3/account/whoami" -H "Authorization: Bearer $TOKEN" 2>/dev/null \
    | jq -e --arg u "$BOT_USER" '.user_id == $u' >/dev/null 2>&1
}

# `dnf-mas` is root-only on the matrix host: one ssh round-trip per call.
mas_remote() {
  ssh -o BatchMode=yes "nix@${matrixHost}" "sudo dnf-mas $1" 2>&1
}

# --- 1. Bot account and token ----------------------------------------------
TOKEN="$(sops_get openclaw-matrix-token)"
if token_valid; then
  log "Existing bot token still valid — keeping it."
else
  log "Bot token missing/invalid — provisioning..."
  out="$(mas_remote "manage register-user --yes --display-name $(printf '%q' "$displayName") $bot")" || true
  case "$out" in
    *"User registered"*) log "Bot account $BOT_USER created." ;;
    *"already exists"*)  log "Bot account $BOT_USER already present." ;;
    *) die "bot registration failed: $out" ;;
  esac

  # A tracing log line (timestamp, level, maybe ANSI colours), not a bare
  # print: match the message anywhere, keep the first word after it.
  out="$(mas_remote "manage issue-compatibility-token $bot")" || true
  TOKEN="$(printf '%s\n' "$out" | sed -e 's/\x1b\[[0-9;]*m//g' \
    -n -e 's/.*Compatibility token issued: \([^[:space:]]*\).*/\1/p' | head -n 1)"
  [ -n "$TOKEN" ] || die "could not issue a compatibility token for $BOT_USER: $out"
  sops_set openclaw-matrix-token "$TOKEN"
  log "Token issued and stored in usr/secrets/hosts/$host.yaml."
fi

# --- 2. Profile: display name and avatar ------------------------------------
# Also re-applied by the gateway at each start; set here for an immediate
# effect. A PUT is skipped when unchanged: each one notifies every DM.
tmp="$(mktemp)"
img="$(mktemp)"
trap 'rm -f "$tmp" "$img"' EXIT
profileUrl="$PUBLIC_HS/_matrix/client/v3/profile/$(jq -rn --arg u "$BOT_USER" '$u | @uri')"
current="$(mx -fsS -H "Authorization: Bearer $TOKEN" "$profileUrl" 2>/dev/null || echo '{}')"
put_profile() {
  mx -fsS -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    "$profileUrl/$1" -d "$(jq -cn --arg k "$1" --arg v "$2" '{($k): $v}')" >/dev/null \
    || die "cannot set the $1 of $BOT_USER."
}

if [ "$(jq -r '.displayname // empty' <<<"$current")" != "$displayName" ]; then
  put_profile displayname "$displayName"
  log "Display name: $displayName."
fi

# Avatar uploaded once per source (`avatarSource`), its `mxc://` kept in the
# marker.
avatarSource="$(jq -r '.avatarSource // empty' <<<"$profile")"
prev="$(gen "if builtins.pathExists $marker then builtins.toJSON ((import $marker).matrixAvatar or null) else \"null\"")"
[ -n "$prev" ] || prev=null
avatarUrl=""
if [ -n "$avatarSource" ] && [ "$(jq -r '.source // empty' <<<"$prev")" = "$avatarSource" ]; then
  avatarUrl="$(jq -r .url <<<"$prev")"
elif [ -n "$avatarSource" ]; then
  if [ -n "$(jq -r '.avatarFile // empty' <<<"$profile")" ]; then
    file="$(nix build --no-link --print-out-paths "$profileAttr.avatarFile")" \
      || die "cannot build the avatar of $host."
    mime="$(jq -r .avatarMime <<<"$profile")"
  else
    mime="$(mx -fsSL --max-filesize 10485760 -o "$img" -w '%{content_type}' "$(jq -r .avatarUrl <<<"$profile")")" \
      || die "cannot download the avatar of $host."
    file="$img"
    mime="${mime%%;*}"
  fi
  case "$mime" in
    image/png | image/jpeg | image/gif | image/webp) ;;
    *) die "avatar of $host: png, jpg, gif or webp expected, got '$mime'." ;;
  esac
  [ "$(stat -c %s "$file")" -le 10485760 ] || die "avatar of $host: over 10 MB."
  avatarUrl="$(mx -fsS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: $mime" \
    --data-binary @"$file" "$PUBLIC_HS/_matrix/media/v3/upload?filename=avatar" \
    | jq -r '.content_uri // empty')" || true
  [ -n "$avatarUrl" ] || die "avatar upload failed for $BOT_USER."
  log "Avatar uploaded: $avatarUrl."
fi

# No avatar declared: cleared only when this script had set one.
if [ "$(jq -r '.avatar_url // empty' <<<"$current")" != "$avatarUrl" ] \
  && { [ -n "$avatarUrl" ] || [ "$prev" != null ]; }; then
  put_profile avatar_url "$avatarUrl"
  log "Avatar: ${avatarUrl:-cleared}."
fi

# --- 3. Marker: enables the OpenClaw Matrix channel -------------------------
# `var/generated` belongs to the workspace owner, not to `nix`: written with
# sudo, ownership restored by the recipe (`_fix_fs_permissions`). Already in
# nixfmt shape: `just clean` leaves it untouched.
# Nix string literal: `\`, `"` and `${` escaped.
nixStr() {
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "${s//\$\{/\\\$\{}"
}
if [ -n "$avatarUrl" ]; then
  body="{
  matrixBot = $(nixStr "$bot");
  matrixAvatar = {
    source = $(nixStr "$avatarSource");
    url = $(nixStr "$avatarUrl");
  };
}"
else
  body="{ matrixBot = $(nixStr "$bot"); }"
fi
cat > "$tmp" <<EOF
# Generated by \`just space-init $host\` — do not edit by hand.
# Read by dnf/modules/service/openclaw.nix: enables the Matrix channel.
$body
EOF
sudo install -D -m 644 "$tmp" "$marker"
log "$BOT_USER ready."
