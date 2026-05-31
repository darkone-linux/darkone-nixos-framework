# DNF Modules registry
#
# Default values:
# {
#   reverseProxy = true;
#   uniquePerZone = false;
#   externalAccess = false;
# };

{
  ncps = {
    reverseProxy = false;
    uniquePerZone = true;
    description = "";
  };
  adguardhome = {
    uniquePerZone = true;
    activation.profiles.gateway.triggers.keys.adguardhome = [ "enable" ];
  };
  audio = {
    reverseProxy = false;
    activation.profiles.desktop.triggers.always = [ "enable" ];
  };
  harmonia = {
    reverseProxy = false;
    activation.profiles.minimal.triggers.keys.harmonia = [ "enable" ];
  };
  headscale = {
    reverseProxy = false;
    externalAccess = true;
    activation.profiles.hcs.triggers.always = [ "enable" ];
  };
  homepage = {
    uniquePerZone = true;
    activation.profiles.minimal.triggers.keys.homepage = [ "enable" ];
  };
  idm = {
    reverseProxy = false;
    activation.profiles = {
      gateway.triggers.keys.idm = [ "enable" ];
      hcs.triggers.keys.idm = [ "enable" ];
    };
  };
  nfs = {
    reverseProxy = false;
  };
  printing = {
    reverseProxy = false;
    activation.profiles = {
      desktop.triggers.always = [ "enable" ];
      laptop.triggers.always = [ "loadAll" ];
    };
  };
  restic = {
    reverseProxy = false;
    activation.profiles.minimal.triggers.keys = {
      restic = [
        "enable"
        "enableServer"
      ];
      backuped = [ "enable" ];
    };
  };
  searx = {
    reverseProxy = false;
    activation.profiles.minimal.triggers.keys.searx = [ "enable" ];
  };
  turn = {
    externalAccess = true;
    activation.profiles.minimal.triggers.keys.turn = [ "enable" ];
  };
  ai = {
    activation.profiles.minimal.triggers.keys.ai = [ "enable" ];
  };
  docs = {
    activation.profiles.minimal.triggers.keys.docs = [ "enable" ];
  };
  element = {
    activation.profiles.minimal.triggers.keys.element = [ "enable" ];
  };
  forgejo = {
    activation.profiles.minimal.triggers.keys.forgejo = [ "enable" ];
  };
  garage = {
    activation.profiles.minimal.triggers.keys.garage = [ "enable" ];
  };
  geneweb = {
    activation.profiles.minimal.triggers.keys.geneweb = [ "enable" ];
  };
  immich = {
    activation.profiles.minimal.triggers.keys.immich = [ "enable" ];
  };
  jellyfin = {
    activation.profiles.minimal.triggers.keys.jellyfin = [ "enable" ];
  };
  jitsi-meet = {
    activation.profiles.minimal.triggers.keys.jitsi-meet = [ "enable" ];
  };
  matrix = {
    activation.profiles.minimal.triggers.keys.matrix = [ "enable" ];
  };
  mealie = {
    activation.profiles.minimal.triggers.keys.mealie = [ "enable" ];
  };
  monitoring = {
    activation.profiles.minimal.triggers.keys.monitoring = [ "enable" ];
  };
  nextcloud = {
    activation.profiles.minimal.triggers.keys.nextcloud = [ "enable" ];
  };
  outline = {
    activation.profiles.minimal.triggers.keys.outline = [ "enable" ];
  };
  vaultwarden = {
    activation.profiles.minimal.triggers.keys.vaultwarden = [ "enable" ];
  };
  dnsmasq = {
    activation.profiles.gateway.triggers.always = [ "enable" ];
  };
  fail2ban = {
    activation.profiles = {
      gateway.triggers.always = [ "enable" ];
      hcs.triggers.always = [ "enable" ];
    };
  };
}
