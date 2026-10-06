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
# - roaming clients (`roaming = true`, set by the `roaming` host feature):
#   nomadic hosts moved between zones. Their substituters are the zone-neutral
#   names (`harmonia.dnf.internal`, `nix-cache.dnf.internal`) that each zone's
#   DNS resolves to its own cache services (see `service/dnsmasq.nix`), so the
#   cache follows the laptop. `fleet-update` builds such a host on itself.
# - global-zone hosts (`www`, a datacenter VPS): no LAN, no gateway, so no
#   proxy. They take the `global` harmonia over the tailnet and the fleet key,
#   without which they can pull nothing the fleet built.
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
  hostIsLocal = host.zone != dnfLib.constants.globalZone;
  cacheService = lib.findFirst (
    s: s.zone == zone.name && s.name == "nix-cache"
  ) null network.services;

  # A zone may declare no nix-cache service; stay null-safe so `serverName` does
  # not select `.host` on a missing service.
  serverName = if cacheService == null then null else cacheService.host;
  hasServer = hostIsLocal && serverName != null;
  isServer = hostIsLocal && host.hostname == serverName;

  # A roaming host ignores its declared zone: zone-pinned substituters would
  # point at unreachable caches as soon as the machine moves. It relies on the
  # zone-neutral names instead, whatever zone (if any) it is plugged into.
  isRoaming = hostIsLocal && cfg.roaming;
  isClient = hostIsLocal && hasServer && !isRoaming;

  # Global zone: none of the zone-pinned plumbing above applies, but the host
  # still belongs to the cache fabric through a `global` harmonia (tailnet) and
  # the fleet signing key.
  isGlobalZone = !hostIsLocal;
  cachePort = dnfConfig.network.ports.nixCache;
  harmoniaPort = dnfConfig.network.ports.harmonia;

  # Substituter priorities (lower wins), pinned in the store URL: Nix orders by
  # the advertised `nix-cache-info` value, which collides here (harmonia 30,
  # this proxy and `cache.nixos.org` both 40). The direct `cache.nixos.org`
  # keeps its 40: the fallback when the gateway is down.
  inZonePriority = 20; # zone harmonia (LAN): what the zone built
  proxyPriority = 35; # beats the direct upstream, so the zone pools downloads
  globalPriority = 45; # cross-zone harmonia: only for paths upstream lacks

  # Store URL carrying an explicit priority (see above).
  cacheUrl =
    priority: port: addr:
    "http://${addr}:${toString port}?priority=${toString priority}";
  harmoniaUrl = priority: cacheUrl priority harmoniaPort;
  proxyUrl = cacheUrl proxyPriority cachePort;

  # Harmonia substituters in scope: same-zone instances first, then any global
  # one (cross-zone, tailnet); Nix handles 404 fall-through and signatures. A
  # harmonia host skips its own instance: it serves this very `/nix/store`.
  harmoniaInZone = lib.filter (
    s: s.name == "harmonia" && s.zone == zone.name && s.host != host.hostname
  ) network.services;
  harmoniaGlobal = lib.filter (
    s: s.name == "harmonia" && (s.global or false) && s.zone != zone.name
  ) network.services;
  harmoniaUrls =
    (map (s: harmoniaUrl inZonePriority (findHost s.host s.zone hosts).ip) harmoniaInZone)
    ++ (map (
      s: harmoniaUrl globalPriority (preferredIp (findHost s.host s.zone hosts))
    ) harmoniaGlobal);

  # Roaming substituters: zone-neutral names served by each zone's DNS (see
  # `service/dnsmasq.nix`). Outside any DNF zone both names NXDOMAIN instantly
  # and Nix falls through to cache.nixos.org — no cross-zone (tailnet) harmonia
  # here on purpose: from inside another zone it would be a dead substituter
  # (tailscale may be paused on zone LANs) eating connect-timeouts.
  roamingUrls = [
    (harmoniaUrl inZonePriority dnfLib.constants.harmoniaRoamingFqdn)
    (proxyUrl dnfLib.constants.nixCacheRoamingFqdn)
  ];

  # Deployment-wide harmonia public key (committed like nix.pub). Present only
  # once the admin has provisioned the binary-cache key; absent in standalone
  # test mode where the consumer workspace does not exist.
  harmoniaPubFile = workDir + "/usr/secrets/harmonia.pub";
  harmoniaKeys = lib.optional (
    (!config.darkone.test.standalone) && builtins.pathExists harmoniaPubFile
  ) (lib.fileContents harmoniaPubFile);

  # The single public upstream this proxy caches.
  upstreamHost = "cache.nixos.org";
  upstreamKey = "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=";

  # nginx-managed cache directory (path is `/var/cache/nginx/<name>`).
  cacheName = "nix-cache";
  cacheDir = "/var/cache/nginx/${cacheName}";

  # Local resolver for the runtime upstream lookup below. The nix-cache server
  # is always the zone gateway, which runs its own DNS (dnsmasq, or adguardhome
  # in front of it) on this address — reachable regardless of the box's
  # /etc/resolv.conf state.
  resolverIp = zone.gateway.lan.ip;
in
{
  options = {
    darkone.service.nix-cache.enable = lib.mkEnableOption "the per-zone Nix binary-cache proxy (nginx in front of cache.nixos.org)";
    darkone.service.nix-cache.maxSize = lib.mkOption {
      type = lib.types.str;
      default = "40g";
      description = "Maximum on-disk cache size; nginx evicts least-recently-used entries beyond it.";
    };
    darkone.service.nix-cache.roaming = lib.mkOption {
      type = lib.types.bool;

      # One declaration for both sides: `fleet-update` reads the same feature.
      default = (host.features or { }) ? "roaming";
      defaultText = lib.literalExpression ''host.features ? "roaming"'';
      description = ''
        Nomadic host (laptop moved between zones): replace the zone-pinned
        substituters with the zone-neutral names every zone's DNS resolves to
        its own cache services. Outside any DNF zone the names NXDOMAIN
        instantly and Nix falls back to cache.nixos.org. Declared by the
        `roaming` feature in `config.yaml`; set it by hand for a temporary move.
      '';
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

            # Upstream as an nginx variable: `cache.nixos.org` resolves per
            # request (every `valid=`), not at startup, where a resolv.conf being
            # rewritten failed nginx hard ("host not found in upstream"). A
            # variable `proxy_pass` needs `$request_uri` to carry the path.
            proxyPass = "https://$nix_cache_upstream$request_uri";

            # NixOS appends its recommended proxy headers *after* extraConfig,
            # ending with `proxy_set_header Host $host` — which would override the
            # upstream Host set below and make Fastly answer 421. This cache
            # wants none of those headers, so drop them on this location.
            recommendedProxySettings = false;

            extraConfig = ''
              # Runtime resolver for the variable upstream above. ipv6=off: the
              # gateway runs IPv4-only; valid=300s re-resolves to follow Fastly's
              # rotating CDN IPs.
              resolver ${resolverIp} ipv6=off valid=300s;
              set $nix_cache_upstream ${upstreamHost};

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

              # HTTPS upstream behind a CDN (Fastly): send the TLS SNI and the
              # Host header as the upstream name so Fastly serves the matching
              # cert and routes the request (otherwise 421).
              proxy_ssl_name ${upstreamHost};
              proxy_ssl_server_name on;
              proxy_set_header Host ${upstreamHost};

              # NARs can be multi-GB: never cap them to a temp-file ceiling.
              proxy_max_temp_file_size 0;

              add_header X-Cache-Status $upstream_cache_status;
            '';
          };
        };
      };

      # A server's substituters must stay zone-pinned: it *is* the zone cache.
      assertions = [
        {
          assertion = !(isServer && cfg.roaming);
          message = "darkone.service.nix-cache: host '${host.hostname}' cannot be both the zone cache server and a roaming client.";
        }
      ];

      #----------------------------------------------------------------------
      # Clients: substituters (harmonia direct + this proxy)
      #----------------------------------------------------------------------

      nix.settings = {
        substituters = lib.mkMerge [
          (lib.mkIf isClient (
            harmoniaUrls
            ++ [
              (proxyUrl "${zone.gateway.hostname}.${zone.domain}")

              # Optional direct (not LAN-cached) upstream. cache.nixos.org covers a
              # standard nixpkgs fleet, so cachix stays off; re-enable here if a
              # nix-community-only path starts building from source.
              # "https://nix-community.cachix.org"
            ]
          ))
          (lib.mkIf isRoaming roamingUrls)

          # Global zone: no proxy out there, so `harmoniaUrls` holds the global
          # harmonia alone, at its usual priority 45.
          (lib.mkIf isGlobalZone harmoniaUrls)
        ];

        # Keys are zone-independent (deployment-wide harmonia key, upstream
        # signatures relayed verbatim by the proxy), so roaming needs no more.
        trusted-public-keys = lib.mkIf (isClient || isRoaming || isGlobalZone) (
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
