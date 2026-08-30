# Admin remote desktop: attach to an open graphical session, or open one, over RDP.
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
# :::tip[Three modes]
# `ro` mirrors the screen read-only, `rw` mirrors it and takes control. Both
# need somebody logged in and fail otherwise, rather than quietly handing out
# a private session an admin who asked to *watch* a user would not expect.
# `login` is that private session, asked for explicitly: a GDM login screen
# served by the system daemon, whoever is in front of the machine.
# :::
#
# :::tip[Three backends, one protocol]
# A GNOME Wayland session is served by `gnome-remote-desktop`, driven through
# `grdctl` inside the session owner's own bus. A Cinnamon X11 session — the
# gaze-driven UMI workstation, since GNOME 50 dropped its Xorg session — is
# served by `freerdp-shadow-cli` on the existing display. A `login` session is
# served by the same `gnome-remote-desktop`, in its system runtime mode, which
# hands the client over to GDM. Same protocol, same client, `ro`/`rw`
# enforced server-side.
# :::
#
# :::caution[Attaching is taking over someone's screen]
# The target session belongs to a user who is very likely sitting in front of
# it. GNOME shows a sharing indicator, but nothing asks for consent: this is a
# support tool for machines you administer, and enabling it on a host is a
# deliberate, auditable declaration in `config.yaml`. `login` is the discreet
# one: it never touches the screen on the monitor.
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

  # Upstream hardcodes the METADATA cursor mode when mirroring a physical
  # monitor (`create_stream`, src/grd-rdp-layout-manager.c): the pointer's
  # *shape* is sent as an RDP pointer update but never its *position*, so the
  # client draws the remote cursor wherever the local mouse happens to be and
  # an observer never sees what the user is pointing at. EMBEDDED asks mutter
  # to composite the pointer into the video instead — which also stops the
  # PipeWire cursor metadata, so no second cursor appears.
  #
  # Deliberately a `--replace-fail` rather than a patch file: no context lines
  # to rot, and a loud, legible failure the day upstream touches that call.
  embeddedCursorOverlay = _final: prev: {
    gnome-remote-desktop = prev.gnome-remote-desktop.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        substituteInPlace src/grd-rdp-layout-manager.c \
          --replace-fail "GRD_SCREEN_CAST_CURSOR_MODE_METADATA);" \
                         "GRD_SCREEN_CAST_CURSOR_MODE_EMBEDDED);"
      '';
    });
  };

  awk = "${pkgs.gawk}/bin/awk";
  chmod = "${pkgs.coreutils}/bin/chmod";
  chown = "${pkgs.coreutils}/bin/chown";
  dconf = "${pkgs.dconf}/bin/dconf";
  dirname = "${pkgs.coreutils}/bin/dirname";
  env = "${pkgs.coreutils}/bin/env";
  gdbus = "${pkgs.glib}/bin/gdbus";
  mkdir = "${pkgs.coreutils}/bin/mkdir";
  mktemp = "${pkgs.coreutils}/bin/mktemp";
  mv = "${pkgs.coreutils}/bin/mv";
  cp = "${pkgs.coreutils}/bin/cp";
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
  touch = "${pkgs.coreutils}/bin/touch";
  tr = "${pkgs.coreutils}/bin/tr";

  remoteDesktopScript = pkgs.writeShellApplication {
    name = "dnf-remote-desktop";

    # Every binary is called through its store path below, so nothing is
    # expected on PATH — including when systemd runs the self-destruct timer.
    runtimeInputs = [ ];

    text = ''
      port=${toString port}
      state=${stateFile}
      syscert=/run/dnf-remote-desktop/tls.crt
      syskey=/run/dnf-remote-desktop/tls.key
      sysconf=/etc/gnome-remote-desktop/grd.conf
      sysconf_backup=/run/dnf-remote-desktop/grd.conf.orig
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

        # No session is not an error: the caller falls back to remote login.
        [ "$count" != 0 ] || return 1
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

        # `grdctl rdp enable` asks systemd to EnableUnitFiles, which drops an
        # alias into ~/.config/systemd/user pinning the store path resolved at
        # that instant. That alias outranks /etc/systemd/user and survives
        # every later deploy, so a stale one silently keeps starting an old
        # binary. Clear it and reload before enabling; `stop` removes it again.
        as_user ${systemctl} --user disable gnome-remote-desktop.service >/dev/null 2>&1 || true
        as_user ${systemctl} --user daemon-reload

        as_user ${grdctl} rdp enable >/dev/null
        as_user ${systemctl} --user start gnome-remote-desktop.service
        wait_port

        # Bare lowercase hex: openssl colon-separates, and a colon is what
        # FreeRDP uses to split the /cert: option itself.
        fingerprint=$(${openssl} x509 -in "$cert" -noout -fingerprint -sha256 \
          | ${sed} 's/^.*=//' | ${tr} -d ':' | ${tr} '[:upper:]' '[:lower:]')

        # Mirroring cannot resize a physical monitor, so the client has to open
        # at the remote aspect ratio or the desktop arrives stretched. Best
        # effort: the recipe falls back to a share of the local screen when
        # this comes back empty. \047 is a quote awk understands, which keeps
        # the program free of shell quoting.
        geometry=$(as_user ${gdbus} call --session \
          --dest org.gnome.Mutter.DisplayConfig \
          --object-path /org/gnome/Mutter/DisplayConfig \
          --method org.gnome.Mutter.DisplayConfig.GetCurrentState 2>/dev/null \
          | ${awk} 'BEGIN { RS = "[(]\047" }
                    /is-current.: <true>/ && match($0, /^[0-9]+x[0-9]+/) {
                      print substr($0, RSTART, RLENGTH); exit
                    }' || true)
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
        if load_session ;then
          echo "backend=$s_type"
          echo "session=$sid"
          echo "session_user=$s_user"
        else
          echo "backend=login"
        fi
      }

      # Nobody logged in: hand the client GDM instead, through the system
      # daemon. Same binary, same port, same tunnel — but its runtime mode
      # takes credentials from a TPM or a file rather than from a keyring,
      # which is precisely what an unattended machine cannot provide.
      #
      # The RDP credentials below only open the door; GDM then asks for the
      # real account. What comes back is a fresh headless session, never the
      # monitor's own screen.
      # `grdctl --system rdp enable` cannot be used here: it asks systemd to
      # enable the unit *before* setting the key, and that write lands in
      # /etc/systemd/system, read-only on NixOS by construction. It therefore
      # fails and never sets `enabled` at all. The unit already runs and we
      # start it ourselves, so the key is the only thing missing — put it in
      # the system daemon's own key file.
      set_system_enabled() {
        local tmp
        tmp=$(${mktemp})

        # grdctl creates the file on its first write, so `stop` can reach this
        # before anything ever wrote it — and awk on a missing file is fatal.
        [ -e "$sysconf" ] || ${touch} "$sysconf"

        ${awk} -v want="$1" '
          /^\[/ { group = $0 }
          group == "[RDP]" && /^[[:space:]]*enabled[[:space:]]*=/ { next }
          { print }
          /^\[RDP\][[:space:]]*$/ { print "enabled=" want ; done = 1 }
          END { if (!done) { print "[RDP]" ; print "enabled=" want } }
        ' "$sysconf" > "$tmp"
        ${chown} gnome-remote-desktop "$tmp"
        ${chmod} 644 "$tmp"
        ${mv} -f "$tmp" "$sysconf"
      }

      start_login() {
        local dir

        dir=$(${dirname} "$syscert")
        ${mkdir} -p "$dir"
        ${chmod} 700 "$dir"
        ${chown} gnome-remote-desktop "$dir"

        ${openssl} req -x509 -newkey rsa:2048 -nodes -days 1 \
          -subj "/CN=$(${hostname})" -keyout "$syskey" -out "$syscert" >/dev/null 2>&1 \
          || die "could not generate the TLS certificate"
        ${chown} gnome-remote-desktop "$syscert" "$syskey"
        ${chmod} 600 "$syscert" "$syskey"

        # Keep the original so `stop` restores exactly what was there.
        [ ! -e "$sysconf" ] || ${cp} -a "$sysconf" "$sysconf_backup"

        ${grdctl} --system rdp set-tls-cert "$syscert" >/dev/null
        ${grdctl} --system rdp set-tls-key "$syskey" >/dev/null
        ${grdctl} --system rdp set-port "$port" >/dev/null
        ${grdctl} --system rdp disable-port-negotiation >/dev/null
        ${grdctl} --system rdp set-credentials "$rdp_user" "$rdp_pass" >/dev/null

        # view-only defaults to true in the schema, and a login screen you
        # cannot type into is worth nothing: `ro` simply has no meaning here.
        ${grdctl} --system rdp disable-view-only >/dev/null 2>&1 || true

        set_system_enabled true
        ${systemctl} restart gnome-remote-desktop.service
        wait_port

        # Deliberately no fingerprint: the daemon hands the client over to the
        # login session, which presents a certificate of its own. Pinning ours
        # would break the second leg. Loopback behind the tunnel carries the
        # trust here.
        fingerprint=""
      }

      cmd_start() {
        mode=$1
        case "$mode" in
          ro | rw | login) ;;
          *) die "mode must be ro, rw or login" ;;
        esac

        [ ! -e "$state" ] || die "a support session is already open; run 'stop' first"

        rdp_user=dnf-support
        rdp_pass=$(${openssl} rand -hex 18)
        cert=""
        key=""
        fingerprint=""
        geometry=""

        # `login` asks for a session of one's own, so who sits in front of the
        # machine is irrelevant and never looked at. `ro`/`rw` mirror a screen
        # that has to exist: no session is a hard failure, never a silent
        # promotion to a private one — an admin asking to watch a user must
        # not end up somewhere else entirely.
        if [ "$mode" = login ] ;then
          backend=login
          cert=$syscert
          key=$syskey
        else
          load_session \
            || die "nobody is logged in: '$mode' has no screen to mirror (the 'login' mode opens a session instead)"
          backend=$s_type
          cert="$s_runtime/dnf-remote-desktop.crt"
          key="$s_runtime/dnf-remote-desktop.key"
        fi

        # Written BEFORE arming, not after: half-armed is exactly the state
        # `stop` has to be able to undo, and an arming that dies partway used
        # to leave the host configured with nothing to clean it up.
        umask 077
        {
          echo "backend=$backend"
          echo "session_user=''${s_user:-}"
          echo "session_uid=''${s_uid:-}"
          echo "session_dbus=''${s_dbus:-}"
          echo "mode=$mode"
          echo "cert=$cert"
          echo "key=$key"
        } > "$state"

        case "$backend" in
          wayland) start_gnome ;;
          x11)
            rdp_user=""
            rdp_pass=""
            start_x11
            ;;
          login) start_login ;;
          *) die "unsupported session type: $backend" ;;
        esac

        # Self-destruct. If the admin's client dies, the laptop closes or the
        # tunnel breaks, the session still closes on its own.
        ${systemdRun} --collect --quiet --unit="$timeout_unit" \
          --on-active="''${timeout}m" -- "$0" stop >/dev/null

        echo "backend=$backend"
        echo "session_user=''${s_user:-}"
        echo "mode=$mode"
        echo "port=$port"
        echo "username=$rdp_user"
        echo "password=$rdp_pass"
        echo "fingerprint=$fingerprint"
        echo "geometry=$geometry"
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

            # `rdp disable` is the counterpart of `rdp enable`: a plain dconf
            # reset flips the key but leaves the systemd unit enabled, and its
            # alias behind. Disable twice over, since only the alias actually
            # matters and grd may not always remove it.
            as_user ${grdctl} rdp disable >/dev/null 2>&1 || true
            as_user ${systemctl} --user disable gnome-remote-desktop.service >/dev/null 2>&1 || true

            as_user ${grdctl} rdp clear-credentials >/dev/null 2>&1 || true
            as_user ${dconf} reset -f /org/gnome/desktop/remote-desktop/rdp/ >/dev/null 2>&1 || true
            ${rm} -f "$(state_get cert)" "$(state_get key)"
            ;;
          x11)
            ${systemctl} stop "$shadow_unit.service" >/dev/null 2>&1 || true
            ;;
          login)

            # Order matters: deafen first, then stop. The unit is
            # WantedBy=graphical.target, so it may well come back — it just
            # must come back deaf.
            set_system_enabled false
            ${grdctl} --system rdp clear-credentials >/dev/null 2>&1 || true
            ${systemctl} stop gnome-remote-desktop.service >/dev/null 2>&1 || true

            # Restore what was there before, once nothing reads it any more.
            # No backup means there was no file: the shipped default is empty,
            # so dropping ours is what restores the host exactly.
            if [ -e "$sysconf_backup" ] ;then
              ${mv} -f "$sysconf_backup" "$sysconf"
              ${chown} gnome-remote-desktop "$sysconf"
            else
              ${rm} -f "$sysconf"
            fi
            ${rm} -f "$syscert" "$syskey"
            ;;
        esac

        ${rm} -f "$state"
      }

      case "''${1:-}" in
        probe) cmd_probe ;;
        start) cmd_start "''${2:-ro}" ;;
        stop) cmd_stop ;;
        *)
          echo "usage: dnf-remote-desktop probe | start <ro|rw|login> | stop" >&2
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
      embedCursor = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Patch gnome-remote-desktop so the pointer is composited into the
          video. Without it the observer cannot see where the user points,
          which defeats the read-only mode. Costs a local rebuild of
          gnome-remote-desktop.
        '';
      };
    };
  };

  config = mkIf cfg.enable {

    nixpkgs.overlays = lib.optional cfg.embedCursor embeddedCursorOverlay;

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
