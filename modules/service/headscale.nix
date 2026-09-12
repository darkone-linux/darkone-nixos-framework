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
# - `headscale-audit` (every 15 min) compares the live nodes with the declared
#   topology: metrics for the `dnf-headscale-<zone>` alerts, details in its
#   journal. It never tags nor deletes.
# - `dnf-tailnet-enroll` backs `just tailnet-enroll`: single-use keys tagged
#   from the declared topology, declared name and tags on the enrolled node.
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
  zone,
  ...
}:
let
  cfg = config.darkone.service.headscale;
  srv = config.services.headscale;
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

  policyFile = (pkgs.formats.json { }).generate "headscale-policy.json" (
    dnfLib.mkHeadscalePolicy {
      inherit network hosts users;
      inherit (cfg.policy)
        enforce
        adminDevices
        exitNodeSources
        extraAcls
        extraHosts
        ;
    }
  );

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
          v4: 100.64.0.0/10
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
          base_domain: tailnet.internal
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

  # node_exporter textfile collector dir (same value as monitoring.nix).
  textfileDir = "/var/lib/node-exporter-textfile";

  # Checks on the reduced node list; `$mode` selects metrics or journal lines.
  # Label values are DNS names and logins: anything else is flattened to `_`.
  auditJq = pkgs.writeText "headscale-audit.jq" ''
    def lv: tostring | gsub("[^A-Za-z0-9_.@-]"; "_");
    def flag(b): if b then 1 else 0 end;

    $spec[0] as $s
    | . as $nodes
    | ($nodes | map(select(.tags != []))) as $tagged
    | ($nodes | map(select(.tags == []))) as $personal
    | [
        ($s.nodes[] as $e
          | ($nodes | map(select(.name == $e.name)) | first) as $n
          | {
              node: $e.name,
              missing: ($n == null and $e.required),
              tag_mismatch: ($n != null and $n.tags != $e.tags),
              ip_drift: ($n != null and $e.ipv4 != null and $n.ipv4 != $e.ipv4)
            }),
        ($s.adminDevices | to_entries[]
          | .value as $ip
          | {
              node: .key,
              missing: false,
              tag_mismatch: false,
              ip_drift: ($personal | map(select(.ipv4 == $ip)) | length == 0)
            })
      ] as $checks
    | (
        [$tagged[] | select((.name | IN($s.nodes[].name)) | not)]
        + [$personal[] | select((.user | IN($s.users[])) | not)]
      ) as $unexpected
    | if $mode == "metrics" then
        ($checks[]
          | "dnf_headscale_node_missing{node=\"\(.node | lv)\"} \(flag(.missing))",
            "dnf_headscale_node_tag_mismatch{node=\"\(.node | lv)\"} \(flag(.tag_mismatch))",
            "dnf_headscale_node_ip_drift{node=\"\(.node | lv)\"} \(flag(.ip_drift))"),
        ($unexpected[]
          | "dnf_headscale_unexpected_node{node=\"\(.name | lv)\",user=\"\(.user | lv)\"} 1"),
        ($personal[] | select(.expiry != null)
          | "dnf_headscale_node_expiry_timestamp_seconds{node=\"\(.name | lv)\",user=\"\(.user | lv)\"} \(.expiry)")
      else
        ($checks[] | select(.missing) | "missing: \(.node)"),
        ($checks[] | select(.tag_mismatch) | "tag mismatch: \(.node)"),
        ($checks[] | select(.ip_drift) | "ip drift: \(.node)"),
        ($unexpected[] | "unexpected: \(.name) (user \(.user))")
      end
  '';

  auditScript = pkgs.writeShellScript "headscale-audit" ''
    set -euo pipefail
    hs() { ${srv.package}/bin/headscale --config /etc/headscale/config.yaml "$@" </dev/null; }
    jq=${pkgs.jq}/bin/jq

    # Reduce at once: the raw list carries pre-auth keys in clear, never printed.
    nodes=$(hs nodes list -o json | $jq -c '[.[] | {
      name: .given_name,
      user: .user.name,
      tags: ((.tags // []) | sort),
      ipv4: ([.ip_addresses[]? | select(test("^[0-9.]+$"))] | first),
      expiry: (.expiry.seconds // null)
    }]')
    audit() { $jq -r --slurpfile spec ${auditSpec} --arg mode "$1" -f ${auditJq} <<<"$nodes"; }
    audit findings

    policy=1
    if ! hs policy check -f /etc/headscale/policy.hujson >/dev/null 2>&1; then
      echo "policy: fails headscale policy check"
      policy=0
    elif [ "$(hs policy get | $jq -S -c .)" != "$($jq -S -c . /etc/headscale/policy.hujson)" ]; then
      echo "policy: served policy differs from /etc/headscale/policy.hujson"
      policy=0
    fi
    ${lib.optionalString (idmUrl != null) ''

      # headscale never retries OIDC: a fallback warning in this run's journal holds.
      oidc=1
      run=$(${pkgs.systemd}/bin/systemctl show -p InvocationID --value headscale.service)
      hits=$(${pkgs.systemd}/bin/journalctl -q -o cat _SYSTEMD_INVOCATION_ID="$run" \
        | ${pkgs.gnugrep}/bin/grep -c 'falling back to CLI based authentication' || true)
      if [ "$hits" != 0 ]; then
        echo "oidc: fell back to CLI registration at startup"
        oidc=0
      fi
    ''}

    # Best-effort metrics: only supervised hosts have the collector dir.
    [ -d ${textfileDir} ] || exit 0
    tmp=$(${pkgs.coreutils}/bin/mktemp ${textfileDir}/.headscale.XXXXXX)
    trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT
    {
      audit metrics
      echo "dnf_headscale_policy_valid $policy"
      ${lib.optionalString (idmUrl != null) ''echo "dnf_headscale_oidc_available $oidc"''}
      echo "dnf_headscale_audit_last_success_timestamp_seconds $(${pkgs.coreutils}/bin/date +%s)"
    } > "$tmp"

    # mktemp creates 0600; node_exporter reads as a non-root user.
    ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
    ${pkgs.coreutils}/bin/mv -f "$tmp" ${textfileDir}/headscale.prom
  '';

  # Root side of `just tailnet-enroll`, reached through sudo. Tags and names
  # come from the declared topology only, never from the caller.
  enrollCmd = "dnf-tailnet-enroll";
  enrollBin = "/run/current-system/sw/bin/${enrollCmd}";
  enrollScript = pkgs.writeShellScriptBin enrollCmd ''
    set -euo pipefail
    hs() { ${srv.package}/bin/headscale --config /etc/headscale/config.yaml "$@" </dev/null; }
    jq=${pkgs.jq}/bin/jq
    die() {
      echo "${enrollCmd}: $*" >&2
      exit 1
    }
    usage="usage: ${enrollCmd} status <host> [nodeKey] | key <host> | adopt <host> <nodeKey>"

    cmd=''${1:-}
    host=''${2:-}
    nodeKey=''${3:-}
    [[ $host =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "$usage"
    declared=$($jq -c --arg h "$host" 'first(.nodes[] | select(.name == $h) | {tags, ipv4}) // null' ${auditSpec})

    # Reduced at once: the raw list carries pre-auth keys in clear.
    nodes() {
      hs nodes list -o json | $jq -c '[.[] | {
        id,
        name: .given_name,
        tags: ((.tags // []) | sort),
        ipv4: ([.ip_addresses[]? | select(test("^[0-9.]+$"))] | first),
        online: (.online // false),
        nodeKey: .node_key
      }]'
    }
    byKey() { $jq -c --arg k "$nodeKey" 'first(.[] | select($k != "" and .nodeKey == $k)) // null'; }

    case "$cmd" in

      # Declared identity, and the node holding the host's current node key.
      status)
        $jq -n -c --argjson d "$declared" --argjson n "$(nodes | byKey)" \
          '{declared: $d, node: (if $n == null then null else $n | del(.nodeKey) end)}'
        ;;

      # Single-use and short-lived: worthless once the host has registered.
      key)
        [ "$declared" != null ] || die "$host: no declared tailnet identity"
        tags=$($jq -r '.tags | join(",")' <<<"$declared")
        hs preauthkeys create --tags "$tags" --expiration 10m -o json | $jq -er '.key'
        ;;

      # Declared tags and name on the host's node. One declared host is one
      # machine: an offline homonym is the registration a reinstall left.
      adopt)
        [ "$declared" != null ] || die "$host: no declared tailnet identity"
        list=$(nodes)
        node=$(byKey <<<"$list")
        [ "$node" != null ] || die "$host: no node holds key $nodeKey"
        id=$($jq -r .id <<<"$node")
        want=$($jq -c .tags <<<"$declared")
        if [ "$($jq -c .tags <<<"$node")" != "$want" ]; then
          hs nodes tag -i "$id" --tags "$($jq -r 'join(",")' <<<"$want")" >/dev/null
          echo "node $id: tags set to $want" >&2
        fi
        if [ "$($jq -r .name <<<"$node")" != "$host" ]; then
          for stale in $($jq -r --arg h "$host" --argjson id "$id" \
            '.[] | select(.name == $h and .id != $id) | "\(.id):\(.online)"' <<<"$list"); do
            [ "''${stale#*:}" = false ] || die "node ''${stale%:*} named $host is online, not deleting it"
            hs nodes delete -i "''${stale%:*}" --force >/dev/null
            echo "node ''${stale%:*}: stale registration of $host deleted" >&2
          done
          hs nodes rename -i "$id" "$host" >/dev/null
          echo "node $id: renamed to $host" >&2
        fi
        nodes | $jq -c --argjson id "$id" 'first(.[] | select(.id == $id)) | del(.nodeKey)'
        ;;
      *) die "$usage" ;;
    esac
  '';
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

      #------------------------------------------------------------------------
      # Unbound (pivot DNS)
      #------------------------------------------------------------------------

      # Unbound is required by headscale
      systemd.services.headscale = {
        wants = [ "unbound.service" ];
        after = [ "unbound.service" ];
      };

      services.unbound = {
        enable = true;
        settings = {
          server = {
            interface = [
              "127.0.0.1"
              hcsTailnetIpv4
            ];
            access-control = [
              "127.0.0.1 allow"
              "100.64.0.0/10 allow"
            ];
            inherit (zone.unbound) local-data;
            harden-glue = true;
            harden-dnssec-stripped = true;
            use-caps-for-id = false;
            prefetch = true;
            edns-buffer-size = 1232;
            hide-identity = true;
            hide-version = true;
          };
          forward-zone =
            lib.mapAttrsToList
              (_: z: {
                name = "${z.domain}.";
                forward-addr = [ "${z.gateway.vpn.ipv4}" ];
              })
              (
                lib.filterAttrs (n: z: (lib.hasAttrByPath [ "gateway" "vpn" "ipv4" ] z) && n != "www") network.zones
              )
            ++ [
              {
                name = ".";
                forward-addr = [
                  "9.9.9.9#dns.quad9.net"
                  "149.112.112.112#dns.quad9.net"
                ];
                forward-tls-upstream = true; # Protected DNS
              }
            ];

          # Syntax error
          # local-zone = "\"tailnet.internal.\" static";
        };
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

            # Base domain for MagicDNS
            # -> Use an internal domain here to prevent names from
            #    leaking to the internet / external DNS. A name like vpn.mydomain.tld
            #    is not a good idea!
            base_domain = "tailnet.internal";

            # Force headscale DNS config over node local DNS
            override_local_dns = false;

            nameservers = {

              # No global resolver: roaming clients keep the DNS of the network
              # they are plugged into (box/café) for public names. Forcing global
              # through HCS unbound tunneled *all* DNS over the VPN, so any flaky
              # data-path (DERP-only, UDP-blocked) surfaced tailscale's "can't
              # reach the configured DNS servers" and broke resolution entirely.
              global = [ ];

              # Split-DNS: only internal names reach HCS unbound (100.100.100.100
              # stub → hcsTailnetIpv4), which then pivots to each zone gateway.
              split.${network.domain} = [ hcsTailnetIpv4 ];

              # Each zone suffix gets its own DNS server...
              # { "zone.domain.tld" = [ "100.64.x.x" ]; (...) };
              # NOTE: Headscale split-DNS only tells clients which DNS to query
              #        for which zone, it does not resolve or chain DNS itself.
              #        Unbound now serves as the pivot DNS server for zones.
              #        The previous split delegates main domain DNS handling to Unbound.
              # split = lib.concatMapAttrs (_: z: { "${z.domain}" = [ "${z.gateway.vpn.ipv4}" ]; }) (
              #   lib.filterAttrs (_: z: lib.hasAttrByPath [ "gateway" "vpn" "ipv4" ] z) network.zones
              # );
            };

            # Search domains
            # -> No search through headscale for now.
            # zone1.domain.tld, zone2.domain.tld, etc.
            # With MagicDNS enabled, your tailnet base_domain is always the first search domain.
            # search_domains = [
            #   srv.settings.dns.base_domain
            # ]
            # ++ lib.attrsets.mapAttrsToList (_: z: z.domain) hcsClientZones;
            #search_domains = lib.attrsets.mapAttrsToList (_: z: z.domain) hcsClientZones;
            search_domains = [ "tailnet.internal" ];

            # See if we should put global services here (DOES NOT WORK - NO EFFECT)
            # To use for global services?
            # https://github.com/juanfont/headscale/blob/9c4c017eac2e81908d2ae7d8d777e143a13a1772/config-example.yaml#L312
            # extra_records = lib.attrsets.mapAttrsToList (_: z: {
            #   name = "${z.gateway.hostname}.${z.domain}";
            #   type = "A";
            #   value = "100.64.${z.ipPrefix}";
            # }) hcsClientZones;
          }; # dns
        };
      };

      #--------------------------------------------------------------------------
      # Firewall
      #--------------------------------------------------------------------------

      # https://headscale.net/stable/setup/requirements/#ports-in-use
      networking.firewall = {

        # Open HTTP on all interfaces if not the gateway
        allowedTCPPorts = [
          80 # Caddy, let's encrypt
          443 # Tailscale clients, DERP server
          (lib.mkIf cfg.enableGRPC 50443) # gRPC
        ];

        allowedUDPPorts = [
          3478 # STUN, DERP server
        ];

        # Unbound (pivot DNS) must be reachable by tailnet nodes on the VPN IP.
        # With the nftables backend, the NixOS firewall and tailscale live in
        # separate base chains on the same input hook: tailscale's accept rule
        # no longer short-circuits the nixos-fw drop policy, so port 53 must be
        # opened explicitly on the tailscale interface. Unbound already limits
        # queries via access-control (100.64.0.0/10).
        interfaces.${config.services.tailscale.interfaceName} = {
          allowedTCPPorts = [ 53 ];
          allowedUDPPorts = [ 53 ];
        };
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
      };
    })

    #------------------------------------------------------------------------
    # Tailnet audit
    #------------------------------------------------------------------------

    (lib.mkIf cfg.enable {

      # Read-only: reports drift as metrics and journal lines, fixes nothing.
      # Root keeps its capabilities: the gRPC socket is `headscale`-group only.
      systemd.services.headscale-audit = {
        description = "Compare headscale nodes with the declared tailnet";
        after = [ "headscale.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = auditScript;
          ProtectSystem = "strict";
          ReadWritePaths = [ "-${textfileDir}" ];
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
        };
      };

      systemd.timers.headscale-audit = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "15min";
        };
      };
    })

    #------------------------------------------------------------------------
    # Tailnet enrollment
    #------------------------------------------------------------------------

    (lib.mkIf cfg.enable {
      environment.systemPackages = [ enrollScript ];

      # For the deploy user. NOLOG_OUTPUT: the minted key is printed, kept out
      # of the R39 I/O logs.
      security.sudo.extraRules = [
        {
          users = [ "nix" ];
          runAs = "root";
          commands = [
            {
              command = enrollBin;
              options = [
                "NOPASSWD"
                "NOLOG_INPUT"
                "NOLOG_OUTPUT"
              ];
            }
          ];
        }
      ];
      darkone.security.sudo.allowedRootRules = [ enrollBin ];
    })
  ];
}
