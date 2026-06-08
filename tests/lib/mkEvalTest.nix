# L1 — eval guard. Forces config.system.build.toplevel.drvPath for every host
# of every given workspace. Interpolating the drvPaths (strings) forces full
# module evaluation without realizing the system closures: a broken module set
# fails `nix build` here, fast, with no VM boot.
#
# Evaluates the SAME nodes the VM tiers boot (forTest + test-tuning seam), so
# production-only workDir reads (nix.pub, ...) don't trip the guard. The driver-
# owned bits dropped by `forTest` (the nixpkgs misc module + hostPlatform) are
# added back for a standalone `nixosSystem`.

{ pkgs, inputs }:
{ name, workspaces }:
let
  inherit (pkgs) lib;
  load = import ./workspace.nix { inherit inputs; };

  toplevelDrv =
    nodeDef:
    (inputs.nixpkgs.lib.nixosSystem {
      inherit (nodeDef) specialArgs;
      modules = nodeDef.modules ++ [
        "${inputs.nixpkgs}/nixos/modules/misc/nixpkgs.nix"
        { nixpkgs.hostPlatform = nodeDef.system; }
        ./test-tuning.nix

        {

          # Eval-only (drvPath, never built/booted): a real host gets these
          # from its hardware/disko profile, the VM tier from qemu-vm. Stub
          # at `mkDefault` priority so disko-aware hosts (which define their
          # own fileSystems via the disko module) win the merge cleanly.
          fileSystems."/" = {
            device = lib.mkDefault "/dev/vda";
            fsType = lib.mkDefault "ext4";
          };
          fileSystems."/boot" = {
            device = lib.mkDefault "/dev/vda1";
            fsType = lib.mkDefault "vfat";
          };
        }
      ];
    }).config.system.build.toplevel.drvPath;

  loaded = map load workspaces;
  drvs = lib.concatMap (w: map (h: toplevelDrv (w.nodeOf h)) w.hostNames) loaded;
in
pkgs.runCommand name { } ''
  cat > "$out" <<'EOF'
  ${lib.concatStringsSep "\n" drvs}
  EOF
''
