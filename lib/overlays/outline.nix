# Overlay: fixes `pkgs.outline` 1.10.1 (nixpkgs `yarn-fix.patch` no longer applies).
#
# :::caution[Why]
# Upstream `v1.10.1` ships a third `npmAuditIgnoreAdvisories` entry in
# `.yarnrc.yml` (outline#13166): the nixpkgs patch hunk fails in the source
# `postFetch`, and both fixed-output hashes (source, yarn cache) are stale.
# `outline-yarn-fix.patch` is the nixpkgs patch with the updated context.
# :::
#
# :::tip[Cleanup]
# Guarded on version 1.10.1: inert as soon as nixpkgs bumps `outline`.
# Drop this file, the patch and its wiring in `mk-configuration.nix` then.
# :::

final: prev:
let

  # Same placeholder substitution as nixpkgs `package.nix`.
  yarnFixPatch = final.substitute {
    src = ./outline-yarn-fix.patch;
    substitutions = [
      "--replace-fail"
      "YARN_LOCKFILE_VERSION_PLACEHOLDER"
      final.yarn-berry_4.lockfileVersion
    ];
  };
in
{

  # Attribute always defined, condition inside: an overlay keyset depending
  # on `final` recurses infinitely.
  outline =
    if prev.outline.version != "1.10.1" then
      prev.outline
    else
      prev.outline.overrideAttrs (
        finalAttrs: prevAttrs: {

          # `.override`, not `overrideAttrs`: fetchzip wraps `postFetch` with its
          # own unpack step, lost when the attribute is replaced directly.
          src = prevAttrs.src.override {
            hash = "sha256-xFNWxsNrihrcdFqrl1I9RYuIlHufoFtl8IFJhquhJfI=";
            postFetch = ''
              cd $out
              patch -p1 < ${yarnFixPatch}
            '';
          };

          offlineCache = final.yarn-berry_4.fetchYarnBerryDeps {
            inherit (finalAttrs) src missingHashes;
            hash = "sha256-rgqRRWZdy938rPuTV+E1pWfJ6O1w6Z3F84qlGUZgorM=";
          };
        }
      );
}
