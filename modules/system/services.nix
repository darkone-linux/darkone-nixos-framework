# DNF service registry: every service module registers here, and the registry
# is resolved against the network topology.
#
# :::caution[Special internal module]
# The resolved registry (`darkone.system.services.resolved`) feeds:
# - the homepage sections (below);
# - `services/caddy.nix`: reverse proxy vhosts, TLS, HTTP(S) firewall;
# - `services/oauth2-proxy.nix`: Kanidm SSO of the protected services.
# `persist.*` entries are the folders and files to back up.
# :::

{
  lib,
  config,
  host,
  hosts,
  zone,
  network,
  dnfLib,
  ...
}:
let
  inherit (lib)
    any
    filter
    findFirst
    mkEnableOption
    mkIf
    mkOption
    types
    ;
  cfg = config.darkone.system.services;

  # Build services list from real and default values
  services = map (service: {
    params = dnfLib.buildServiceParams (dnfLib.findHost service.host service.zone
      hosts
    ) network service cfg.service.${service.name}.defaultParams;
    inherit (service) name;
    inherit (cfg.service.${service.name}) enable;
    inherit (cfg.service.${service.name}) displayOnHomepage;
    inherit (cfg.service.${service.name}) proxy;
  }) network.services;

  # SSO is per zone: only a protected service of THIS zone needs oauth2-proxy
  # and its homepage anchor.
  hasProtectedServices = any (s: s.proxy.isProtected && s.params.zone == zone.name) services;

  # Auth anchor: oauth2-proxy's `/oauth2/*` live on this zone's homepage FQDN,
  # which already has a synced TLS certificate (a synthetic `auth.<zone>` has
  # none). Another zone's homepage would drop the post-login `rd`: cookie and
  # whitelist are scoped to `.<zone>`.
  authAnchor = findFirst (s: s.name == "homepage" && s.params.zone == zone.name) null services;
  authHost = if authAnchor != null then authAnchor.params.fqdn else null;

  # Services to display on the homepage of the zone gateway
  isGateway = dnfLib.isGateway host zone;
  homepageServices = filter (s: s.displayOnHomepage) services;

  mkHomeSection = dnfLib.mkHomepageSection zone.name;
in
{
  options = {
    darkone.system.services.enable = mkEnableOption "Enable DNF services manager to register and expose services";

    # Service registration options
    darkone.system.services.service = mkOption {
      default = { };
      description = "Global services configuration <name>";
      type = types.attrsOf (
        types.submodule (_: {
          options = {
            enable = mkEnableOption "Enable service proxy";
            defaultParams = mkOption {
              default = { };
              description = "Theses options are calculated by dnfLib.srv.extractServiceParams";
              type = types.submodule {
                options = {
                  domain = mkOption {
                    type = types.str;
                    default = "";
                    description = "Domain name for the service";
                  };
                  title = mkOption {
                    type = types.str;
                    default = "";
                    description = "Display name in homepage";
                  };
                  description = mkOption {
                    type = types.str;
                    default = "";
                    description = "Service description for homepage";
                  };
                  icon = mkOption {
                    type = types.str;
                    default = "";
                    description = "[Icon name for homepage](https://selfh.st/icons/)";
                  };
                  global = mkOption {
                    type = types.bool;
                    default = false;
                    description = "Global service is accessible on Internet";
                  };
                  noRobots = mkOption {
                    type = types.bool;
                    default = true;
                    description = "Prevent robots from scanning if global is true";
                  };
                  fqdn = mkOption {
                    type = types.str;
                    default = "";
                    description = "Calculated FQDN or the service before the reverse proxy";
                  };
                  href = mkOption {
                    type = types.str;
                    default = "";
                    description = "Calculated URL of the service before the reverse proxy";
                  };
                  ip = mkOption {
                    type = types.str;
                    default = "";
                    description = "Calculated IP to contact the service";
                  };
                };
              };
            };

            # Homepage settings
            displayOnHomepage = mkOption {
              type = types.bool;
              default = true;
              description = "Display a link on homepage";
            };

            # Network/DNS topology hints consumed by the generator (nix eval ->
            # var/generated/service-registry.json). Kept here so a service is
            # fully described in its own module: the generator no longer hard-codes
            # any service name. These describe the DNS view, distinct from the
            # `proxy.*` options below which describe the Caddy view.
            reverseProxy = mkOption {
              type = types.bool;
              default = true;
              description = "Reached through the zone gateway reverse proxy (DNS points to the gateway LAN IP)";
            };
            uniquePerZone = mkOption {
              type = types.bool;
              default = false;
              description = "At most one instance allowed per zone (generator validation)";
            };
            externalAccess = mkOption {
              type = types.bool;
              default = false;
              description = "www-zone service reachable from the LAN via a fixed host IP (e.g. headscale, turn)";
            };

            # Folders and files to persist
            persist.dirs = mkOption {
              type = types.listOf types.str;
              default = [ ];
              example = [ "/var/lib/immich" ];
              description = "Service persistant dirs";
            };
            persist.files = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Service persistant files";
            };
            persist.dbDirs = mkOption {
              type = types.listOf types.str;
              default = [ ];
              example = [ config.services.postgresql.dataDir ];
              description = "Service persistant dirs with database(s)";
            };
            persist.dbFiles = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Service database file(s)";
            };
            persist.varDirs = mkOption {
              type = types.listOf types.str;
              default = [ ];
              example = [
                "/var/cache"
                "/var/log"
              ];
              description = "Variable secondary files (log, cache, etc.)";
            };
            persist.mediaDirs = mkOption {
              type = types.listOf types.str;
              default = [ ];
              example = [
                "/var/lib/immich/encoded-video"
                "/var/lib/immich/library"
                "/var/lib/immich/upload"
              ];
              description = "Service media dirs (pictures, videos, big files)";
            };

            # Reverse proxy settings
            proxy.enable = mkOption {
              type = types.bool;
              default = true;
              description = "Whether to create virtualHost configuration (false for services that manage their own)";
            };
            proxy.isProtected = mkOption {
              type = types.bool;
              default = false;
              description = "Oauth2 protected service";
            };
            proxy.allowedGroups = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Kanidm groups allowed on this protected service (empty = any authenticated user)";
            };
            proxy.isInternal = mkOption {
              type = types.bool;
              default = false;
              description = "Bind service on internal interface only (not internet accessible)";
            };
            proxy.hasReverseProxy = mkOption {
              type = types.bool;
              default = true;
              description = "This is a reverse proxy (or another virtualhost configuration via extraConfig)";
            };
            proxy.defaultService = mkOption {
              type = types.bool;
              default = false;
              description = "Is the default service";
            };
            proxy.servicePort = mkOption {
              type = types.nullOr types.port;
              default = null;
              description = "Service internal port";
            };
            proxy.preExtraConfig = mkOption {
              type = types.lines;
              default = "";
              description = "Extra caddy virtualHost configuration (prefix)";
            };
            proxy.extraConfig = mkOption {
              type = types.lines;
              default = "";
              description = "Extra caddy virtualHost configuration";
            };
            proxy.extraGlobalConfig = mkOption {
              type = types.lines;
              default = "";
              description = "Extra caddy configuration";
            };
            proxy.scheme = mkOption {
              type = types.str;
              default = "http";
              example = "https";
              description = "Internal service scheme (http / https)";
            };
          };
        })
      );
    };

    # Registry resolved against the topology, for the `services/` sub-modules:
    # `services` (`{ name; params; enable; displayOnHomepage; proxy; }`), then
    # this zone's `hasProtectedServices` and SSO anchor `authHost` (or null).
    darkone.system.services.resolved = mkOption {
      type = types.raw;
      internal = true;
      readOnly = true;
      default = { inherit services hasProtectedServices authHost; };
      defaultText = "computed from `service` and the network topology";
      description = "Resolved service registry.";
    };
  };

  config = mkIf cfg.enable {

    # Add services to homepage
    # TODO: widgets params integration in service params / sops
    darkone.service.homepage = mkIf isGateway {
      localServices = mkHomeSection (
        filter (srv: srv.params.zone == zone.name && !srv.params.global) homepageServices
      );
      globalServices = mkHomeSection (filter (srv: srv.params.global) homepageServices);
      remoteServices = mkHomeSection (
        filter (srv: srv.params.zone != zone.name && !srv.params.global) homepageServices
      );
    };
  };
}
