# Darkone Network administrator

{
  imports = [
    ./../admin
    ./features.nix
  ];

  programs.zsh.shellAliases = {
    nx = "cd /etc/nixos";
    nf = "nixfmt -s"; # Nix Format
    nc = "deadnix"; # Nix Check
    dnf = "cd ~/dnf";
    jc = "just clean";
    mrproper = "nix-collect-garbage --delete-old && sudo nix-collect-garbage -d && sudo /run/current-system/bin/switch-to-configuration boot";
  };
}
