# Darkone Network administrator

{ inputs, ... }: {
  imports = [
    ./../admin
    ./features.nix

    # Prebuilt nix-index DB + `comma` (`,`): the module pins a `nix-index`
    # package shipping the weekly DB and symlinks it into the user cache.
    inputs.nix-index-database.homeModules.nix-index
  ];

  # Per-user nix indexer: enables `nix-locate` and the shell handler that
  # resolves unknown commands against the prebuilt DB above.
  programs.nix-index = {
    enable = true;
    enableZshIntegration = true;
  };

  # `,` runs an uninstalled program by resolving it against the nix-index DB.
  programs.nix-index-database.comma.enable = true;

  programs.zsh.shellAliases = {
    nx = "cd /etc/nixos";
    nf = "nixfmt -s"; # Nix Format
    nc = "deadnix"; # Nix Check
    dnf = "cd ~/dnf";
    jc = "just clean";
    mrproper = "nix-collect-garbage --delete-old && sudo nix-collect-garbage -d && sudo /run/current-system/bin/switch-to-configuration boot";
  };
}
