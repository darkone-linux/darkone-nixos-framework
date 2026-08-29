# DNF — `init` app: materialise the framework tree in a consumer workspace.
#
# Two tools need the framework at a real path, not behind a flake input:
#
# - `just`, which resolves `import` paths statically at parse time;
# - `dnf-generator`, which looks up user profiles (`dnf/home/profiles/`), disko
#   profiles (`dnf/hosts/disko/`) and the machine template on disk, under the
#   workspace root.
#
# Both symlinks are gitignored by the consumer templates. `.dnf` is kept for
# the legacy `import? '.dnf/just/project.just'` form.
#
# :::tip[Run it from the project]
# `nix run .#init` links the revision the consumer's own `flake.lock` pins, so
# the tooling and the built system always come from the same framework rev.
# `nix run github:darkone-linux/darkone-nixos-framework#init` links the latest
# one instead — the way to bootstrap a workspace that has no lock yet.
# :::

{ pkgs, frameworkRoot }:

{
  type = "app";
  meta.description = "Link the DNF framework tree into a consumer workspace (dnf/, .dnf/)";
  program = toString (
    pkgs.writeShellScript "dnf-init" ''
      set -euo pipefail
      ln -sfn ${frameworkRoot} dnf
      ln -sfn ${frameworkRoot}/assets .dnf
      echo "Linked dnf  -> $(readlink dnf)"
      echo "Linked .dnf -> $(readlink .dnf)"
      echo "Next: 'nix develop' then 'just --list'."
    ''
  );
}
