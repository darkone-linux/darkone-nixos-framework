# Tests for dnf/lib/paths.nix — generator-emitted profile path resolution.
#
# Helpers accept strings for `frameworkRoot` / `workDir`, so we feed them
# `/fw` and `/wd` and assert exact string equality.
#
# Run with: nix-unit --flake .#libTests
{ dnfLib }:
let
  roots = {
    frameworkRoot = "/fw";
    workDir = "/wd";
  };
  resolve = dnfLib.resolveProfile roots;
  resolveNixos = dnfLib.resolveNixosProfile roots;
in
{

  # resolveProfile — framework-side profile (`dnf/` prefix stripped, framework root prepended)
  testResolveProfileFramework = {
    expr = resolve "dnf/home/profiles/nix-admin";
    expected = "/fw/home/profiles/nix-admin";
  };
  testResolveProfileFrameworkAdmin = {
    expr = resolve "dnf/home/profiles/admin";
    expected = "/fw/home/profiles/admin";
  };

  # resolveProfile — consumer-side profile (path-through under workDir)
  testResolveProfileConsumer = {
    expr = resolve "usr/home/profiles/custom";
    expected = "/wd/usr/home/profiles/custom";
  };
  testResolveProfileConsumerNested = {
    expr = resolve "usr/some/nested/profile";
    expected = "/wd/usr/some/nested/profile";
  };

  # The `dnf/` prefix must be a true prefix (full segment) — `dnfsomething/...`
  # is treated as consumer-side, not framework-side.
  testResolveProfilePrefixIsSegment = {
    expr = resolve "dnfsomething/foo";
    expected = "/wd/dnfsomething/foo";
  };

  # resolveNixosProfile — framework-side: derives `home/nixos/<name>.nix`
  # under the framework root.
  testResolveNixosProfileFramework = {
    expr = resolveNixos "dnf/home/profiles/nix-admin";
    expected = "/fw/home/nixos/nix-admin.nix";
  };
  testResolveNixosProfileFrameworkAdmin = {
    expr = resolveNixos "dnf/home/profiles/admin";
    expected = "/fw/home/nixos/admin.nix";
  };

  # resolveNixosProfile — consumer-side: `usr/home/nixos/<name>.nix` under workDir.
  testResolveNixosProfileConsumer = {
    expr = resolveNixos "usr/home/profiles/custom";
    expected = "/wd/usr/home/nixos/custom.nix";
  };
  testResolveNixosProfileConsumerNested = {
    expr = resolveNixos "usr/some/nested/custom";
    expected = "/wd/usr/home/nixos/custom.nix";
  };

  # Realistic mapAttrs scenario over a generated users.nix slice.
  testUserNixosProfilesMapping = {
    expr =
      let
        users = {
          admin = {
            profile = "dnf/home/profiles/nix-admin";
          };
          alice = {
            profile = "dnf/home/profiles/normal";
          };
          custom = {
            profile = "usr/home/profiles/dev";
          };
        };
      in
      builtins.mapAttrs (_login: user: resolveNixos user.profile) users;
    expected = {
      admin = "/fw/home/nixos/nix-admin.nix";
      alice = "/fw/home/nixos/normal.nix";
      custom = "/wd/usr/home/nixos/dev.nix";
    };
  };

  # `resolveProfile`/`resolveNixosProfile` are partially applied: the roots
  # are bound once, then each call passes only the profile path. Ensure the
  # closure does not leak across calls.
  testResolveProfileNoLeakage =
    let
      ra = dnfLib.resolveProfile {
        frameworkRoot = "/A";
        workDir = "/x";
      };
      rb = dnfLib.resolveProfile {
        frameworkRoot = "/B";
        workDir = "/y";
      };
    in
    {
      expr = [
        (ra "dnf/foo")
        (rb "dnf/foo")
        (ra "usr/bar")
        (rb "usr/bar")
      ];
      expected = [
        "/A/foo"
        "/B/foo"
        "/x/usr/bar"
        "/y/usr/bar"
      ];
    };
}
