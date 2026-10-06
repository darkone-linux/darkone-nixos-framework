# Overlay: rebuilds `pkgs.gimp` without `__structuredAttrs`.
#
# :::caution[Why]
# The `__structuredAttrs = true` inherited from upstream breaks the `gimp`
# build (environment variables / hooks expecting the old attribute format).
# Forcing it off falls back on the behaviour that builds the package.
# :::
#
# :::tip[Cleanup]
# Drop it once upstream makes `gimp` `__structuredAttrs`-clean.
# :::

_final: prev: {

  gimp = prev.gimp.overrideAttrs (_: {
    __structuredAttrs = false;
  });
}
