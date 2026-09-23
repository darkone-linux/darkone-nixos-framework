# Release-train check of a consumer template (`nix eval --apply`): every host
# evaluates down to `system.build.toplevel` against the pinned framework.
#
# A template carries no hardware and no secrets, so both are stubbed: a root
# filesystem, no boot loader, an empty sops file, `darkone.test.standalone`.
# Stubs are `mkDefault`: a host shipping its own hardware configuration wins.
# Install images (ISO, SD) are skipped: they hold no host of the template.

configurations:
let
  isImage = name: builtins.match "(iso|sd-image)-.*" name != null;
  hosts = builtins.removeAttrs configurations (
    builtins.filter isImage (builtins.attrNames configurations)
  );
  stub = { lib, ... }: {
    fileSystems."/" = lib.mkDefault {
      device = "none";
      fsType = "tmpfs";
    };
    boot.loader.grub.enable = lib.mkDefault false;
    darkone.test.standalone = true;
    sops.defaultSopsFile = lib.mkForce (builtins.toFile "secrets.yaml" "{}");
    sops.validateSopsFiles = false;
  };
in
builtins.mapAttrs (
  _: configuration:
  (configuration.extendModules { modules = [ stub ]; }).config.system.build.toplevel.drvPath
) hosts
