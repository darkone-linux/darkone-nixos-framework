# This file is generated by 'just generate'
# from the configuration file usr/config.yaml
# --> DO NOT EDIT <--

[
  {
    hostname = "nlt";
    name = "Darkone Laptop";
    profile = "usr/hosts/admin-laptop.nix";
    users = [
      {
        login = "darkone";
        email = "darkone@darkone.yt";
        name = "Darkone Linux";
        profile = "usr/homes/darkone";
      }
      {
        login = "gponcon";
        email = "gponcon@arthur.lan";
        name = "G. Ponçon";
        profile = "lib/homes/normal";
      }
    ];
    colmena = {
      deployment = {
        tags = [
          "laptops"
          "admin"
          "group-admin"
          "user-darkone"
          "user-gponcon"
        ];
      };
      allowLocalDeployment = true;
    };
  }
  {
    hostname = "vbox-01";
    name = "Virtual 01";
    profile = "usr/hosts/vbox.nix";
    users = [
      {
        login = "darkone";
        email = "darkone@darkone.yt";
        name = "Darkone Linux";
        profile = "usr/homes/darkone";
      }
    ];
    colmena = {
      deployment = {
        tags = [ "user-darkone" ];
      };
    };
  }
  {
    hostname = "vbox-02";
    name = "Virtual 02";
    profile = "usr/hosts/vbox.nix";
    users = [
      {
        login = "darkone";
        email = "darkone@darkone.yt";
        name = "Darkone Linux";
        profile = "usr/homes/darkone";
      }
    ];
    colmena = {
      deployment = {
        tags = [ "user-darkone" ];
      };
    };
  }
  {
    hostname = "vbox-03";
    name = "Virtual 03";
    profile = "usr/hosts/vbox.nix";
    users = [
      {
        login = "darkone";
        email = "darkone@darkone.yt";
        name = "Darkone Linux";
        profile = "usr/homes/darkone";
      }
    ];
    colmena = {
      deployment = {
        tags = [ "user-darkone" ];
      };
    };
  }
]
