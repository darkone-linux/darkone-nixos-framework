# MicroVM hypervisor side: whisper.cpp server for the guests that ask for it.

{
  lib,
  config,
  options,
  dnfLib,
  dnfConfig,
  pkgs,
  host,
  hosts,
  microvmGuests,
  ...
}:
let
  cfg = config.darkone.system.microvm.whisper;
  port = dnfConfig.network.ports.whisper;

  # Inventory entries (IP, tap) of the guests with `guest.whisper`.
  clients = lib.filter (
    h:
    microvmGuests ? ${h.hostname}
    && microvmGuests.${h.hostname}.config.darkone.system.microvm.guest.whisper
  ) hosts;
  tap = h: (dnfLib.mkMicrovmLink h).tap;
in
{
  config = lib.optionalAttrs (options ? microvm.host) (
    lib.mkIf (clients != [ ]) {

      # Both tables filter input: NixOS firewall and `dnf-microvm`.
      networking.firewall.interfaces = lib.listToAttrs (
        map (h: lib.nameValuePair (tap h) { allowedTCPPorts = [ port ]; }) clients
      );
      darkone.system.microvm.guestInputRules = lib.concatMapStrings (h: ''
        iifname "${tap h}" ip saddr ${h.ip} tcp dport ${toString port} accept
      '') clients;

      systemd.services.whisper-server = {
        description = "whisper.cpp speech-to-text server for microVM guests";
        wantedBy = [ "multi-user.target" ];

        # Binds the hypervisor's LAN address: retried until it is up.
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];

        # OpenMP defaults to one thread per core beside ggml's: oversubscribed,
        # 2-3 times slower.
        environment.OMP_NUM_THREADS = toString cfg.threads;

        # `/load` makes the server load any file a client names, and exit on
        # failure: chroot holding this model only, restarted by systemd. The
        # guest falls back on its local model meanwhile.
        confinement.enable = true;

        # WAV only (no `--convert`): guests convert, no ffmpeg run here.
        serviceConfig = {
          ExecStart = lib.escapeShellArgs [
            "${pkgs.whisper-cpp}/bin/whisper-server"
            "--host"
            host.ip
            "--port"
            (toString port)
            "--model"
            "${cfg.model}"
            "--language"
            "auto"
            "--threads"
            (toString cfg.threads)
            "--public"
            "${pkgs.emptyDirectory}"
          ];
          Restart = "always";
          RestartSec = 5;
          DynamicUser = true;

          # Guests' content is untrusted: requesting guests only, no privilege.
          IPAddressAllow = map (h: h.ip) clients;
          IPAddressDeny = "any";
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_UNIX"
          ];
          CapabilityBoundingSet = "";
          NoNewPrivileges = true;
          MemoryDenyWriteExecute = true;
          LockPersonality = true;
          RestrictNamespaces = true;
          RestrictRealtime = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectProc = "invisible";
          SystemCallArchitectures = "native";
          SystemCallFilter = [ "@system-service" ];
        };
      };
    }
  );
}
