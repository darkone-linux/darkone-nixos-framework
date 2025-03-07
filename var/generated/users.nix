# This file is generated by 'just generate'
# from the configuration file usr/config.yaml
# --> DO NOT EDIT <--

{
  nixos = {
    uid = 1000;
    name = "An admin user";
    profile = "dnf/homes/admin";
    groups = [ "admin" ];
  };
  darkone = {
    uid = 1001;
    email = "darkone@darkone.yt";
    name = "Darkone Linux";
    profile = "usr/homes/darkone";
    groups = [
      "admin"
      "media"
      "common"
    ];
  };
  ethan = {
    uid = 1002;
    name = "Ethan";
    profile = "dnf/homes/student";
    groups = [
      "sn"
      "tsn"
    ];
  };
  esteban = {
    uid = 1003;
    name = "Esteban";
    profile = "dnf/homes/teenager";
    groups = [
      "kids"
      "common"
    ];
  };
  nix = {
    uid = 65000;
    name = "Nix Maintenance User";
    profile = "dnf/homes/nix-admin";
    groups = [ ];
  };
}
