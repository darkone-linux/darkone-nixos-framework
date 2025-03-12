# This file is generated by 'just generate'
# from the configuration file usr/config.yaml
# --> DO NOT EDIT <--

{
  domain = "darkone.lan";
  timezone = "America/Miquelon";
  locale = "fr_FR.UTF-8";
  gateway = {
    hostname = "gateway";
    wan = {
      interface = "eth0";
      gateway = "192.168.0.1";
    };
    lan = {
      interfaces = [ "enu1u4" ];
      ip = "192.168.1.1";
      prefixLength = 24;
      dhcp-range = [ "192.168.1.100,192.168.1.230,24h" ];
      dhcp-extra-option = [ "option:ntp-server,191.168.1.1" ];
    };
    services = [
      "homepage"
      "ncps"
      "forgejo"
      "lldap"
    ];
  };
  extraDnsmasqSettings = {
    dhcp-host = [
      "e8:ff:1e:d0:44:82,192.168.1.2,my-laptop,infinite"
      "e8:ff:1e:d0:44:83,192.168.1.82,my-laptop,infinite"
      "08:00:27:03:BB:20,192.168.1.101,pc01,infinite"
      "08:00:27:AE:49:7F,192.168.1.102,pc02,infinite"
      "08:00:27:EA:85:CB,192.168.1.103,pc03,infinite"
      "08:00:27:A4:B1:36,192.168.1.104,pc04,infinite"
      "f0:1f:af:13:61:c6,192.168.1.20,laptop-kids,infinite"
      "f0:1f:af:13:61:c7,192.168.1.21,laptop-family,infinite"
    ];
    dhcp-option = [
      "option:router,192.168.1.1"
      "option:dns-server,192.168.1.1"
      "option:domain-name,darkone.lan"
      "option:ntp-server,191.168.1.1"
    ];
    dhcp-range = [ "192.168.1.100,192.168.1.230,24h" ];
  };
  extraNetworking = {
    hosts = {
      "192.168.1.1" = [
        "gateway"
        "gateway"
        "passerelle"
      ];
      "192.168.1.2" = [
        "darkone"
        "my-laptop"
        "my-laptop"
      ];
      "192.168.1.20" = [ "laptop-kids" ];
      "192.168.1.21" = [ "laptop-family" ];
      "192.168.1.101" = [ "pc01" ];
      "192.168.1.102" = [ "pc02" ];
      "192.168.1.103" = [ "pc03" ];
      "192.168.1.104" = [ "pc04" ];
    };
  };
}
