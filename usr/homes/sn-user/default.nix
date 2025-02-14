{
  config,
  host,
  lib,
  ...
}:
let
  isSnPc = builtins.match "^pc.*" host.hostname != null;
in
{
  imports = [
    ./../../../lib/homes/student
    ./programs.nix
  ];

  # Zed editor
  darkone.home.zed.enable = true;

  home = {

    # Shared home only if in SN pc
    homeDirectory = lib.mkIf isSnPc (lib.mkForce "/mnt/home/${config.home.username}");
    stateVersion = "25.05";
  };
}
