# Kanidm (identity manager) DNF Service.
#
# :::note[Secrets are generated, not typed]
# `just configure-admin-host` creates every entry this module reads:
# the break-glass account passwords (`kanidm-admin-password`,
# `kanidm-idm-admin-password`), the self-signed pair of the internal HTTPS
# listener (`kanidm-tls-chain` / `kanidm-tls-key`, 10 years, CN=127.0.0.1) and
# one `oidc-secret-<client>` per provisioned OAuth2 client. Read them back with
# `just sops` on the rare occasions an admin needs one.
# :::
#
# Sub-modules (`idm/`):
# - `replication.nix`: multi-zone read-only replication, HCS to zone gateways;
# - `provision.nix`: OAuth2 clients (template registry), groups and persons.
#
# #### Replication (`replication.nix`)
#
# Automatic, derived from where `idm` is declared:
# - idm on the HCS only, or on a gateway without HCS: one instance;
# - on the HCS and >= 1 zone gateway: the HCS supplies (WriteReplica), each
#   idm gateway consumes.
#
# Two-step bootstrap: `just apply` generates every replication certificate
# (gateways stay WriteReplicaNoUI), then `just idm-sync-certs` + `just apply`
# adds the partners and flips the gateways to ReadOnlyReplica.
#
# #### Provisioning (`provision.nix`)
#
# Every OIDC-capable service module contributes a client template to
# `darkone.service.idm.oauth2`; one client is provisioned per (template,
# instance), merged by `clientId` across zones. Never on a replication
# consumer: it mirrors the HCS.

{
  lib,
  dnfLib,
  dnfConfig,
  network,
  host,
  zone,
  config,
  pkgs,
  ...
}:
let
  inherit (lib)
    listToAttrs
    mkEnableOption
    mkIf
    mkMerge
    ;
  cfg = config.darkone.service.idm;
  srvPort = dnfConfig.network.ports.kanidm;
  inherit (config.sops) secrets;
  isHcs = dnfLib.isHcs host zone network;
  inherit (cfg.replication) isMainReplica;

  defaultParams = {
    title = "Authentification";
    description = "Global authentication for DNF services";
    ip = "127.0.0.1";
    icon = "kanidm";
  };
  params = dnfLib.extractServiceParams host network "idm" defaultParams;
in
{
  options = {
    darkone.service.idm.enable = mkEnableOption "Enable local SSO with Kanidm";
  };

  config = mkMerge [

    #========================================================================
    # DNF Service configuration
    #========================================================================

    {
      darkone.system.services.service.idm = {
        inherit defaultParams;
        persist.dirs = [ "/var/lib/kanidm" ];
        proxy.enable = isMainReplica;
        proxy.servicePort = srvPort;
        proxy.scheme = "https";
        proxy.extraConfig = ''
          {
            transport http {
              tls_insecure_skip_verify
            }
            header_up Host {host}
          }
        '';
      };
    }

    (mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "idm";

      # SMTP Relay, only where `network.smtp` gives it somewhere to relay to.
      darkone.service.postfix.enable = mkIf (network ? smtp) true;

      #========================================================================
      # Kanidm user & secrets
      #========================================================================

      # Kanidm internal secrets. `oidc-secret-internal` backs oauth2-proxy
      # (`system/services/oauth2-proxy.nix`), not a provisioned client.
      sops.secrets = listToAttrs (
        map
          (item: {
            name = item;
            value = {
              mode = "0400";
              owner = "kanidm";
            };
          })
          [
            "kanidm-idm-admin-password"
            "kanidm-admin-password"
            "kanidm-tls-chain"
            "kanidm-tls-key"
            "oidc-secret-internal"
          ]
      );

      #========================================================================
      # Kanidm service
      #========================================================================

      # Upstream unit names: the server is `kanidm` (only the daemon binary is
      # `kanidmd`), the PAM/NSS resolver is `kanidm-unixd`.
      systemd.services = {
        kanidm = {

          # Sendmail permissions
          path = [
            pkgs.postfix
            pkgs.coreutils
          ];

          # At boot, bring the tailnet up before kanidm reaches its peers (no-op
          # where tailscaled is absent: missing units are ignored in wants/after).
          after = [ "tailscaled.service" ];
          wants = [ "tailscaled.service" ];
        };
      }

      # `unix.enable` follows the same condition, so the unit exists exactly
      # where this block applies. `optionalAttrs` and not `mkIf`: an `mkIf false`
      # on a leaf still materialises the attribute name, and `systemd.services`
      # would emit an empty phantom unit on every other node.
      // lib.optionalAttrs (!isHcs) {

        # kanidm-unixd resolves `default_shell` at runtime and must be able to
        # read the shell paths.
        # -> https://github.com/kanidm/kanidm/blob/392a10afbc19759d1431025a2daee0dd903b2733/examples/unixd#L77
        kanidm-unixd.serviceConfig.ReadOnlyPaths = [
          "/run/current-system/sw/bin"
          "/etc/profiles/per-user/nix/bin"
          "${pkgs.zsh}/bin"
        ];
      };

      # Kanidm binds VPN addresses (LDAP on the tailscale IP, replication on
      # the VPN IP) that may not be assigned yet when the unit (re)starts —
      # typically during a nixos-rebuild switch while tailscaled reconfigures.
      # Non-local bind lets the listener come up regardless, instead of dying
      # with "cannot assign requested address" at every fleet deployment.
      boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;

      #========================================================================
      # Kanidm instance
      #========================================================================

      # Kanidm main instance
      services.kanidm = {

        # Pinned on purpose: nixpkgs exposes no default `kanidm` attribute, and
        # upstream only supports upgrades between ADJACENT releases — a version
        # goes EOL 30 days after its successor ships, then nixpkgs marks it
        # insecure and evaluation fails. Bump one minor at a time, after
        # `kanidmd domain upgrade-check` passes on the running node.
        package = pkgs.kanidm_1_11.withSecretProvisioning;

        #----------------------------------------------------------------------
        # SERVER
        #----------------------------------------------------------------------

        # Manages the DB (Argon2id) and exposes API, Web + LDAP bridge interfaces (read-only).
        # -> https://github.com/kanidm/kanidm/blob/master/examples/server.toml
        server = {
          enable = true;
          settings = {
            bindaddress = "${params.ip}:${toString srvPort}";

            # Default is info
            #log_level = "debug";

            # The domain that Kanidm manages. Must be below or equal to the domain specified in serverSettings.origin.
            # Always set (same value network-wide). The kanidm nixpkgs module
            # asserts `domain == null -> role is a Write replica`, i.e. a
            # ReadOnlyReplica MUST keep a non-null domain (it simply matches the
            # supplier's, which is identical here since the whole net shares one).
            domain = network.domain;

            # The origin of the Kanidm instance.
            origin = params.href;

            # Address and port the LDAP server is bound to. Setting this to null disables the LDAP interface.
            ldapbindaddress = mkIf isMainReplica "${host.vpnIp}:636";

            # Internal TLS certificate. Self-signed (see the file header):
            # Caddy fronts this listener with `tls_insecure_skip_verify`, so it
            # never has to chain to anything.
            tls_chain = secrets.kanidm-tls-chain.path;
            tls_key = secrets.kanidm-tls-key.path;
          };
        };

        #----------------------------------------------------------------------
        # CLIENT
        #----------------------------------------------------------------------

        # Web/CLI client
        client = {
          enable = true;
          settings = {
            uri = params.href;
            connect_timeout = 86400; # 24h (seconds)
          };
        };

        #----------------------------------------------------------------------
        # UNIXD / PAM / NSS (WIP)
        #----------------------------------------------------------------------

        # Unix daemon configuration for PAM/NSS (replaces SSSD)
        unix = {
          enable = !isHcs;
          settings = {
            default_shell = "/etc/profiles/per-user/nix/bin/zsh";

            # Renamed in the unixd v2 config: the PAM login groups now live under
            # the `[kanidm]` provider table (nixpkgs asserts this).
            kanidm.pam_allowed_login_groups = [ "posix" ];
          };
        };
      };
    })
  ];
}
