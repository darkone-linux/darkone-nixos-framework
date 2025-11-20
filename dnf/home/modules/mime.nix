# Mime types DNF module. (wip)
#
# :::note
# This module define default applications depending on user profile. For example, markdown editor for...
# - Beginner (default): apostrophe, gnome text editor...
# - Advanced: zed, vim, vscode...
# :::

# TODO:
# - Configuration mime idéale pour chaque type de fichiers (logiciels rapides et fiables)
# - Gnome text editor lit des choses que Zed ne lit pas (adoc) et est rapide, voir si on peut le personnaliser dans nix
# - adoc (text/plain) -> gnome text (vs zed)
# - image -> geeqie (vs navigateur)
# - sh -> zed
# - mp4, mkv & vidéos -> Gnome vidéo ; vlc ; mpv (vs handbrake)
# - svg : geeqie ; inkscape ; krita (vs gimp)

{ lib, config, ... }:

let
  cfg = config.darkone.home.mime;
  type = {
    md = [
      "dev.zed.Zed.desktop"
      "org.gnome.gitlab.somas.Apostrophe.desktop"
      "code.desktop"
      "org.gnome.TextEditor.desktop"
    ];
    pdf = [ "org.gnome.Evince.desktop" ];
    img = [
      "org.geeqie.Geeqie.desktop"
      "firefox-esr.desktop"
      "firefox.desktop"
      "brave.desktop"
    ];
    svg = [
      "org.geeqie.Geeqie.desktop"
      "org.inkscape.Inkscape.desktop"
      "org.kde.krita.desktop"
    ];
    txt = [
      "org.gnome.TextEditor.desktop"
      "dev.zed.Zed.desktop"
    ];
    vid = [
      "org.gnome.Totem.desktop"
      "vlc.desktop"
      "mpv.desktop"
    ];
    mp3 = [
      "audacious.desktop"
      "org.gnome.Music.desktop"
      "org.gnome.Lollypop.desktop"
    ];
    code = [
      "dev.zed.Zed.desktop"
      "code.desktop"
    ];
  };
in
{
  options = {
    darkone.home.mime.enable = lib.mkEnableOption "Enable DNF default applications update";
    #darkone.home.mime.enableAdvanced = lib.mkEnableOption "Update the default applications for advanced profiles";
  };

  config = lib.mkIf cfg.enable {

    # TODO: Default appications
    xdg.mimeApps = {
      enable = true;
      defaultApplications =
        # if cfg.enableAdvanced then
        #   {
        #     "text/plain" = [ "org.gnome.TextEditor.desktop" ];
        #     "application/pdf" = [ "org.gnome.Evince.desktop" ];
        #   }
        # else
        {
          "application/pdf" = type.pdf;
          "audio/aac" = type.mp3;
          "audio/aiff" = type.mp3;
          "audio/basic" = type.mp3;
          "audio/flac" = type.mp3;
          "audio/mp4" = type.mp3;
          "audio/mpeg" = type.mp3;
          "audio/ogg" = type.mp3;
          "audio/vnd.wav" = type.mp3;
          "audio/webm" = type.mp3;
          "audio/x-matroska" = type.mp3;
          "audio/x-ms-wma" = type.mp3;
          "image/bmp" = type.img;
          "image/gif" = type.img;
          "image/jpeg" = type.img;
          "image/pjpeg" = type.img;
          "image/png" = type.img;
          "image/svg+xml" = type.svg;
          "image/tiff" = type.img;
          "image/webp" = type.img;
          "image/x-portable-pixmap" = type.img;
          "text/markdown" = type.md;
          "text/plain" = type.txt;
          "video/mp4" = type.vid;
          "video/mpeg" = type.vid;
          "video/ogg" = type.vid;
          "video/quicktime" = type.vid;
          "video/vnd.mpegurl" = type.vid;
          "video/webm" = type.vid;
          "video/x-m4v" = type.vid;
          "video/x-matroska" = type.vid;
          "video/x-ms-wmv" = type.vid;
          "video/x-msvideo" = type.vid;
          "video/x-sgi-movie" = type.vid;
        };
    };
  };
}
