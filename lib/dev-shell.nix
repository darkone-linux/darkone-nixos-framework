# DNF — shared development shell.
#
# Single package list behind the framework shell (`flake.nix`) and the one
# `lib/mk-configuration.nix` hands to consumers. `extraPackages`: what only one
# side needs (framework: doc toolchain, `dnf-generator` binary).

{
  pkgs,
  colmena,
  extraPackages ? [ ],
}:

pkgs.mkShell {
  packages = [
    colmena
  ]
  ++ (with pkgs; [
    age
    cargo
    deadnix
    git

    # Changelog generation behind `just bump` / `just release`.
    git-cliff
    just
    mkpasswd
    nix-unit
    nixfmt
    openssl

    # HMAC helper of just/scripts/configure-alert-bot.sh (keeps the homeserver
    # registration shared secret out of argv).
    python3
    rustc
    sops
    ssh-to-age
    statix
    treefmt
    yq-go
    zsh
  ])
  ++ extraPackages;

  shellHook = "exec zsh";
}
