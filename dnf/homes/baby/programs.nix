# Baby profile programs

{ pkgs, ... }:
{
  home.packages = with pkgs; [
    #gcompris # TODO: fail
    leocad
    tuxpaint
  ];
}
