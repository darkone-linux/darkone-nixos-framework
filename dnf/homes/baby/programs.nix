# Baby profile programs

{ pkgs, ... }:
{
  home.packages = with pkgs; [
    gcompris
    leocad
    tuxpaint
  ];
}
