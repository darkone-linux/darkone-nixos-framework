# DNF — `init` app: materialise the framework tree in a consumer workspace.
#
# Two tools need the framework at a real path, not behind a flake input:
#
# - `just`, which resolves `import` paths statically at parse time;
# - `dnf-generator`, which looks up user profiles (`dnf/home/profiles/`), disko
#   profiles (`dnf/hosts/disko/`) and the machine template on disk, under the
#   workspace root.
#
# The symlink is gitignored by the consumer templates, whose Justfile imports
# `dnf/just/project.just`. It is a GC root (`nix-store --add-root`).
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
  meta.description = "Link the DNF framework tree into a consumer workspace (dnf/)";
  program = toString (
    pkgs.writeShellScript "dnf-init" ''
      set -euo pipefail

      # A directory there is a checkout (co-development): never replaced.
      if [ -e dnf ] && [ ! -L dnf ]; then
        echo "dnf is not a link, left as is." >&2
        exit 1
      fi

      # Indirect GC root: the weekly `nix-collect-garbage` would empty the link
      # otherwise. It follows the link, so the next `init` keeps it.
      nix-store --add-root dnf --realise ${frameworkRoot} >/dev/null
      echo "Linked dnf -> $(readlink dnf)"
      echo "Next: 'nix develop' then 'just --list'."
    ''
  );
}
