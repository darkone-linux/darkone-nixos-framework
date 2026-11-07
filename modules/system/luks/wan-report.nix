# DNF luks: gateways report their WAN address to the HCS. Doc: `../luks.nix` header.

{
  lib,
  config,
  pkgs,
  host,
  hosts,
  network,
  ...
}:
let
  cfg = config.darkone.system.luks;
  inherit (cfg.shared) manifest;

  coordination = network.coordination or { };
  hcsHost = lib.findFirst (h: h.hostname == (coordination.hostname or "")) { } hosts;

  # IP literal, no DNS: the initrd runs no resolver, and the HCS keeps a
  # fixed public address (`ipv4.external` in config.yaml).
  hcsIp = hcsHost.ip or "";
  isHcs = host.hostname == (coordination.hostname or "");
  active = cfg.wanReport.enable && (coordination.enable or false) && hcsIp != "";

  reportUser = "dnf-wan-report";
  stateDir = "/var/lib/dnf-wan-report";

  # Published by `just luks <host>`: the HCS authorizes a gateway with it.
  # Absent = this side stays inert, the other side refuses it anyway.
  pubOf = h: manifest.${h}."initrd-key-pub" or "";

  # Gateways of local zones (a `lan`), i.e. the hosts whose VPN dies with them.
  gateways = lib.unique (
    lib.concatMap (
      z:
      let
        gw = z.gateway.hostname or "";
      in
      lib.optional (gw != "" && gw != (coordination.hostname or "") && (z.gateway ? lan)) gw
    ) (lib.attrValues (network.zones or { }))
  );
  reporters = lib.filter (gw: pubOf gw != "") gateways;

  #----------------------------------------------------------------------------
  # Gateway side
  #----------------------------------------------------------------------------

  sshPkg = config.services.openssh.package;

  # The initrd SSH host key doubles as the report identity: already in the
  # initrd (`boot.initrd.secrets`), same path in stage 1 and stage 2.
  identity = "/var/lib/luks-initrd/ssh_host_ed25519_key";

  # `#!/bin/sh`, POSIX only, `sleep` from the initrd /bin: same constraints
  # as `dnf-unlock`. No HCS host key pinning: the session carries no secret,
  # a man in the middle can only drop the report (signature bound to it).
  reportScript = pkgs.writeTextFile {
    name = "dnf-wan-report";
    executable = true;
    text = ''
      #!/bin/sh
      set -u
      phase=''${1:-system}

      report() {
        ${sshPkg}/bin/ssh -F /dev/null -i ${identity} -p 22 \
          -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=15 \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR ${reportUser}@${hcsIp} "$phase" 2>&1
      }

      if [ "$phase" != initrd ]; then
        out=$(report) || {
          echo "dnf-wan-report: failed: $out" >&2
          exit 1
        }
        echo "dnf-wan-report: WAN address $out reported to ${hcsIp}"
        exit 0
      fi

      # Initrd: report until switch-root stops the unit; the address may move
      # during a long wait. A refused key retries slowly, or the HCS fail2ban
      # bans the whole zone address after 3 failures.
      while :; do
        if out=$(report); then
          echo "dnf-wan-report: WAN address $out reported to ${hcsIp}"
          delay=900
        else
          echo "dnf-wan-report: failed: $out" >&2
          case $out in
            *"Permission denied"*) delay=900 ;;
            *) delay=15 ;;
          esac
        fi
        sleep "$delay"
      done
    '';
  };

  #----------------------------------------------------------------------------
  # HCS side
  #----------------------------------------------------------------------------

  # Forced command of every gateway key: the client address comes from sshd
  # (`SSH_CONNECTION`), never from the gateway. A changed address or phase
  # goes to the journal: the history of a gateway's reboots, kept on the HCS.
  recordScript = pkgs.writeShellScript "dnf-wan-record" ''
    set -eu
    gw=$1
    case "''${SSH_ORIGINAL_COMMAND:-}" in
      initrd | system) phase=$SSH_ORIGINAL_COMMAND ;;
      *) phase=unknown ;;
    esac
    ip=''${SSH_CONNECTION%% *}
    old=$(${pkgs.coreutils}/bin/cat "${stateDir}/$gw" 2>/dev/null || true)
    printf '%s %s %s\n' "$ip" "$(${pkgs.coreutils}/bin/date +%s)" "$phase" >"${stateDir}/.$gw.tmp"

    # Read by `nix` (`just unlock`), whatever umask the session got.
    ${pkgs.coreutils}/bin/chmod 644 "${stateDir}/.$gw.tmp"
    ${pkgs.coreutils}/bin/mv -f "${stateDir}/.$gw.tmp" "${stateDir}/$gw"
    set -- $old
    if [ "''${1:-}" != "$ip" ] || [ "''${3:-}" != "$phase" ]; then
      ${pkgs.util-linux}/bin/logger -t dnf-wan-report "$gw: $ip ($phase)"
    fi
    echo "$ip"
  '';
in
{
  options.darkone.system.luks.wanReport.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Zone gateways report their WAN address to the HCS, from the initrd and the booted system (`just unlock` reads it)";
  };

  config = lib.mkMerge [

    # Same gate as the initrd sshd: the identity key only exists there.
    (lib.mkIf
      (
        active
        && !isHcs
        && cfg.shared.luksActive
        && cfg.shared.hasNixPub
        && cfg.shared.isGateway
        && pubOf host.hostname != ""
      )
      {
        boot.initrd.systemd.storePaths = [ "${sshPkg}/bin/ssh" ];
        boot.initrd.systemd.extraBin.dnf-wan-report = reportScript;

        # Same lifecycle as the initrd sshd: `initrd-switch-root.target`
        # isolation stops it once the volume is open.
        boot.initrd.systemd.services.dnf-wan-report = {
          description = "Report the WAN address to the coordination server";
          wantedBy = [ "initrd.target" ];
          after = [
            "network.target"
            "initrd-nixos-copy-secrets.service"
          ];
          before = [ "shutdown.target" ];
          conflicts = [ "shutdown.target" ];
          unitConfig.DefaultDependencies = false;

          # Initrd secrets land world-readable: ssh refuses such a key, as
          # sshd does (its own preStart runs the same chmod).
          preStart = "/bin/chmod 0600 ${identity}";
          serviceConfig = {
            Type = "simple";
            ExecStart = "/bin/dnf-wan-report initrd";
          };
        };

        # Booted system: keeps the last known address fresh, and proves the
        # chain works before the day it is needed.
        systemd.services.dnf-wan-report = {
          description = "Report the WAN address to the coordination server";
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${reportScript} system";
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            NoNewPrivileges = true;
          };
        };
        systemd.timers.dnf-wan-report = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2min";
            OnUnitActiveSec = "1h";
            RandomizedDelaySec = "5min";
          };
        };
      }
    )

    # `restrict`: no pty, no forwarding; the key runs the record, nothing else.
    # A real shell: sshd runs a forced command through the login shell.
    (lib.mkIf (active && isHcs && reporters != [ ]) {
      users.groups.${reportUser} = { };
      users.users.${reportUser} = {
        isSystemUser = true;
        group = reportUser;
        home = stateDir;
        createHome = true;
        homeMode = "755";
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keys = map (
          gw: ''restrict,command="${recordScript} ${gw}" ${pubOf gw}''
        ) reporters;
      };
    })
  ];
}
