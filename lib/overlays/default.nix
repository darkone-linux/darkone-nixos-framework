# DNF — nixpkgs overlays of every host, in application order.
#
# Applied through a module by `lib/mk-configuration.nix`: `nixosSystem`
# builds its own `pkgs`, which a flake-level overlay never reaches. Why each
# one exists: its own header; a temporary one also has its entry in
# `config/workarounds.nix`.
#
# :::caution[Order matters]
# A later overlay sees the earlier ones through `prev`: reordering the list
# can change every host.
# :::

{ inputs }: system: [

  # DNF-only packages (`pkgs/`): permanent until each one is upstreamed.
  (import ../../pkgs/overlay.nix)

  # `pkgs.dnf-generator` for `admin/fleet-update.nix`, x86_64 only: absent
  # elsewhere, hence `pkgs.dnf-generator or null` on the consumer side. Built
  # on `system`: reading `final.stdenv` recurses on test-driver nodes.
  (
    _final: _prev:
    inputs.nixpkgs.lib.optionalAttrs (inputs.dnf-generator.packages ? ${system}) {
      dnf-generator = inputs.dnf-generator.packages.${system}.default;
    }
  )

  # Temporary workarounds (`config/workarounds.nix`).
  (import ./geneweb.nix { inherit (inputs) nixpkgs-geneweb; } system)
  (import ./logseq.nix)
  (import ./kernel-modules-sign.nix)
  (import ./posthog.nix)
  (import ./digital.nix)
  (import ./lk-jwt-service.nix)
  (import ./presenterm.nix)
  (import ./thonny.nix)

  # `pkgs.talon` (UMI host profiles), x86_64 only.
  (import ./talon.nix { inherit (inputs) talon-nix; } system)

  # Temporary: pin of `pkgs.opencode` (`config/workarounds.nix`).
  (import ./opencode.nix { inherit (inputs) nixpkgs-opencode; } system)

  # `pkgs.openclaw-gateway` for AI spaces, fetched only by a host running it.
  (import ./openclaw.nix { inherit (inputs) nix-openclaw; } system)

  # `pkgs.claude-code-nix`: the Claude Code of `darkone.home.ai`.
  (import ./claude-code.nix { inherit (inputs) claude-code; } system)
]
