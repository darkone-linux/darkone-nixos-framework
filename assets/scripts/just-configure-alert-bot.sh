#!/usr/bin/env bash
#
# Idempotent provisioning of the Matrix alert bot + rooms for DNF alerting.
#
# Run via `just configure-alert-bot` (which sets WORKDIR and fixes fs perms).
# Re-running is safe: each step checks current state before acting.
#  - bot account      : created once via the registration shared secret;
#                       password + access token kept in sops.
#  - access token     : reused while valid (whoami), re-issued by login else.
#  - webhook secret    : generated once, kept in sops.
#  - rooms            : resolved by alias, created only if missing; the bot
#                       (their creator) is a member, the human admin is invited.
#  - bot + room IDs   : written to var/generated/matrix.nix (NOT config.yaml,
#                       which stays manual-only). Merged into network.matrix.*
#                       by dnf/lib/mk-configuration.nix.
#
# Source of truth: etc/config.yaml `network.matrix.admin` and `network.domain`
# (manual). The bot local part defaults to `alertbot` (override with ALERT_BOT).
# The Matrix host is read from the generated network. Client API calls go to
# https://matrix.<domain>; the admin-only registration endpoint falls back to an
# SSH tunnel (as the nix deploy user) when it is not exposed publicly.

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
admin="$(yq -r '.network.matrix.admin // ""' "$cfg")"
bot="${ALERT_BOT:-alertbot}"
[ -n "$domain" ] && [ "$domain" != "null" ] || die "network.domain missing in config.yaml."
[ -n "$admin" ] || die "Set network.matrix.admin (your local part) in config.yaml."

BOT_USER="@${bot}:${domain}"
HUMAN="@${admin}:${domain}"
PUBLIC_HS="https://matrix.${domain}"

matrixHost="$(nix eval --impure --raw --extra-experimental-features 'nix-command flakes' --expr \
  "let n = import $workDir/var/generated/network.nix; s = builtins.filter (x: x.name == \"matrix\") n.services; in if s == [ ] then \"\" else (builtins.head s).host" \
  2>/dev/null || true)"

log "Domain=$domain  bot=$BOT_USER  admin=$HUMAN  matrixHost=${matrixHost:-?}"

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

login_token() {
  mx -fsS -XPOST "$PUBLIC_HS/_matrix/client/v3/login" -H 'Content-Type: application/json' \
    -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"$bot\"},\"password\":\"$1\"}" \
    | jq -r '.access_token // empty'
}

# Register the bot via the nonce + HMAC shared-secret flow; echoes the token
# the admin register endpoint returns. Opens an SSH tunnel to the Matrix host
# when /_synapse/admin is not reachable publicly.
register_token() {
  local pass="$1" shared admin_hs nonce mac resp tunnel=""
  shared="$(sops_get matrix-rss-password)"
  [ -n "$shared" ] || die "registration shared secret (matrix-rss-password) missing in sops."

  admin_hs="$PUBLIC_HS"
  if ! mx -fsS -o /dev/null "$PUBLIC_HS/_synapse/admin/v1/register" 2>/dev/null; then
    [ -n "$matrixHost" ] || die "admin API not public and Matrix host unknown — cannot tunnel."
    log "Admin API not public: opening SSH tunnel to $matrixHost (as nix)..."
    sudo -i -u nix ssh -fN -o ExitOnForwardFailure=yes -L 18008:localhost:8008 "nix@${matrixHost}"
    tunnel="nix@${matrixHost}"
    admin_hs="http://localhost:18008"
  fi

  nonce="$(mx -fsS "$admin_hs/_synapse/admin/v1/register" | jq -r .nonce)"
  mac="$(printf '%s\0%s\0%s\0notadmin' "$nonce" "$bot" "$pass" \
    | openssl dgst -sha1 -hmac "$shared" | awk '{print $NF}')"
  resp="$(mx -sS -XPOST "$admin_hs/_synapse/admin/v1/register" -H 'Content-Type: application/json' \
    -d "{\"nonce\":\"$nonce\",\"username\":\"$bot\",\"displayname\":\"Alertes\",\"password\":\"$pass\",\"admin\":false,\"mac\":\"$mac\"}" || true)"

  [ -n "$tunnel" ] && sudo -i -u nix pkill -f '18008:localhost:8008' 2>/dev/null || true

  if printf '%s' "$resp" | grep -q M_USER_IN_USE; then
    die "Bot $BOT_USER already exists but no password is stored. Reset it or add alertmanager-matrix-password to sops."
  fi
  printf '%s' "$resp" | jq -r '.access_token // empty'
}

# --- 1. Bot credentials (idempotent) ---------------------------------------
TOKEN="$(sops_get alertmanager-matrix-token)"
PASS="$(sops_get alertmanager-matrix-password)"

if [ -z "$PASS" ]; then
  log "Creating bot account $BOT_USER..."
  PASS="$(openssl rand -hex 24)"
  TOKEN="$(register_token "$PASS")"
  [ -n "$TOKEN" ] || die "bot registration failed."
  sops_set alertmanager-matrix-password "$PASS"
  sops_set alertmanager-matrix-token "$TOKEN"
  log "Bot created, password + token stored in sops."
elif token_valid; then
  log "Existing bot token still valid — keeping it."
else
  log "Bot token missing/invalid — logging in to refresh..."
  TOKEN="$(login_token "$PASS")"
  [ -n "$TOKEN" ] || die "login failed (wrong stored password?)."
  sops_set alertmanager-matrix-token "$TOKEN"
  log "Token refreshed."
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

# Invite the human admin (tolerant: already-invited/joined returns an error).
for R in "$WARN_ID" "$INC_ID"; do
  mx -fsS -XPOST "$PUBLIC_HS/_matrix/client/v3/rooms/$R/invite" -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -d "{\"user_id\":\"$HUMAN\"}" >/dev/null 2>&1 || true
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
