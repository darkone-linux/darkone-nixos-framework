# A full-configured headscale service for HCS.
#
# The tailnet ACL policy is generated from the topology (zones, hosts, users)
# by `dnfLib.mkHeadscalePolicy`, validated by `headscale policy check` at build
# time, then reloaded on change (SIGHUP) without restarting headscale.
#
# - Machines are tagged: `tag:hcs`, `tag:gw-<zone>`, `tag:admin` (host whose
#   `groups` contains `admin`).
# - Machines and zone LANs reach each other. Personal devices: DNS and HTTPS
#   on the HCS, HTTPS on zone gateways (every zone for admins, else their
#   `zone-*` groups). SSH from admin stations and `policy.adminDevices`.
# - Personal devices log in through Kanidm (OIDC), for members of the Kanidm
#   `tailnet` group; their keys expire after `nodeExpiry`.
#
# Sub-modules (`headscale/`):
# - `dns.nix`: unbound, the tailnet pivot DNS, and its `tailnet-machines` view;
# - `audit.nix`: `headscale-audit`, live nodes against the declared topology;
# - `enroll.nix`: `dnf-tailnet-enroll`, behind `just tailnet-enroll`.
#
# ```nix
# darkone.service.headscale.policy.adminDevices.phone-alice = "100.64.0.9";
# ```
#
# :::caution[Open mode]
# `policy.enforce = false` keeps the identities but allows all traffic: for a
# migration only, while nodes get tagged.
# :::
#
# :::note[Kanidm outage]
# headscale still starts without Kanidm and falls back to CLI registration
# until its next restart. Registered nodes are unaffected.
# :::

# TODO: works but can be simplified / optimized.
{
  lib,
  dnfLib,
  pkgs,
  config,
  network,
  host,
  hosts,
  users,
  ...
}:
let
  cfg = config.darkone.service.headscale;
  srv = config.services.headscale;
  inherit (dnfLib.constants) tailnetDomain;
  defaultParams = {
    inherit (network.coordination) domain;
    description = "Headscale DNF service";
    ip = srv.address;
    global = true;
    noRobots = false;
  };
  hcsTailnetIpv4 = network.zones.www.gateway.vpn.ipv4;
  params = dnfLib.extractServiceParams host network "headscale" defaultParams;
  inherit
    (dnfLib.mkOidcContext {
      name = "headscale";
      inherit params network hosts;
    })
    clientId
    secret
    idmUrl
    ;
  oidc = dnfLib.mkKanidmEndpoints idmUrl clientId;

  # headscale sets up OIDC once, at startup: start after the issuer (Kanidm
  # behind Caddy) is served when it runs on this host.
  issuerUnits =
    lib.optional config.darkone.service.idm.enable "kanidm.service"
    ++ lib.optional config.services.caddy.enable "caddy.service";

  policy = dnfLib.mkHeadscalePolicy {
    inherit network hosts users;
    inherit (cfg.policy)
      enforce
      adminDevices
      exitNodeSources
      extraAcls
      extraHosts
      ;
  };
  policyFile = (pkgs.formats.json { }).generate "headscale-policy.json" policy;

  # Throwaway offline instance: a rejected policy fails the build instead of
  # the running server. Users are unknown here, tags, groups and aliases are
  # still checked.
  checkedPolicy =
    pkgs.runCommand "headscale-policy.hujson" { nativeBuildInputs = [ srv.package ]; }
      ''
        export HOME=$TMPDIR
        cat > config.yaml <<EOF
        server_url: http://127.0.0.1:8080
        listen_addr: 127.0.0.1:8080
        noise:
          private_key_path: $TMPDIR/noise.key
        prefixes:
          v4: ${dnfLib.constants.tailnetIpv4Cidr}
          v6: fd7a:115c:a1e0::/48
        derp:
          server:
            enabled: false
          urls: []
          auto_update_enabled: false
        database:
          type: sqlite
          sqlite:
            path: $TMPDIR/db.sqlite
        dns:
          magic_dns: true
          override_local_dns: false
          base_domain: ${tailnetDomain}
        unix_socket: $TMPDIR/headscale.sock
        EOF
        headscale --config config.yaml --force policy check \
          --bypass-grpc-and-access-database-directly -f ${policyFile}
        cp ${policyFile} $out
      '';

  # `headscale-audit`: the declared tailnet, compared with the live node list.
  auditSpec = (pkgs.formats.json { }).generate "headscale-audit-spec.json" (
    dnfLib.mkHeadscaleAuditSpec {
      inherit network hosts users;
      inherit (cfg.policy) adminDevices;
    }
  );

in
{
  options = {
    darkone.service.headscale.enable = lib.mkEnableOption "Enable headscale DNF service";
    darkone.service.headscale.enableGRPC = lib.mkEnableOption "Open GRPC TCP port";

    darkone.service.headscale.nodeExpiry = lib.mkOption {
      type = lib.types.str;
      default = "180d";
      description = "Key expiry of personal devices (`0`: never). Tagged machines never expire.";
    };

    darkone.service.headscale.policy = {
      enforce = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Default-deny tailnet ACLs. `false` allows all traffic, for a migration only.";
      };
      adminDevices = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          phone-alice = "100.64.0.9";
        };
        description = "Personal devices granted SSH on every machine and zone: name -> tailnet IPv4.";
      };
      exitNodeSources = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "group:admins" ];
        description = "Policy sources allowed to use the HCS as exit node.";
      };
      extraHosts = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          printer = "10.1.3.1/32";
        };
        description = "Extra policy host aliases (name -> CIDR), to use in `extraAcls`.";
      };
      extraAcls = lib.mkOption {
        type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
        default = [ ];
        example = [
          {
            action = "accept";
            src = [ "group:admins" ];
            dst = [ "printer:631" ];
          }
        ];
        description = "ACL rules appended after the generated ones.";
      };
    };

    # Values shared with the `headscale/` sub-modules.
    darkone.service.headscale.shared = lib.mkOption {
      type = lib.types.raw;
      internal = true;
      readOnly = true;
      default = {
        inherit
          policy
          auditSpec
          idmUrl
          hcsTailnetIpv4
          ;
      };
      defaultText = "computed";
      description = "Headscale values shared with the `headscale/` sub-modules.";
    };
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.headscale = {
        displayOnHomepage = false;
        inherit defaultParams;
        persist.dirs = [ "/var/lib/headscale" ];
        proxy.servicePort = srv.port;
      };

      # Kanidm OAuth2 client template. Scopes are mapped to `tailnet` only:
      # Kanidm turns other users away before headscale checks the group.
      darkone.service.idm.oauth2.headscale = {
        displayName = "Headscale VPN";
        imageFile = ./../../assets/app-icons/headscale.svg;
        redirectPaths = [ "/oidc/callback" ];
        landingPath = "/";

        # Short `preferred_username`: the policy names `alice@`, not the SPN.
        preferShortUsername = true;
        extra.scopeMaps.tailnet = [
          "openid"
          "email"
          "profile"
          "groups"
        ];
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "headscale";

      # Unbound, the tailnet pivot DNS (`headscale/dns.nix`), is required
      systemd.services.headscale = {
        wants = [ "unbound.service" ];
        after = [ "unbound.service" ];
      };

      #------------------------------------------------------------------------
      # Headscale main configuration
      #------------------------------------------------------------------------

      services.headscale = {
        enable = true;
        settings = {

          # Public Headscale server URL
          server_url = "https://${params.fqdn}:443";

          # Configuration DNS
          dns = {

            # MagicDNS enabled (default)
            magic_dns = true;

            # `.internal` domain: tailnet names never leak to public DNS.
            base_domain = tailnetDomain;

            # Force headscale DNS config over node local DNS
            override_local_dns = false;

            nameservers = {

              # No global resolver: a roaming client keeps its local network DNS
              # for public names. Forced through the VPN, any flaky data path
              # (DERP only, UDP blocked) broke resolution entirely.
              global = [ ];

              # Split DNS: internal names only reach HCS unbound, which pivots to
              # each zone gateway (cf. `headscale/dns.nix`).
              split.${network.domain} = [ hcsTailnetIpv4 ];
            };

            # Tailnet names only, no zone search domain.
            search_domains = [ tailnetDomain ];
          }; # dns
        };
      };

      #--------------------------------------------------------------------------
      # Firewall
      #--------------------------------------------------------------------------

      # https://headscale.net/stable/setup/requirements/#ports-in-use
      networking.firewall = {

        # Public: ACME challenge, tailnet clients + DERP, optional gRPC
        allowedTCPPorts = [
          80 # Caddy, let's encrypt
          443 # Tailscale clients, DERP server
          (lib.mkIf cfg.enableGRPC 50443) # gRPC
        ];

        allowedUDPPorts = [
          3478 # STUN, DERP server
        ];
      };
    })

    #------------------------------------------------------------------------
    # Tailnet ACL policy and node expiry
    #------------------------------------------------------------------------

    (lib.mkIf cfg.enable {

      # Stable path: a policy change leaves config.yaml and the unit untouched,
      # so it reloads headscale instead of restarting it.
      environment.etc."headscale/policy.hujson".source = checkedPolicy;

      services.headscale.settings = {
        policy.path = "/etc/headscale/policy.hujson";
        node.expiry = cfg.nodeExpiry;
      };

      # The nixpkgs unit has no reload; headscale re-reads the policy on SIGHUP.
      systemd.services.headscale = {
        reloadTriggers = [ checkedPolicy ];
        serviceConfig.ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
      };
    })

    #------------------------------------------------------------------------
    # Personal devices: OIDC login through Kanidm
    #------------------------------------------------------------------------

    (lib.mkIf (cfg.enable && idmUrl != null) {

      # Re-encrypted alias of the kanidm-owned OAuth2 secret, readable by
      # headscale (sops `key` field unmaps the master secret name).
      sops.secrets."${secret}-service" = {
        mode = "0400";
        owner = srv.user;
        key = secret;
      };

      services.headscale.settings.oidc = {

        # A Kanidm outage must not keep the control plane down: CLI
        # registration only, until the next restart.
        only_start_if_oidc_is_available = false;
        issuer = oidc.issuerUrl;
        client_id = clientId;
        client_secret_path = config.sops.secrets."${secret}-service".path;
        scope = [
          "openid"
          "profile"
          "email"
          "groups"
        ];

        # Kanidm sends groups as SPNs.
        allowed_groups = [ "tailnet@${network.domain}" ];
        pkce.enabled = true;
      };

      systemd.services.headscale = {
        wants = issuerUnits;
        after = issuerUnits;
        serviceConfig = {

          # Covers the wait loop below (default 90s would race it).
          TimeoutStartSec = "150s";

          # `after`/`wants` only mean kanidm.service's start job finished, not
          # that the OIDC discovery endpoint answers through Caddy yet (same
          # gap as `system/services/oauth2-proxy.nix`). Best-effort, never blocks:
          # starts with CLI fallback if the issuer stays unreachable.
          ExecStartPre = pkgs.writeShellScript "headscale-wait-oidc" ''
            url="${oidc.openidConfigUrl}"
            for _ in $(${pkgs.coreutils}/bin/seq 1 15); do
              code=$(${pkgs.curl}/bin/curl -sS -o /dev/null -w '%{http_code}' --max-time 4 "$url" || true)
              [ -n "$code" ] && [ "$code" != "000" ] && exit 0
              ${pkgs.coreutils}/bin/sleep 3
            done
            echo "headscale: OIDC issuer unreachable after ~100s, starting with CLI fallback" >&2
            exit 0
          '';
        };
      };
    })
  ];
}
