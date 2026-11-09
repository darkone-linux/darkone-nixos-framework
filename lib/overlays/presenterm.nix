# Overlay: gives Rust packages the system libs their `*-sys` crates require.
#
# :::caution[Why]
# The locked nixpkgs makes `onig_sys` (`RUSTONIG_SYSTEM_LIBONIG`), `zstd-sys`,
# `libsqlite3-sys` and `aws-lc-sys` (`AWS_LC_SYS_USE_SYSTEM`) use a system lib
# absent from the build. Affected: `presenterm`, `aichat`, `codex`.
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
}
