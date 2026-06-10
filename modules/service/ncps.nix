# Nix cache proxy with NCPS module.
#
# This module is activated by core. Server and clients are automatically detected.
#
# :::tip
# To check if a host contains the local gateway in substituters:
#
# ```sh
# nix --extra-experimental-features nix-command show-config | grep substituters
# telnet <your-gateway> 8501
# ```
# :::

{
  lib,
  config,
  network,
  pkgs,
  host,
  hosts,
  zone,
  dnfLib,
  dnfConfig,
  workDir,
  ...
}:
let
  inherit (dnfLib) findHost preferredIp;
  cfg = config.darkone.service.ncps;
  hostIsLocal = host.zone != "www";
  ncpsService = lib.findFirst (s: s.zone == zone.name && s.name == "ncps") null network.services;

  # A zone may declare no ncps service (eg. minimal hosts); stay null-safe so
  # `serverName` does not select `.host` on a missing service.
  serverName = if ncpsService == null then null else ncpsService.host;
  hasServer = hostIsLocal && serverName != null;
  isServer = hostIsLocal && host.hostname == serverName;
  isClient = hostIsLocal && hasServer;
  ncpsPort = dnfConfig.network.ports.ncps;
  harmoniaPort = dnfConfig.network.ports.harmonia;

  # Harmonia upstreams in scope for this zone's ncps: same-zone instances
  # (highest priority, reached over the LAN) first, then any global harmonia
  # (reached cross-zone over the tailnet). Other zones' non-global harmonia are
  # never used.
  harmoniaInZone = lib.filter (s: s.name == "harmonia" && s.zone == zone.name) network.services;
  harmoniaGlobal = lib.filter (
    s: s.name == "harmonia" && (s.global or false) && s.zone != zone.name
  ) network.services;
  harmoniaUrls =
    (map (s: "http://${(findHost s.host s.zone hosts).ip}:${toString harmoniaPort}") harmoniaInZone)
    ++ (map (
      s: "http://${preferredIp (findHost s.host s.zone hosts)}:${toString harmoniaPort}"
    ) harmoniaGlobal);

  # Deployment-wide harmonia public key (committed like nix.pub). Present only
  # once the admin has provisioned the binary-cache key; absent in standalone
  # test mode where the consumer workspace does not exist.
  harmoniaPubFile = workDir + "/usr/secrets/harmonia.pub";
  harmoniaKeys = lib.optional (
    (!config.darkone.test.standalone) && builtins.pathExists harmoniaPubFile
  ) (lib.fileContents harmoniaPubFile);
in
{
  options = {
    darkone.service.ncps.enable = lib.mkEnableOption "Enable nix cache proxy for packages";
    darkone.service.ncps.dataPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/ncps";
      description = "Nix cache proxy cache folder";
    };
    darkone.service.ncps.extraOptions = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "services.ncps extra options";
    };
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.ncps = {
        displayOnHomepage = false;
        persist = {
          varDirs = [ config.services.ncps.cache.dataPath ];
        };
        proxy.enable = false;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.ncps.enable = isServer;
      };

      # The upstream unit runs with ProtectHome=true: a dataPath under /home
      # is invisible to the service ("permission denied" at first dbmate run).
      # Put the cache elsewhere, or bind mount the /home space onto dataPath.
      assertions = [
        {
          assertion = !(isServer && lib.hasPrefix "/home" cfg.dataPath);
          message = "darkone.service.ncps.dataPath cannot live under /home (ncps runs with ProtectHome=true); use a bind mount instead.";
        }
      ];

      #------------------------------------------------------------------------
      # NCPS Service
      #------------------------------------------------------------------------

      services.ncps = lib.mkIf isServer (
        {
          package = pkgs.ncps;
          enable = true;
          cache = {
            storage.local = cfg.dataPath;
            maxSize = "40G";
            hostName = "${host.hostname}.${zone.domain}";
            lru.schedule = "0 2 * * *";
            allowPutVerb = true;
            allowDeleteVerb = true;
            upstream = {

              # Bounded upstream waits: a sick harmonia or an unreachable
              # public cache must not freeze the proxy for every client.
              dialerTimeout = "3s";
              responseHeaderTimeout = "10s";
              urls = harmoniaUrls ++ [
                "https://cache.nixos.org"
                "https://nix-community.cachix.org"
              ];
              publicKeys = harmoniaKeys ++ [
                "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
                "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
              ];
            };
          };
        }
        // cfg.extraOptions
      );

      # Add local gw to substituters.
      # Check with nix --extra-experimental-features nix-command config show | grep substituters
      nix.settings = {
        substituters = [
          (lib.mkIf isClient "http://${zone.gateway.hostname}.${zone.domain}:${toString ncpsPort}")
          "https://nix-community.cachix.org"
        ];
        trusted-public-keys = harmoniaKeys ++ [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        ];

        # Fail fast when the zone cache is down or degraded: a broken ncps
        # must never be slower than no cache at all (cf. agate disk-full
        # incident: HTTP 500 retries slowed down every build of the fleet).
        connect-timeout = 5;
        download-attempts = 2;
        fallback = true;
      };

      #------------------------------------------------------------------------
      # Recovery helper (server only)
      #------------------------------------------------------------------------

      # A disk-full incident can desync the sqlite index from the stored NARs,
      # making ncps answer HTTP 500 "invalid nar hash" on every request.
      # Wiping store + db is the reliable repair (the signing key in config/
      # is preserved); the only cost is re-downloading from upstreams.
      environment.systemPackages = lib.mkIf isServer [
        (pkgs.writeShellScriptBin "ncps-reset" ''
          set -euo pipefail

          if [ "$(${pkgs.coreutils}/bin/id -u)" -ne 0 ]; then
            echo "ncps-reset must run as root" >&2
            exit 1
          fi

          echo "This wipes the ncps cache and index (${cfg.dataPath}/{store,db}) then restarts ncps."
          read -r -p "Continue? [y/N] " answer
          [ "$answer" = "y" ] || exit 1

          ${pkgs.systemd}/bin/systemctl stop ncps.service
          ${pkgs.coreutils}/bin/rm -rf ${cfg.dataPath}/store ${cfg.dataPath}/db

          # Recreate the data directories with their canonical owner/perms,
          # exactly as a fresh deployment would.
          ${pkgs.systemd}/bin/systemd-tmpfiles --create --prefix=${cfg.dataPath}

          # The unit may have hit its start rate limit while broken.
          ${pkgs.systemd}/bin/systemctl reset-failed ncps.service || true
          ${pkgs.systemd}/bin/systemctl start ncps.service
          echo "ncps cache reset done."
        '')
      ];
    })
  ];
}
