# Per-zone Nix binary-cache proxy (nginx `proxy_cache`).
#
# Caches the public Nix cache (`cache.nixos.org`) on the zone gateway so a
# fleet-wide deploy pulls each closure from the WAN once, then serves it over
# the LAN to every other host. Locally built paths are served straight from
# `harmonia` (see `harmonia.nix`); this proxy never fronts harmonia.
#
# :::note[Why nginx and not a rewriting proxy]
# One cache endpoint fronts exactly **one** upstream. A `narinfo` and its `nar`
# are two separate requests and the `nar` URL is upstream-agnostic, so a
# multi-upstream proxy must rewrite `narinfo` URLs into its own namespace and
# track them in a database (the approach the former `ncps` proxy took — and the
# source of its recurring HTTP 500 "invalid nar hash"). With a single upstream
# there is no ambiguity:
# nginx caches `narinfo` + `nar` verbatim, signatures pass through untouched and
# clients verify them. No rewrite, no database, no such bug by construction.
# :::
#
# :::tip[Topology]
# - server: the gateway host that lists `nix-cache` in `config.yaml` (one per
#   zone). Runs nginx on the internal IP, port `network.ports.nixCache`.
# - clients: every local-zone host. Their substituters become the zone's
#   harmonia instances (direct, LAN/tailnet) plus this proxy.
# :::

{
  lib,
  config,
  network,
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
  cfg = config.darkone.service.nix-cache;
  hostIsLocal = host.zone != "www";
  cacheService = lib.findFirst (
    s: s.zone == zone.name && s.name == "nix-cache"
  ) null network.services;

  # A zone may declare no nix-cache service; stay null-safe so `serverName` does
  # not select `.host` on a missing service.
  serverName = if cacheService == null then null else cacheService.host;
  hasServer = hostIsLocal && serverName != null;
  isServer = hostIsLocal && host.hostname == serverName;
  isClient = hostIsLocal && hasServer;
  cachePort = dnfConfig.network.ports.nixCache;
  harmoniaPort = dnfConfig.network.ports.harmonia;

  # Harmonia substituters in scope for this zone: same-zone instances (LAN,
  # highest priority) first, then any global harmonia (reached cross-zone over
  # the tailnet). Other zones' non-global harmonia are never used. These are now
  # direct client substituters — Nix itself handles the 404 fall-through and the
  # signature checks across substituters.
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

  # The single public upstream this proxy caches.
  upstreamUrl = "https://cache.nixos.org";
  upstreamHost = "cache.nixos.org";
  upstreamKey = "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=";

  # nginx-managed cache directory (path is `/var/cache/nginx/<name>`).
  cacheName = "nix-cache";
  cacheDir = "/var/cache/nginx/${cacheName}";
in
{
  options = {
    darkone.service.nix-cache.enable = lib.mkEnableOption "the per-zone Nix binary-cache proxy (nginx in front of cache.nixos.org)";
    darkone.service.nix-cache.maxSize = lib.mkOption {
      type = lib.types.str;
      default = "40g";
      description = "Maximum on-disk cache size; nginx evicts least-recently-used entries beyond it.";
    };
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.nix-cache = {
        displayOnHomepage = false;
        persist.varDirs = [ cacheDir ];
        proxy.enable = false;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable on the gateway that hosts it.
      darkone.system.services = {
        enable = true;
        service.nix-cache.enable = isServer;
      };

      #----------------------------------------------------------------------
      # Server: nginx proxy_cache (gateway only)
      #----------------------------------------------------------------------

      services.nginx = lib.mkIf isServer {
        enable = true;

        proxyCachePath.${cacheName} = {
          enable = true;
          keysZoneName = "nixcache";
          keysZoneSize = "100m";
          inherit (cfg) maxSize;
          inactive = "30d";
          levels = "1:2";
          useTempPath = false;
        };

        # Plain HTTP on the internal IP only; the trusted LAN/VPN carries it and
        # integrity comes from the NAR signature, not from TLS (like harmonia).
        virtualHosts.${cacheName} = {
          listen = [
            {
              addr = host.ip;
              port = cachePort;
            }
          ];
          locations."/" = {
            proxyPass = upstreamUrl;
            extraConfig = ''
              proxy_cache nixcache;

              # Content-addressed paths: the URI alone is a stable key, so cache
              # essentially forever; keep only a short negative cache for misses.
              proxy_cache_key $uri;
              proxy_cache_valid 200 365d;
              proxy_cache_valid 404 1m;

              # Keep serving from cache while the upstream is down or degraded.
              proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;

              # Collapse concurrent misses for one path into a single fetch.
              proxy_cache_lock on;

              # HTTPS upstream behind a CDN: force SNI + Host so it routes.
              proxy_ssl_server_name on;
              proxy_set_header Host ${upstreamHost};

              # NARs can be multi-GB: never cap them to a temp-file ceiling.
              proxy_max_temp_file_size 0;

              add_header X-Cache-Status $upstream_cache_status;
            '';
          };
        };
      };

      #----------------------------------------------------------------------
      # Clients: substituters (harmonia direct + this proxy)
      #----------------------------------------------------------------------

      nix.settings = {
        substituters = lib.mkIf isClient (
          harmoniaUrls
          ++ [
            "http://${zone.gateway.hostname}.${zone.domain}:${toString cachePort}"

            # Optional direct (not LAN-cached) upstream. cache.nixos.org covers a
            # standard nixpkgs fleet, so cachix stays off; re-enable here if a
            # nix-community-only path starts building from source.
            # "https://nix-community.cachix.org"
          ]
        );
        trusted-public-keys = lib.mkIf isClient (
          harmoniaKeys
          ++ [
            upstreamKey

            # Matching key for the optional cachix substituter above.
            # "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
          ]
        );

        # Fail fast when the zone cache is down or degraded: a broken cache must
        # never be slower than no cache at all. mkDefault so a consumer can
        # override them per host.
        connect-timeout = lib.mkDefault 5;
        download-attempts = lib.mkDefault 2;
        fallback = lib.mkDefault true;
      };
    })
  ];
}
