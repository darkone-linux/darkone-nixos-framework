{
  lib,
  pkgs,
  config,
  osConfig,
  host,
  zone,
  ...
}:
let
  hasServer = osConfig.darkone.service.nfs.enable;
  nfsServer = (lib.findFirst (s: s.service == "nfs") null zone.sharedServices).host;
  isClient = host.hostname != nfsServer;
  baseDir = if isClient then "/mnt/nfs" else "/export";
in
{
  # Home dirs creation
  # IMPORTANT: international names do NOT works with xdg.userDirs
  # This script create links from user dirs to NFS targets
  home.activation.bindXdgToNfs = lib.mkIf hasServer (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''

      # Required to update correctly user dirs
      rm -f ~/.config/user-dirs.*
      ${pkgs.xdg-user-dirs}/bin/xdg-user-dirs-update --force
      . ~/.config/user-dirs.dirs

      function createHomeDir() {
        if [ -d "$2" ] && [ ! -L "$2" ]; then
          rmdir "$2" || mv "$2" "$2".bak
        fi
        if [ ! -e "$2" ] ;then
          ln -sfn "$1" "$2"
        fi
      }

      createHomeDir ${baseDir}/homes/${config.home.username}/Documents "$XDG_DOCUMENTS_DIR"
      createHomeDir ${baseDir}/homes/${config.home.username}/Pictures "$XDG_PICTURES_DIR"
      createHomeDir ${baseDir}/homes/${config.home.username}/Music "$XDG_MUSIC_DIR"
      createHomeDir ${baseDir}/homes/${config.home.username}/Videos "$XDG_VIDEOS_DIR"
      createHomeDir ${baseDir}/homes/${config.home.username}/Downloads "$XDG_DOWNLOAD_DIR"
      createHomeDir ${baseDir}/homes/${config.home.username}/Desktop "$XDG_DESKTOP_DIR"
      createHomeDir ${baseDir}/homes/${config.home.username}/Templates "$XDG_TEMPLATES_DIR"
      createHomeDir ${baseDir}/common "$XDG_PUBLICSHARE_DIR"
    ''
  );
}
