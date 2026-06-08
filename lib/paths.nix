# DNF — pure helpers for path resolution used by `mk-configuration.nix`.
#
# Profiles emitted by the generator in `var/generated/users.nix` carry a
# `dnf/...` prefix for framework-owned profiles and a `usr/...` prefix for
# consumer-owned ones. These helpers turn those strings into real Nix paths
# rooted at the framework store path (`frameworkRoot`) or the consumer
# workspace (`workDir`).
#
# :::note
# Helpers accept both Nix paths and plain strings as `frameworkRoot` /
# `workDir`, which makes them straightforward to unit-test with mock string
# roots (`/fw`, `/wd`).
# :::

{ lib }:

{

  # Resolve a generator-emitted profile path to its home-manager profile
  # directory. Framework-side profiles (prefix `dnf/`) land at the framework
  # root; consumer-side ones (`usr/...`) at the consumer's workspace.
  resolveProfile =
    { frameworkRoot, workDir }:
    profilePath:
    if lib.hasPrefix "dnf/" profilePath then
      frameworkRoot + "/${lib.removePrefix "dnf/" profilePath}"
    else
      workDir + "/${profilePath}";

  # Resolve the companion NixOS module (`home/nixos/<name>.nix`) for a given
  # profile path. Used by `modules/user/build.nix` to declare
  # `users.users.<login>` overrides without baking layout assumptions.
  resolveNixosProfile =
    { frameworkRoot, workDir }:
    profilePath:
    let
      name = baseNameOf profilePath;
    in
    if lib.hasPrefix "dnf/" profilePath then
      frameworkRoot + "/home/nixos/${name}.nix"
    else
      workDir + "/usr/home/nixos/${name}.nix";
}
