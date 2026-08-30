# Admin remote desktop: attach to an already open graphical session over RDP.
#
# :::note[Nothing is installed, nothing is exposed]
# `gnome-remote-desktop` already ships and runs on every GNOME host (the
# nixpkgs GNOME module enables it by default); it simply sits idle until its
# RDP backend is turned on. This module adds no daemon and opens no port: it
# installs `dnf-remote-desktop`, a helper the `just remote-desktop` recipe
# calls over ssh to arm a session, then disarm it. The RDP listener binds only
# while a support session runs and is reached exclusively through an ssh
# tunnel — the firewall stays shut.
# :::
#
# :::tip[Two backends, one protocol]
# A GNOME Wayland session is served by `gnome-remote-desktop`, driven through
# `grdctl` inside the session owner's own bus. A Cinnamon X11 session — the
# gaze-driven UMI workstation, since GNOME 50 dropped its Xorg session — is
# served by `freerdp-shadow-cli` on the existing display. Same protocol, same
# client, same `ro`/`rw` semantics enforced server-side.
# :::
#
# :::caution[Attaching is taking over someone's screen]
# The target session belongs to a user who is very likely sitting in front of
# it. GNOME shows a sharing indicator, but nothing asks for consent: this is a
# support tool for machines you administer, and enabling it on a host is a
# deliberate, auditable declaration in `config.yaml`.
# :::
#
# :::tip[Activation]
# A host opts in through its `features` list in `config.yaml`:
# `features: [ "remote-desktop", ... ]`. Unlike `services:`, features are
# inherited by templated host groups (`range:` / `hosts:`), so a whole family
# of identical desktops is covered by one line.
# :::

{
  lib,
  config,
  pkgs,
  host,
  dnfConfig,
  ...
}:
let
  inherit (lib) mkIf mkOption types;

  cfg = config.darkone.graphic.remote-desktop;

  # Not a service: no reverse proxy, no homepage entry, nothing to publish —
  # just a capability switched on per host, which is what `features` is for.
  hasFeature = builtins.hasAttr "remote-desktop" (host.features or { });

  port = dnfConfig.network.ports.remoteDesktop;

  # Transient units armed by `start`, torn down by `stop`. Fixed names: only
  # one support session at a time, which `start` enforces through the state
  # file anyway.
  shadowUnit = "dnf-remote-desktop-shadow";
  timeoutUnit = "dnf-remote-desktop-timeout";

  # /run, so a reboot wipes it: a stale state file would make `stop` try to
  # restore a session that no longer exists.
  stateFile = "/run/dnf-remote-desktop.state";

  awk = "${pkgs.gawk}/bin/awk";
  dconf = "${pkgs.dconf}/bin/dconf";
  env = "${pkgs.coreutils}/bin/env";
  grdctl = "${pkgs.gnome-remote-desktop}/bin/grdctl";
  head = "${pkgs.coreutils}/bin/head";
  hostname = "${pkgs.inetutils}/bin/hostname";
  loginctl = "${pkgs.systemd}/bin/loginctl";
  openssl = "${pkgs.openssl}/bin/openssl";
  rm = "${pkgs.coreutils}/bin/rm";
  runuser = "${pkgs.util-linux}/bin/runuser";
  sed = "${pkgs.gnused}/bin/sed";
  shadow = "${pkgs.freerdp}/bin/freerdp-shadow-cli";
  sleep = "${pkgs.coreutils}/bin/sleep";
  ss = "${pkgs.iproute2}/bin/ss";
  systemctl = "${pkgs.systemd}/bin/systemctl";
  systemdRun = "${pkgs.systemd}/bin/systemd-run";
  tr = "${pkgs.coreutils}/bin/tr";

  remoteDesktopScript = pkgs.writeShellApplication {
    name = "dnf-remote-desktop";

    # Every binary is called through its store path below, so nothing is
    # expected on PATH — including when systemd runs the self-destruct timer.
    runtimeInputs = [ ];

    text = ''
      port=${toString port}
      state=${stateFile}
      timeout=${toString cfg.timeout}
      shadow_unit=${shadowUnit}
      timeout_unit=${timeoutUnit}

      die() {
        echo "dnf-remote-desktop: $*" >&2
        exit 1
      }

      # One variable out of a process environment (NUL separated).
      environ_get() {
        ${tr} '\0' '\n' < "/proc/$1/environ" 2>/dev/null | ${sed} -n "s/^$2=//p" | ${head} -n1
      }

      # Candidate sessions, one id per line.
      #
      # `loginctl list-sessions` carries neither the type nor the active flag
      # (its columns are SESSION UID USER SEAT LEADER CLASS TTY IDLE SINCE),
      # so each session has to be interrogated on its own.
      pick_sessions() {
        local id type class active
        ${loginctl} list-sessions --no-legend | ${awk} '{ print $1 }' | while read -r id ;do
          [ -n "$id" ] || continue
          type=$(${loginctl} show-session "$id" -p Type --value 2>/dev/null || true)
          class=$(${loginctl} show-session "$id" -p Class --value 2>/dev/null || true)
          active=$(${loginctl} show-session "$id" -p Active --value 2>/dev/null || true)
          case "$type" in
            wayland | x11) ;;
            *) continue ;;
          esac
          [ "$class" = user ] || continue
          [ "$active" = yes ] || continue
          echo "$id"
        done
      }

      # Resolve THE session to attach to and export its coordinates.
      load_session() {
        local found count
        found=$(pick_sessions)
        count=$(printf '%s' "$found" | ${awk} 'NF { n++ } END { print n + 0 }')
        [ "$count" != 0 ] || die "no open graphical session on this host"
        [ "$count" = 1 ] || die "several active graphical sessions ($(echo "$found" | ${tr} '\n' ' ')): refusing to guess"

        sid=$(printf '%s\n' "$found" | ${head} -n1)
        s_user=$(${loginctl} show-session "$sid" -p Name --value)
        s_uid=$(${loginctl} show-session "$sid" -p User --value)
        s_type=$(${loginctl} show-session "$sid" -p Type --value)
        s_leader=$(${loginctl} show-session "$sid" -p Leader --value)
        s_runtime="/run/user/$s_uid"

        # The leader's own environment is the source of truth; the usual
        # /run/user/<uid>/bus is only a very good guess.
        s_dbus=$(environ_get "$s_leader" DBUS_SESSION_BUS_ADDRESS)
        [ -n "$s_dbus" ] || s_dbus="unix:path=$s_runtime/bus"
      }

      # Run a command inside the session owner's context.
      #
      # grdctl stores credentials through libsecret, so it must reach that
      # user's keyring and session bus. LC_ALL=C keeps grdctl's output
      # parseable whatever the desktop locale is.
      as_user() {
        ${runuser} -u "$s_user" -- ${env} \
          XDG_RUNTIME_DIR="$s_runtime" \
          DBUS_SESSION_BUS_ADDRESS="$s_dbus" \
          LC_ALL=C \
          "$@"
      }

      state_get() {
        ${sed} -n "s/^$1=//p" "$state" | ${head} -n1
      }

      # Bounded poll: grd takes a moment to bind, and a fixed sleep is either
      # too short on a loaded host or wasted time on an idle one.
      wait_port() {
        local remaining
        remaining=50
        while [ "$remaining" -gt 0 ] ;do
          if ${ss} -H -ltn "sport = :$port" | ${awk} 'NF { found = 1 } END { exit !found }' ;then
            return 0
          fi
          ${sleep} 0.1
          remaining=$((remaining - 1))
        done
        die "the RDP listener never came up on port $port"
      }

      # Credentials without exposing them in argv on the target host: grdctl
      # prompts on stdin when the password argument is omitted. Verified after
      # the fact, because a build that insisted on a tty would store nothing
      # and fail the connection with a confusing error.
      set_credentials() {
        local stored
        printf '%s\n' "$rdp_pass" | as_user ${grdctl} rdp set-credentials "$rdp_user" >/dev/null 2>&1 || true
        stored=$(as_user ${grdctl} status --show-credentials 2>/dev/null | ${sed} -n 's/^[[:space:]]*Password: //p' | ${head} -n1)
        if [ "$stored" != "$rdp_pass" ] ;then
          as_user ${grdctl} rdp set-credentials "$rdp_user" "$rdp_pass" >/dev/null
        fi
      }

      start_gnome() {
        local current

        # Someone enabled screen sharing on purpose: leave it alone. This is
        # also what lets `stop` be a plain `dconf reset` instead of saving and
        # restoring seven keys.
        current=$(as_user ${dconf} read /org/gnome/desktop/remote-desktop/rdp/enable 2>/dev/null || true)
        [ "$current" != "true" ] || die "screen sharing is already enabled on this session; leaving it untouched"

        cert="$s_runtime/dnf-remote-desktop.crt"
        key="$s_runtime/dnf-remote-desktop.key"

        # Ephemeral and self-signed: it lives in the session's tmpfs, dies with
        # the session, and its fingerprint travels back over ssh. Identity is
        # anchored in the ssh channel, which binds the machine far more
        # tightly than a certified DNS name would.
        as_user ${openssl} req -x509 -newkey rsa:2048 -nodes -days 1 \
          -subj "/CN=$(${hostname})" -keyout "$key" -out "$cert" >/dev/null 2>&1 \
          || die "could not generate the TLS certificate"

        as_user ${grdctl} rdp set-tls-cert "$cert" >/dev/null
        as_user ${grdctl} rdp set-tls-key "$key" >/dev/null
        as_user ${grdctl} rdp set-port "$port" >/dev/null

        # Without this grd silently slides to another port when ours is busy,
        # and the tunnel would point at nothing.
        as_user ${grdctl} rdp disable-port-negotiation >/dev/null

        set_credentials

        if [ "$mode" = ro ] ;then
          as_user ${grdctl} rdp enable-view-only >/dev/null
        else
          as_user ${grdctl} rdp disable-view-only >/dev/null
        fi

        as_user ${grdctl} rdp enable >/dev/null
        as_user ${systemctl} --user start gnome-remote-desktop.service
        wait_port

        # Bare lowercase hex: openssl colon-separates, and a colon is what
        # FreeRDP uses to split the /cert: option itself.
        fingerprint=$(${openssl} x509 -in "$cert" -noout -fingerprint -sha256 \
          | ${sed} 's/^.*=//' | ${tr} -d ':' | ${tr} '[:upper:]' '[:lower:]')
      }

      start_x11() {
        local display xauth
        local args

        display=$(environ_get "$s_leader" DISPLAY)
        xauth=$(environ_get "$s_leader" XAUTHORITY)
        [ -n "$display" ] || die "no DISPLAY in the session leader's environment"

        args=( "/bind-address:127.0.0.1" "/port:$port" "-auth" )

        # -auth drops client authentication, which is sound here and only
        # here: the listener is loopback-only, so the ssh tunnel is the sole
        # way in and it already authenticated the admin.
        [ "$mode" != ro ] || args+=( "-may-interact" )

        # A transient service, not a scope: a scope dies with the process that
        # created it, i.e. the ssh command about to return.
        ${systemdRun} --collect --quiet --unit="$shadow_unit" \
          --uid="$s_user" \
          --setenv=DISPLAY="$display" \
          --setenv=XAUTHORITY="$xauth" \
          -- ${shadow} "''${args[@]}" >/dev/null

        wait_port
      }

      cmd_probe() {
        load_session
        echo "session=$sid"
        echo "session_user=$s_user"
        echo "type=$s_type"
      }

      cmd_start() {
        mode=$1
        case "$mode" in
          ro | rw) ;;
          *) die "mode must be ro or rw" ;;
        esac

        [ ! -e "$state" ] || die "a support session is already open; run 'stop' first"

        load_session

        rdp_user=dnf-support
        rdp_pass=$(${openssl} rand -hex 18)
        cert=""
        key=""
        fingerprint=""
        auth=credentials

        case "$s_type" in
          wayland) start_gnome ;;
          x11)
            auth=none
            rdp_user=""
            rdp_pass=""
            start_x11
            ;;
          *) die "unsupported session type: $s_type" ;;
        esac

        umask 077
        {
          echo "backend=$s_type"
          echo "session_user=$s_user"
          echo "session_uid=$s_uid"
          echo "session_dbus=$s_dbus"
          echo "mode=$mode"
          echo "cert=$cert"
          echo "key=$key"
        } > "$state"

        # Self-destruct. If the admin's client dies, the laptop closes or the
        # tunnel breaks, the session still closes on its own.
        ${systemdRun} --collect --quiet --unit="$timeout_unit" \
          --on-active="''${timeout}m" -- "$0" stop >/dev/null

        echo "backend=$s_type"
        echo "session_user=$s_user"
        echo "mode=$mode"
        echo "port=$port"
        echo "auth=$auth"
        echo "username=$rdp_user"
        echo "password=$rdp_pass"
        echo "fingerprint=$fingerprint"
        echo "timeout=$timeout"
      }

      # Idempotent on purpose: it is called by the recipe, by the self-destruct
      # timer, and by an admin cleaning up by hand.
      cmd_stop() {
        local backend
        [ -e "$state" ] || exit 0

        backend=$(state_get backend)
        s_user=$(state_get session_user)
        s_uid=$(state_get session_uid)
        s_dbus=$(state_get session_dbus)
        s_runtime="/run/user/$s_uid"

        ${systemctl} stop "$timeout_unit.timer" "$timeout_unit.service" >/dev/null 2>&1 || true

        case "$backend" in
          wayland)
            as_user ${systemctl} --user stop gnome-remote-desktop.service >/dev/null 2>&1 || true
            as_user ${grdctl} rdp clear-credentials >/dev/null 2>&1 || true
            as_user ${dconf} reset -f /org/gnome/desktop/remote-desktop/rdp/ >/dev/null 2>&1 || true
            ${rm} -f "$(state_get cert)" "$(state_get key)"
            ;;
          x11)
            ${systemctl} stop "$shadow_unit.service" >/dev/null 2>&1 || true
            ;;
        esac

        ${rm} -f "$state"
      }

      case "''${1:-}" in
        probe) cmd_probe ;;
        start) cmd_start "''${2:-ro}" ;;
        stop) cmd_stop ;;
        *)
          echo "usage: dnf-remote-desktop probe | start <ro|rw> | stop" >&2
          exit 64
          ;;
      esac
    '';
  };
in
{
  options = {
    darkone.graphic.remote-desktop = {
      enable = mkOption {
        type = types.bool;
        default = hasFeature;
        description = "Remote desktop support access (driven by the host feature, avoid enabling manually).";
      };
      timeout = mkOption {
        type = types.ints.positive;
        default = 60;
        description = "Minutes before an armed support session closes itself.";
      };
    };
  };

  config = mkIf cfg.enable {

    # freerdp is explicit rather than inherited from the gnome-remote-desktop
    # closure: the X11 backend depends on freerdp-shadow-cli being there.
    environment.systemPackages = [
      remoteDesktopScript
      pkgs.freerdp
    ];

    assertions = [
      {
        assertion = config.darkone.graphic.gnome.enable;
        message = "The remote-desktop feature needs a graphical host (darkone.graphic.gnome.enable).";
      }
    ];
  };
}
