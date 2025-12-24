# LLDAP service for DNF SSO.
#
# :::note
# In a tailscale context, the master lldap instance is store in the HCS.
# Zones gateways synchronize user database from the headscale coordination server.
# :::

{
  lib,
  dnfLib,
  config,
  network,
  zone,
  host,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.users;

  # LLDAP service
  lldapSettings = config.services.lldap.settings;
  lldapUserDn = "admin";
  lldapStorage = "/var/lib/lldap";

  # LLDAP server location variables
  isHcs = dnfLib.isHcs host zone network;
  isGateway = dnfLib.isGateway host zone;

  # Détection du main server pour une configuration avec synchronisation.
  # TODO: voir si c'est utile...
  #isMainServer = ...;
  #needSync = network.coordination.enable && !isHcs;
  isMainServer = true;
  needSync = false;

  # Sync target
  hcsInternalIpv4 = network.zones.www.gateway.vpn.ipv4;
  lldapStorTmp = "/tmp/lldap";

  # Défini manuellement car lldapSettings.http_port n'est pas accessible si le service n'est pas enabled
  # https://search.nixos.org/options?channel=unstable&show=services.lldap.settings.http_port&query=services.lldap
  lldapHttpPort = 17170;

  # Service params
  defaultParams = {
    description = "Global user management for DNF services";
    icon = "openldap";
  };
  params = dnfLib.extractServiceParams host network "users" defaultParams;
in
{
  options = {
    darkone.service.users.enable = lib.mkEnableOption "Enable local user management with LLDAP (SSO)";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.users = {
        inherit defaultParams;
        displayOnHomepage = isMainServer;
        persist.dirs = [ lldapStorage ];
        proxy.enable = isMainServer;
        proxy.servicePort = lldapHttpPort;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.users.enable = true;
      };

      #------------------------------------------------------------------------
      # Tests
      #------------------------------------------------------------------------

      # Assertions for path prefixes
      assertions = [
        {
          assertion = isHcs || isGateway;
          message = "Users lldap service must be in HCS or Gateway";
        }
      ];

      #------------------------------------------------------------------------
      # LLDAP User
      #------------------------------------------------------------------------

      # Access to default password
      users.users.lldap = {
        isSystemUser = true;
        group = "lldap";
        extraGroups = [ "sops" ];
      };
      users.groups.lldap = { };

      #------------------------------------------------------------------------
      # LLDAP Service
      #------------------------------------------------------------------------

      services.lldap = {
        enable = true;
        settings = {
          http_host = params.ip;
          http_port = lldapHttpPort;

          # Sur headscale, il ne faut pas un fqdn qui pointe vers l'adresse externe.
          ldap_host = if isHcs then hcsInternalIpv4 else params.fqdn;

          ldap_user_dn = lldapUserDn;
          ldap_user_email = "${lldapUserDn}@${network.domain}";
          ldap_user_pass_file = config.sops.secrets.default-password.path;
          force_ldap_user_pass_reset = "always";
          ldap_base_dn =
            "dc=" + (lib.concatStringsSep ",dc=" (builtins.match "^([^.]+)\.([^.]+)$" "${network.domain}"));
        };
      };

      # Ldap access to local network only
      # TODO: lldapSettings.ldap_port n'a pas d'effet, corriger ça dans le module lldap de nixpkgs ?
      networking.firewall = lib.setAttrByPath (dnfLib.getInternalInterfaceFwPath host zone) {
        allowedTCPPorts = [
          (lib.mkIf (!isGateway) lldapSettings.http_port)
          lldapSettings.ldap_port
        ];
      };

      #------------------------------------------------------------------------
      # Users sync
      #------------------------------------------------------------------------

      # Caddy storage directory creation if needed
      systemd.tmpfiles.rules = lib.optional needSync "d ${lldapStorage} 0750 nobody nogroup -";

      # TLS certificates (caddy storage) sync service
      systemd.services.sync-lldap = lib.mkIf needSync {
        description = "Sync Caddy certificates from VPS via Tailscale";
        after = [ "tailscaled.service" ];
        wants = [ "tailscaled.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          ExecStart = pkgs.writeShellScript "sync-lldap" ''

            # Sync from HCS with nix user
            /run/current-system/sw/bin/mkdir -p ${lldapStorTmp}
            ${pkgs.coreutils}/bin/chown -R nix ${lldapStorTmp}

            # LLDAP users extraction with nix (who have keys)
            /run/wrappers/bin/sudo -u nix ${pkgs.rsync}/bin/rsync \
              -avz \
              --delete \
              --timeout=30 \
              -e "${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=accept-new" \
              --rsync-path="sudo -u root rsync" \
              nix@${hcsInternalIpv4}:${lldapStorage}/ \
              ${lldapStorTmp}/

            # LLDAP use nobody / nogroup to store its data
            ${pkgs.coreutils}/bin/chown -R nobody:nogroup ${lldapStorTmp}

            ${pkgs.systemd}/bin/systemctl stop lldap

            # Sync with local lldap service
            ${pkgs.rsync}/bin/rsync \
              -av \
              --delete \
              ${lldapStorTmp}/ \
              ${lldapStorage}/

            ${pkgs.systemd}/bin/systemctl start lldap
          '';
        };
      };

      # TLS certificates (caddy storage) sync timer
      systemd.timers.sync-lldap = lib.mkIf needSync {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = "10min";
          Persistent = true;
        };
      };

      #------------------------------------------------------------------------
      # LLDAP Service
      #------------------------------------------------------------------------
    })
  ];
}
