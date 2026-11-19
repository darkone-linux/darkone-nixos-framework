# DNF temporary workarounds registry
#
# Every patch, pin or bypass the framework carries while waiting on an
# upstream fix: one entry each, dropped together with the workaround.
# `just workarounds` reports each entry's upstream status.
#
# :::caution[Registration is enforced]
# `tests/unit/config/workarounds_test.nix` rejects an unregistered overlay
# (`lib/overlays/`), backport (`backports/nixos/`) or `nixpkgs-*` input, and
# an entry whose file or input is gone.
# :::
#
# :::note[Fields]
# - `kind`: `overlay` (`lib/overlays/`), `backport` (`backports/nixos/`),
#   `pin` (package from another nixpkgs), `inline` (in-module bypass),
#   `insecure` (`permittedInsecurePackages`)
# - `files`: framework files carrying it, from the dnf root (overlays and
#   backports are also wired: `lib/overlays/default.nix`, `lib/flake/mk-configuration.nix`)
# - `reason`: the upstream defect; `dropWhen`: the cleanup condition
# - `since`: date added, `YYYY-MM-DD`
# - `upstream` (opt.): `owner/repo#N`, the fix awaited (PR or issue)
# - `package` (opt.): nixpkgs attribute path, probed on unstable; omit it
#   when a green Hydra build does not mean fixed
# - `inputs` (opt.): flake inputs to drop with it
# :::

{

  #----------------------------------------------------------------------------
  # Overlays (`lib/overlays/`)
  #----------------------------------------------------------------------------

  logseq = {
    kind = "overlay";
    files = [
      "lib/overlays/logseq.nix"
      "home/modules/office.nix"
    ];
    reason = "electron-forge source build never completes, pulls EOL electron_39";
    upstream = "NixOS/nixpkgs#535206";
    package = "logseq";
    dropWhen = "Hydra builds unstable logseq on electron >= 40";
    since = "2026-06-27";
  };

  virtualbox-modules-sign = {
    kind = "overlay";
    files = [ "lib/overlays/kernel-modules-sign.nix" ];
    reason = "virtualbox modules lack `kernel.commonMakeFlags`: no `.ko.cer`, system build fails";
    dropWhen = "upstream virtualbox passes `kernel.commonMakeFlags` to `makeFlags`";
    since = "2026-10-20";
  };

  openclaw-patchelf = {
    kind = "overlay";
    files = [ "lib/overlays/openclaw.nix" ];
    reason = "patchelf >= 0.18 sorts program headers: the repackaged Node binary segfaults";
    dropWhen = "nix-openclaw or patchelf ships the fix (`--no-sort` no longer needed)";
    since = "2026-10-23";
  };

  #----------------------------------------------------------------------------
  # Backports (`backports/nixos/`)
  #----------------------------------------------------------------------------

  geneweb = {
    kind = "backport";
    files = [
      "backports/nixos/geneweb.nix"
      "lib/overlays/geneweb.nix"
    ];
    reason = "GeneWeb module and package not merged in nixpkgs";
    upstream = "NixOS/nixpkgs#522751";
    inputs = [ "nixpkgs-geneweb" ];
    dropWhen = "nixpkgs#522751 in the locked nixpkgs";
    since = "2026-05-26";
  };

  oxicloud = {
    kind = "backport";
    files = [ "backports/nixos/oxicloud.nix" ];
    reason = "OxiCloud NixOS module not merged in nixpkgs";
    upstream = "NixOS/nixpkgs#516113";
    dropWhen = "nixpkgs#516113 in the locked nixpkgs";
    since = "2026-06-05";
  };

  #----------------------------------------------------------------------------
  # Inline bypasses
  #----------------------------------------------------------------------------

  nix-update-flake-path = {
    kind = "inline";
    files = [ "just/dnf/dev.just" ];
    reason = "Nix 2.35 `nix flake metadata` reports an unrealised `.path`: nix-update imports it, `No such file or directory`";
    upstream = "Mic92/nix-update#687";
    dropWhen = "nix-update realises the flake source itself (#687 closed): drop the `nix` shim of `pkg-update`";
    since = "2026-11-13";
  };

  #----------------------------------------------------------------------------
  # Insecure packages allowed (`permittedInsecurePackages`)
  #----------------------------------------------------------------------------

  jitsi-meet = {
    kind = "insecure";
    files = [ "modules/service/jitsi-meet.nix" ];
    reason = "jitsi-meet flagged insecure: deprecated libolm";
    package = "jitsi-meet";
    dropWhen = "jitsi-meet no longer flagged insecure";
    since = "2025-12-03";
  };

  olm = {
    kind = "insecure";
    files = [ "modules/service/matrix/bridges.nix" ];
    reason = "olm deprecated, flagged insecure; legacy mautrix bridges still need it";
    package = "olm";
    dropWhen = "no enabled bridge needs olm";
    since = "2026-01-27";
  };
}
