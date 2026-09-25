# Tests for dnf/lib/uplinks.nix
# Run with: nix-unit --flake .#libTests
{ lib, dnfLib }:
let
  inherit (dnfLib)
    mkUplinks
    uplinkConflicts
    mkWpaNetworks
    backupLinkSecret
    ;

  phone = {
    type = "wifi";
    interface = "wlp4s0";
    priority = 10;
  };
  neighbour = {
    type = "wifi";
    interface = "wlp4s0";
    priority = 20;
  };
  cable = {
    type = "ethernet";
    interface = "eno3";
    priority = 5;
  };

  uplinks = mkUplinks {
    wanInterface = "eno0";
    backupLinks = { inherit phone neighbour cable; };
  };

  # Readable placeholder stand-in: `<name.field>`.
  placeholder = name: field: "<${name}.${field}>";
in
{
  #----------------------------------------------------------------------------
  # Metrics and names
  #----------------------------------------------------------------------------

  testMetricsOrder = {
    expr = {
      inherit (dnfLib) primaryMetric uplinkProbation uplinkPenalty;
      backup1 = dnfLib.backupMetric 1;
      backup99 = dnfLib.backupMetric 99;
    };
    expected = {
      primaryMetric = 100;
      uplinkProbation = 10000;
      uplinkPenalty = 20000;
      backup1 = 210;
      backup99 = 1190;
    };
  };

  testNetworkFiles = {
    expr = [
      (dnfLib.primaryNetworkFile "eno0")
      (dnfLib.backupNetworkFile "wlp4s0")
    ];
    expected = [
      "40-eno0"
      "45-dnf-backup-wlp4s0"
    ];
  };

  testBackupLinkSecret = {
    expr = backupLinkSecret "phone" "psk";
    expected = "backup-link/phone/psk";
  };

  #----------------------------------------------------------------------------
  # mkUplinks
  #----------------------------------------------------------------------------

  testUplinksNoBackup = {
    expr = mkUplinks {
      wanInterface = "eno0";
      backupLinks = { };
    };
    expected = [
      {
        interface = "eno0";
        type = "ethernet";
        role = "primary";
        networkFile = "40-eno0";
        metric = 100;
        standby = false;
        links = [ ];
      }
    ];
  };

  # Primary first, then backups by metric; a shared radio keeps the metric of
  # its preferred link and lists its links in preference order.
  testUplinksOrderAndGrouping = {
    expr = map (u: {
      inherit (u)
        interface
        role
        metric
        links
        ;
    }) uplinks;
    expected = [
      {
        interface = "eno0";
        role = "primary";
        metric = 100;
        links = [ ];
      }
      {
        interface = "eno3";
        role = "backup";
        metric = 250;
        links = [ "cable" ];
      }
      {
        interface = "wlp4s0";
        role = "backup";
        metric = 300;
        links = [
          "phone"
          "neighbour"
        ];
      }
    ];
  };

  testUplinksBackupFields = {
    expr = lib.findFirst (u: u.interface == "wlp4s0") null uplinks;
    expected = {
      interface = "wlp4s0";
      type = "wifi";
      role = "backup";
      networkFile = "45-dnf-backup-wlp4s0";
      metric = 300;
      standby = true;
      links = [
        "phone"
        "neighbour"
      ];
    };
  };

  # Only wifi backups idle their radio; primary and ethernet stay up.
  testUplinksStandby = {
    expr = map (u: { inherit (u) interface standby; }) uplinks;
    expected = [
      {
        interface = "eno0";
        standby = false;
      }
      {
        interface = "eno3";
        standby = false;
      }
      {
        interface = "wlp4s0";
        standby = true;
      }
    ];
  };

  #----------------------------------------------------------------------------
  # uplinkConflicts
  #----------------------------------------------------------------------------

  testConflictsNone = {
    expr = uplinkConflicts {
      wanInterface = "eno0";
      backupLinks = { inherit phone neighbour cable; };
      reservedInterfaces = {
        eno1 = "zone LAN port";
      };
    };
    expected = [ ];
  };

  testConflictsBadName = {
    expr = uplinkConflicts {
      wanInterface = "eno0";
      backupLinks = {
        "Phone_1" = phone;
      };
    };
    expected = [ "backup link \"Phone_1\": name must match [a-z][a-z0-9-]*" ];
  };

  testConflictsOnWan = {
    expr = uplinkConflicts {
      wanInterface = "eno0";
      backupLinks = {
        box2 = cable // {
          interface = "eno0";
        };
      };
    };
    expected = [ "backup link \"box2\": eno0 is the primary WAN" ];
  };

  testConflictsReserved = {
    expr = uplinkConflicts {
      wanInterface = "eno0";
      backupLinks = {
        ap = phone // {
          interface = "wl-ext";
        };
      };
      reservedInterfaces = {
        wl-ext = "hostapd radio";
      };
    };
    expected = [ "backup link \"ap\": wl-ext is already the hostapd radio" ];
  };

  testConflictsSharedEthernet = {
    expr = uplinkConflicts {
      wanInterface = "eno0";
      backupLinks = {
        a = cable;
        b = cable;
      };
    };
    expected = [ "backup links a, b: ethernet eno3 carries a single link" ];
  };

  testConflictsMixedTypes = {
    expr = uplinkConflicts {
      wanInterface = "eno0";
      backupLinks = {
        a = cable;
        b = phone // {
          interface = "eno3";
        };
      };
    };
    expected = [ "backup links a, b: eno3 cannot be both ethernet and wifi" ];
  };

  #----------------------------------------------------------------------------
  # mkWpaNetworks
  #----------------------------------------------------------------------------

  # Wifi links only, preferred first, wpa priority inverted (higher wins).
  testWpaNetworks = {
    expr = mkWpaNetworks {
      backupLinks = { inherit phone neighbour cable; };
      inherit placeholder;
    };
    expected = ''
      # backup link: phone
      network={
        ssid="<phone.ssid>"
        psk="<phone.psk>"
        key_mgmt=WPA-PSK SAE
        ieee80211w=1
        priority=90
      }

      # backup link: neighbour
      network={
        ssid="<neighbour.ssid>"
        psk="<neighbour.psk>"
        key_mgmt=WPA-PSK SAE
        ieee80211w=1
        priority=80
      }
    '';
  };

  testWpaNetworksNoWifi = {
    expr = mkWpaNetworks {
      backupLinks = { inherit cable; };
      inherit placeholder;
    };
    expected = "";
  };
}
