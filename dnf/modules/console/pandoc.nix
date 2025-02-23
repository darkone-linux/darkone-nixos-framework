{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.console.pandoc;
in
{
  options = {
    darkone.console.pandoc.enable = lib.mkEnableOption "Pre-configured pandoc environment";
  };

  config = lib.mkIf cfg.enable {

    # Font used in pdf documents
    fonts.packages = with pkgs; [ gentium ];

    # Pandoc package + dependencies
    environment.systemPackages = with pkgs; [
      pandoc
      texliveConTeXt
      perl538Packages.ImageExifTool
    ];
  };
}
