# SuperTuxKart with configurations to play in local network.
#
# :::tip
# To use in conjonction with homemanager games module!
# :::

{
  lib,
  config,
  zone,
  network,
  host,
  pkgs,
  ...
}:
let
  cfg = config.darkone.graphic.supertuxkart;
  mainNfsHost = (lib.findFirst (s: s.name == "nfs" && s.zone == zone.name) "" network.services).host;
  hasNfsServer = mainNfsHost != "";
  isMainNfsServer = config.darkone.service.nfs.enable && (host.hostname == mainNfsHost);
  nfsServer = "nfs"; # TODO
  inherit (config.darkone.system) dirs;
  sharePrefix = if cfg.isNfsServer then dirs.root else "/mnt/nfs";
in
{
  options = {
    darkone.graphic.supertuxkart.enable = lib.mkEnableOption "SuperTuxKart + firewall config + tracks share";

    # TODO: imposer que ce soit le serveur nfs central qui partage
    darkone.graphic.supertuxkart.isNfsServer = lib.mkOption {
      type = lib.types.bool;
      default = isMainNfsServer;
      description = "NFS server (share tracks), default is the main NFS server. (wip, enable on main server)";
    };
  };

  config = lib.mkIf cfg.enable {

    # STK package
    environment.systemPackages = with pkgs; [ superTuxKart ];

    # NFS Share (server)
    systemd.tmpfiles.rules = [ "d ${sharePrefix}/stk-tracks 0775 nobody users -" ];
    services.nfs.server = lib.mkIf cfg.isNfsServer {
      enable = true;
      exports = ''
        ${dirs.root}            ${zone.networkIp}/${toString zone.prefixLength}(rw,fsid=0,no_subtree_check)
        ${dirs.root}/stk-tracks ${zone.networkIp}/${toString zone.prefixLength}(ro,nohide,insecure,async,no_subtree_check,all_squash,anonuid=65534,anongid=100)
      '';
    };

    # NFS mount (clients)
    fileSystems."/mnt/nfs/stk-tracks" = lib.mkIf ((!cfg.isNfsServer) && hasNfsServer) {
      device = "${nfsServer}.${host.zoneDomain}:/stk-tracks";
      fsType = "nfs";
      options = [
        "x-systemd.automount" # Mount on demand
        "x-systemd.idle-timeout=600" # Unmount after 10min with no activity
        "noauto"
        "noatime"
        "ro"
      ];
    };

    # Open ports & accept broadcasts (local servers discovery)
    networking.firewall = {
      enable = true;

      allowedTCPPorts = lib.mkIf cfg.isNfsServer [
        2049 # NFS
      ];
      allowedUDPPorts = [
        2757 # STK
        2759 # STK
      ];
      allowedUDPPortRanges = [
        {
          from = 32768;
          to = 60999;
        }
      ];

      # Accept STK broadcasts
      extraCommands = ''
        # Autoriser broadcast entrant sur le port 2757
        iptables -A INPUT -d 10.1.255.255 -p udp --dport 2757 -j ACCEPT
        iptables -A INPUT -d 10.1.2.255 -p udp --dport 2757 -j ACCEPT

        # Autoriser broadcast sortant
        iptables -A OUTPUT -d 10.1.255.255 -p udp --dport 2757 -j ACCEPT
        iptables -A OUTPUT -d 10.1.2.255 -p udp --dport 2757 -j ACCEPT

        # Autorise les réponses aux broadcasts
        iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
      '';
    };
  };
}
