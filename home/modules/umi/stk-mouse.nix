# DNF UMI: SuperTuxKart driven by the mouse alone (`enableStkWithMouse`). Doc: `../umi.nix` header.

{
  lib,
  config,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.darkone.home.umi;

  # Groups `input` and `uinput` (cf. home/nixos/umi.nix), X11 focus tracking
  umiHost = osConfig.darkone.host.umi.enable or false;

  # Runs the game, mouse input held as its default keys meanwhile
  stkMouse = pkgs.writers.writePython3Bin "dnf-stk-mouse" {
    libraries = [
      pkgs.python3Packages.evdev
      pkgs.python3Packages.xlib
    ];
  } (builtins.readFile ./stk-mouse.py);

  # Full copy of the game's entry, launched through the converter: XDG_DATA_HOME
  # shadows the packaged one in the menu and the grid (cf. `hiddenApps`).
  stkEntry = pkgs.runCommand "umi-stk-mouse-entry" { } ''
    sed 's|^Exec=.*|Exec=${stkMouse}/bin/dnf-stk-mouse ${lib.getExe pkgs.supertuxkart}|' \
      ${pkgs.supertuxkart}/share/applications/supertuxkart.desktop > $out
  '';
in
{
  config = lib.mkIf (cfg.enable && cfg.enableStkWithMouse && umiHost) {
    home.packages = [ pkgs.supertuxkart ];
    home.file.".local/share/applications/supertuxkart.desktop".source = stkEntry;
  };
}
