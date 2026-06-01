# Tests for dnf/lib/services.nix
# Run with: nix-unit --flake .#libTests
{ dnfLib }:
let
  inherit (dnfLib) triggerProfileServices mkHostProfileServicesAssertions;

  mockHost = {
    hostname = "testhost";
    services = {
      forgejo = { };
      restic = { };
    };
  };

  # Representative module registry covering all trigger variants.
  mockModules = {

    # Single-key trigger, single option.
    forgejo = {
      activation.profiles.minimal.triggers.keys.forgejo = [ "enable" ];
    };

    # triggers.always (gateway profile only).
    dnsmasq = {
      activation.profiles.gateway.triggers.always = [ "enable" ];
    };

    # Two alternate trigger keys for the same module, multi-option match.
    restic = {
      activation.profiles.minimal.triggers.keys = {
        restic = [
          "enable"
          "enableServer"
        ];
        backuped = [ "enable" ];
      };
    };

    # Activation only in a different profile → silent for "minimal".
    harmonia = {
      activation.profiles.other.triggers.keys.harmonia = [ "enable" ];
    };

    # Key not present in mockHost.services.
    immich = {
      activation.profiles.minimal.triggers.keys.immich = [ "enable" ];
    };
  };

  minimalResult = triggerProfileServices {
    profileName = "minimal";
    host = mockHost;
    modules = mockModules;
  };

in
{
  # triggers.keys: matching key → option activated via mkOverride 200.
  testKeyPresentActivates = {
    expr = minimalResult.darkone.service.forgejo.enable.content;
    expected = true;
  };

  # triggers.keys: key absent → module not emitted.
  testKeyAbsentNoActivation = {
    expr = !(minimalResult ? darkone.service.immich);
    expected = true;
  };

  # triggers.always: activates regardless of host.services.
  testAlwaysActivates = {
    expr =
      (triggerProfileServices {
        profileName = "gateway";
        host = {
          hostname = "gw";
          services = { };
        };
        modules = mockModules;
      }).darkone.service.dnsmasq.enable.content;
    expected = true;
  };

  # Multi-option trigger: all options activated via mkOverride 200 on match.
  testMultipleOptionsOnMatch = {
    expr =
      let
        svc = minimalResult.darkone.service.restic;
      in
      svc.enable.content && svc.enableServer.content;
    expected = true;
  };

  # Module with no trigger for the current profile → not emitted.
  testWrongProfileNoActivation = {
    expr = !(minimalResult ? darkone.service.harmonia);
    expected = true;
  };

  # mkHostProfileServicesAssertions: single matching key → assertion passes.
  testAssertionOkSingleKey = {
    expr =
      (builtins.head (mkHostProfileServicesAssertions {
        profileName = "minimal";
        host = mockHost;
        modules = mockModules;
      })).assertion;
    expected = true;
  };

  # mkHostProfileServicesAssertions: two matching keys for same module → assertion fails.
  testAssertionFailsTwoKeys = {
    expr =
      (builtins.head (mkHostProfileServicesAssertions {
        profileName = "minimal";
        host = mockHost // {
          services = {
            restic = { };
            backuped = { };
          };
        };
        modules = mockModules;
      })).assertion;
    expected = false;
  };
}
