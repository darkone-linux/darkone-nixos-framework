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
#   backports are also wired in `lib/mk-configuration.nix`)
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

  posthog = {
    kind = "overlay";
    files = [ "lib/overlays/posthog.nix" ];
    reason = "posthog marked broken since mcp 2: aider-chat refuses to evaluate";
    upstream = "NixOS/nixpkgs#578265";
    package = "python3Packages.posthog";
    dropWhen = "nixpkgs#578265 in the locked nixpkgs";
    since = "2026-10-27";
  };

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
  # Pins: a package from another nixpkgs
  #----------------------------------------------------------------------------

  opencode = {
    kind = "pin";
    files = [
      "lib/overlays/opencode.nix"
      "flake.nix"
    ];
    reason = "opencode 1.18.30 (nixpkgs#561612) crashes on every prompt";
    inputs = [ "nixpkgs-opencode" ];
    dropWhen = "a release fixing the `SystemPrompt.environment` TypeError in nixos-unstable";
    since = "2026-09-18";
  };

  musescore = {
    kind = "pin";
    files = [ "home/modules/music.nix" ];
    reason = "musescore fails on unstable: Qt 6.12 QML AOT in its `muse` framework";
    package = "musescore";
    dropWhen = "Hydra builds unstable musescore";
    since = "2026-10-20";
  };

  open-webui = {
    kind = "pin";
    files = [ "modules/service/ai.nix" ];
    reason = "unstable 0.12.3 `makeWrapperArgs` is one string, unsplit under `__structuredAttrs`";
    package = "open-webui";
    dropWhen = "unstable open-webui builds (unfree: never on Hydra, `nix build` it)";
    since = "2026-10-20";
  };

  matrix-synapse = {
    kind = "pin";
    files = [ "modules/service/matrix.nix" ];
    reason = "unstable 1.162.0 failed: dependency broken on Hydra";
    package = "matrix-synapse-unwrapped";
    dropWhen = "Hydra builds unstable synapse >= the deployed version (no schema downgrade)";
    since = "2026-10-20";
  };

  ollama = {
    kind = "pin";
    files = [
      "home/modules/ai.nix"
      "modules/service/ai.nix"
    ];
    reason = "stable carried a newer ollama than unstable";
    package = "ollama";
    dropWhen = "unstable ollama >= stable";
    since = "2026-06-07";
  };

  d2 = {
    kind = "pin";
    files = [ "home/modules/advanced.nix" ];
    reason = "undocumented (commit a206fbb)";
    package = "d2";
    dropWhen = "Hydra builds unstable d2";
    since = "2026-09-17";
  };

  #----------------------------------------------------------------------------
  # Inline bypasses
  #----------------------------------------------------------------------------

  librewolf = {
    kind = "inline";
    files = [ "home/modules/office/browsers.nix" ];
    reason = "librewolf flagged insecure (no maintainer): disabled fleet-wide by `&& false`";
    package = "librewolf";
    dropWhen = "librewolf no longer flagged insecure";
    since = "2026-06-17";
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
