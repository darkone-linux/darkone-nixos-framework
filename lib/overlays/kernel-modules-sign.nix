# Overlay: signs the `virtualbox` kernel modules with `kmodigest`.
#
# :::caution[Why]
# nixpkgs signs modules through `kernel.commonMakeFlags` (`cmd_sign=kmodigest`)
# and the modules aggregator concatenates each external `<module>.ko.cer`.
# `virtualbox-modules` lacks these flags: no `.cer`, the system build fails
# (`cat: misc/vboxdrv.ko.cer: No such file or directory`).
# :::
#
# :::tip[Cleanup]
# Drop it once upstream `pkgs/os-specific/linux/virtualbox/default.nix` adds
# `kernel.commonMakeFlags` (or `kernelModuleMakeFlags`) to its `makeFlags`.
# :::

_final: prev:
let

  # `extend`: `kself.kernel` is the final kernel, `boot.kernelPackages`
  # re-extends the set with its own patches.
  fix =
    kernelPackages:
    kernelPackages.extend (
      kself: ksuper: {
        virtualbox = ksuper.virtualbox.overrideAttrs (old: {
          makeFlags = (old.makeFlags or [ ]) ++ kself.kernel.commonMakeFlags;
        });
      }
    );
in
{

  # Every kernel set DNF selects: `system/core.nix`, `security/*.nix`.
  linuxPackages = fix prev.linuxPackages;
  linuxPackages_latest = fix prev.linuxPackages_latest;
  linuxPackages_hardened = fix prev.linuxPackages_hardened;
  linuxPackagesFor = kernel: fix (prev.linuxPackagesFor kernel);
}
