# Overlay: builds `thonny` (education profile) against the locked `uv_build`.
#
# :::caution[Why]
# thonny pins its build backend to `uv_build>=0.11.6,<0.12.0`; nixpkgs widens
# it to `<0.13.0` but ships `uv_build` 0.13.4: the `pypaBuildPhase`
# dependency check fails, the package never builds.
# :::
#
# :::tip[Cleanup]
# Drop once nixpkgs#585369 reaches `nixos-unstable`.
# :::

_final: prev: {

  # Same patch as nixpkgs#585369: `--replace-fail` breaks the build loudly if
  # the bound changes, instead of a silent no-op.
  thonny = prev.thonny.overrideAttrs {
    postPatch = ''
      substituteInPlace pyproject.toml \
        --replace-fail '>=0.11.6,<0.12.0' '>=0.13'
    '';
  };
}
