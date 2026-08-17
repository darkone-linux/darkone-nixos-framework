# DNF — shared development shell.
#
# Single definition behind both the framework's own shell (`flake.nix`) and the
# one `lib/mk-configuration.nix` hands to consumers. They used to be two
# hand-maintained package lists that had already drifted apart by seven entries,
# while a comment claimed they were identical.
#
# `extraPackages` is for what is genuinely specific to one side — the doc
# toolchain and the Rust generator are framework-only, and a consumer has no use
# for them.

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
    just
    mkpasswd
    nix-unit
    nixfmt
    openssl

    # HMAC helper of just-configure-alert-bot.sh (keeps the homeserver
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
