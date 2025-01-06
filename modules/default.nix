{
  imports = [
    ./admin/nix.nix
    ./system/i18n.nix
    ./system/documentation.nix
    ./system/core.nix
    ./system/hardware.nix
    ./graphic/gnome.nix
    ./graphic/virt-manager.nix
    ./graphic/packages.nix
    ./host/laptop.nix
    ./host/server.nix
    ./host/minimal.nix
    ./services/printing.nix
    ./services/audio.nix
    ./services/httpd.nix
    ./console/pandoc.nix
    ./console/zsh.nix
    ./console/packages.nix
    ./console/git.nix
  ];
}
