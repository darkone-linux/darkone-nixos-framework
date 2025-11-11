# Baby home profile

{
  imports = [
    ./../minimal
    ./features.nix
  ];

  # Hide some gnome icons
  darkone.home.gnome.hideTechnicalIcons = true;
}
