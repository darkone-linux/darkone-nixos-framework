# Overlay: builds `lk-jwt-service` (MatrixRTC) with the vendored AWS-LC.
#
# :::caution[Why]
# `cargoUseSystemLibs` (`cargoSetupHook`, nixpkgs 26.11) exports
# `AWS_LC_SYS_USE_SYSTEM=1` without providing AWS-LC: the `aws-lc-sys` build
# script panics, the package never builds. Fixed upstream: nixpkgs#584539.
# :::
#
# :::tip[Cleanup]
# Drop once unstable `lk-jwt-service` builds again.
# :::

_final: prev: {

  # `unset` in the build shell: covers both the package `env` and a setup hook.
  # Later phases (`cargo test`) share that shell.
  lk-jwt-service = prev.lk-jwt-service.overrideAttrs (old: {
    preBuild = (old.preBuild or "") + ''
      unset AWS_LC_SYS_USE_SYSTEM
    '';
  });
}
