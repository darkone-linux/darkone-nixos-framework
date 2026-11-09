# Overlay: gives Rust packages the system libs their `*-sys` crates require.
#
# :::caution[Why]
# `cargoUseSystemLibs` (`cargoSetupHook`, nixpkgs 26.11) makes `onig_sys`,
# `zstd-sys`, `libsqlite3-sys` and `aws-lc-sys` use a system lib absent from
# the build. Fixed upstream: nixpkgs#584850, #584888, #584667.
# :::
#
# :::tip[Cleanup]
# Drop each entry once its unstable package builds again.
# :::

final: prev:
let

  # Superset for every affected package: an unused lib or a duplicate is
  # harmless. AWS-LC stays vendored, as in `lk-jwt-service.nix`.
  withRustSysLibs =
    pkg:
    pkg.overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.pkg-config ];
      buildInputs = (old.buildInputs or [ ]) ++ [
        final.oniguruma
        final.sqlite
        final.zstd
      ];
      preBuild = (old.preBuild or "") + ''
        unset AWS_LC_SYS_USE_SYSTEM
      '';
    });
in
{
  presenterm = withRustSysLibs prev.presenterm;
  aichat = withRustSysLibs prev.aichat;
  codex = withRustSysLibs prev.codex;

  # zstd-sys: no upstream fix tracked yet.
  oxicloud = withRustSysLibs prev.oxicloud;
}
