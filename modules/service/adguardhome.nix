# Full-configured AdGuard Home for local gateway / router.
#
# :::note
# This configuration reads the `network` conf in `config.yaml` file.
# It uses the [DNF dnsmasq module](/ref/modules/#-darkoneservicednsmasq) as upstream DNS and DHCP.
# :::

{
  lib,
  dnfLib,
  dnfConfig,
  config,
  pkgs,
  network,
  zone,
  host,
  ...
}:
let
  cfg = config.darkone.service.adguardhome;
  agh = config.services.adguardhome;

  # ADH and DNSMASQ are on the same host.
  dnsmasqAddr = "127.0.0.1:" + (toString config.services.dnsmasq.settings.port);

  # Local PTR domain prefix derived from the LAN network address.
  inherit (dnfLib) extractReversePrefix;

  adminHash = config.sops.secrets.adguardhome-admin-password-hash.path;

  # AdGuard keeps its credentials in its own state file: anything passed
  # through `settings` lands world-readable in the nix store. Runs as root
  # (`+` prefix), the unit itself being a DynamicUser barred from /run/secrets.
  setAdminUser = pkgs.writeShellScript "adguardhome-admin-user" ''
    set -eu
    conf="$STATE_DIRECTORY/AdGuardHome.yaml"

    # Rewritten through the existing inode: the file belongs to the dynamic
    # user, which saves web interface changes back into it.
    HASH="$(${pkgs.coreutils}/bin/cat ${adminHash})" \
      ${pkgs.yq-go}/bin/yq '.users = [{"name": "admin", "password": strenv(HASH)}]' \
      "$conf" > "$conf.new"
    ${pkgs.coreutils}/bin/cat "$conf.new" > "$conf"
    ${pkgs.coreutils}/bin/rm -f "$conf.new"
  '';
in
{
  options = {
    darkone.service.adguardhome.enable = lib.mkEnableOption "Enable local adguardhome service";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.adguardhome = {
        defaultParams = {
          title = "AdGuardHome";
          description = "Ad and tracker blocker";
          icon = "adguard-home";
          ip = "127.0.0.1";
        };
        proxy.servicePort = agh.port;
        proxy.isInternal = true;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "adguardhome";

      #------------------------------------------------------------------------
      # Resolver readiness gate
      #------------------------------------------------------------------------

      # AdGuardHome owns :53 (resolv.conf points at 127.0.0.1) but its unit is
      # Type=simple: systemd marks it active as soon as the process forks,
      # ~20s before the DNS proxy actually binds. On a gateway that gap is
      # structural, not incidental: at startup ADH reverse-resolves its own
      # tailnet address through MagicDNS (100.100.100.100), unreachable until
      # tailscaled is up, and tailscaled needs a working resolver to reach the
      # control plane. The upstream timeout breaks the loop, but every unit
      # resolving a name meanwhile races a deaf socket and fails hard (nfs
      # mounts, OIDC provisioning...).
      #
      # `nss-lookup.target` is the systemd contract for "names resolve here":
      # gate it on a resolver that answers, so consumers only need the usual
      # `after = [ "nss-lookup.target" ]`.
      systemd.services.dns-ready = {
        description = "Wait for the local DNS resolver to answer";
        after = [
          "adguardhome.service"
          "dnsmasq.service"
        ];
        before = [ "nss-lookup.target" ];
        wantedBy = [
          "nss-lookup.target"
          "multi-user.target"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = "120s";
        };

        # Probes the host's own name: answered locally by dnsmasq, so a reply
        # proves the whole chain is up without depending on any upstream. dig
        # exits 9 while nothing listens, 0 on any answer (NXDOMAIN included).
        #
        # Never fails: a resolver still deaf after the deadline must delay the
        # boot, not break every unit ordered after this gate.
        script = ''
          for _ in $(${pkgs.coreutils}/bin/seq 60); do
            ${pkgs.dnsutils}/bin/dig +tries=1 +timeout=1 @127.0.0.1 \
              ${host.hostname} > /dev/null 2>&1 && exit 0
            ${pkgs.coreutils}/bin/sleep 1
          done
          echo "local resolver still silent, giving up the wait"
        '';
      };

      #------------------------------------------------------------------------
      # AdguardHome Service
      #------------------------------------------------------------------------

      # Own admin secret, never the fleet default password. Declarative: a
      # password changed from the web interface is overwritten at next start.
      sops.secrets.adguardhome-admin-password-hash = { };

      systemd.services.adguardhome.serviceConfig.ExecStartPre = lib.mkAfter [ "+${setAdminUser}" ];

      # TODO: clients from config.yaml
      services.adguardhome = {
        enable = true;

        # DHCP is managed by dnsmasq
        allowDHCP = false;

        # Web interface default host + port (target for reverse proxy)
        port = dnfConfig.network.ports.adguardhome;
        host = "127.0.0.1"; # ADH and RP are on the same host

        # Allow changes made on the AdGuard Home web interface to persist between service restarts.
        mutableSettings = true;

        settings = {
          http = {
            address = "${toString agh.host}:${toString agh.port}";
            session_ttl = "720h";
          };
          auth_attempts = 5;
          block_auth_min = 1;
          language = zone.lang;

          # adguardhome is a dnsmasq upstream
          dns = {
            port = 53;
            bind_hosts = [ "0.0.0.0" ];

            # Upstream default is 10s, and a startup query is retried twice
            # before the DNS proxy binds :53 — 20s of deaf resolver whenever an
            # upstream is unreachable (typically MagicDNS while the tailnet is
            # still coming up). Every upstream here is either local (dnsmasq,
            # ~1ms) or a public resolver, and `fallback_dns` already catches the
            # slow ones, so a short deadline costs nothing and bounds the gap.
            upstream_timeout = "3s";

            # DOMAIN ROUTING
            # 1. Simple names → dnsmasq
            # 2. Local domains → dnsmasq
            # 3. Everything else → ADH DNS
            upstream_dns = [

              # Unqualified names (hosts, services)
              # https://github.com/AdguardTeam/Adguardhome/wiki/Configuration#specifying-upstreams-for-domains
              ("[//]" + dnsmasqAddr)

              # Local names
              ("[/" + network.domain + "/]" + dnsmasqAddr)

              # Zone-neutral roaming names (cache services), answered by dnsmasq
              ("[/" + dnfLib.constants.roamingDomain + "/]" + dnsmasqAddr)

              # Local dns reverse
              ("[/" + (extractReversePrefix zone.ipPrefix) + ".in-addr.arpa/]" + dnsmasqAddr)
            ]
            ++

              # Reverse DNS upstreams for other subnets
              (lib.mapAttrsToList
                (_: z: "[/${extractReversePrefix z.ipPrefix}.in-addr.arpa/]${z.gateway.lan.ip}:5353")
                (
                  lib.filterAttrs (
                    _: z: (lib.hasAttrByPath [ "gateway" "lan" "ip" ] z) && z.name != host.zone
                  ) network.zones
                )
              )

            ++ [
              (lib.mkIf network.coordination.enable "[/100.in-addr.arpa/]100.100.100.100")

              "94.140.14.14"
              "94.140.15.15"
              "https://dns.adguard-dns.com/dns-query"
            ];
            bootstrap_dns = [
              "9.9.9.10"
              "149.112.112.10"
              "2620:fe::10"
              "2620:fe::fe:10"
            ];
            fallback_dns = [
              "8.8.8.8"
              "8.8.4.4"
              "1.1.1.1"
            ];

            # Do not append a suffix to local names
            local_domain_name = "";

            # dnsmasq is an upstream dns for reverse DNS
            # List of upstream DNS servers to resolve PTR requests for addresses inside locally-served networks.
            # If empty, AdGuard Home will automatically try to get local resolvers from the OS.
            local_ptr_upstreams = [ dnsmasqAddr ];

            # If AdGuard Home should use private reverse DNS servers.
            use_private_ptr_resolvers = true;

            # Cache must be disabled to not disturb dnsmasq configuration changes
            cache_enabled = false;

            # Retrieve client ips from dnsmasq (Active EDNS Client Subnet)
            # Note: deactivated -> dnsmasq forward external queries to adguard
            #ecs = true;
          };
          tls.enable = false;
          filtering = {
            blocking_mode = "default";
            protection_enabled = true;
            filtering_enabled = true;
            parental_enabled = false;
            safe_search = {
              enabled = true;
            };
          };

          # The following notation uses map
          # to not have to manually create {enabled = true; url = "";} for every filter
          # This is, however, fully optional
          filters =
            map
              (url: {
                enabled = true;
                inherit url;
              })
              [
                "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt"
                "https://adguardteam.github.io/HostlistsRegistry/assets/filter_11.txt"
                "https://adguardteam.github.io/HostlistsRegistry/assets/filter_59.txt"
              ];
          user_rules = [
            "! Youtube kids"
            "@@||youtubekids.com^"
            "@@||ytimg.com^"
            "@@||googlevideo.com^"
          ];
          dhcp.enable = false;
        };
      };
    })
  ];
}
