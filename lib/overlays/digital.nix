# Overlay: builds `digital` (education profile) with the full JDK.
#
# :::caution[Why]
# `maven.buildMavenPackage` defaults `mvnJdk` to `maven.jdk`, i.e.
# `jdk_headless` (nixpkgs#578013): no `libfontmanager`, 11 AWT tests fail
# (`UnsatisfiedLinkError: no fontmanager`), the package never builds.
# :::
#
# :::tip[Cleanup]
# Drop once nixpkgs#581567 (`mvnJdk = jdk`) reaches `nixos-unstable`.
# :::

final: prev: {

  # No `overrideMavenAttrs`: `JAVA_HOME` is the only `mvnJdk` use in the
  # final build. The dependency FOD keeps the headless JDK, same output.
  digital = prev.digital.overrideAttrs (old: {
    env = old.env // {
      JAVA_HOME = final.jdk;
    };
  });
}
