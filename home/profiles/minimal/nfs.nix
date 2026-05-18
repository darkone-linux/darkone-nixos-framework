{
  lib,
  pkgs,
  config,
  osConfig,
  hosts,
  host,
  zone,
  network,
  ...
}:
let
  hasServer = osConfig.darkone.service.nfs.enable;
  nfsServer =
    if hasServer then
      (lib.findFirst (s: s.name == "nfs" && s.zone == zone.name) null network.services).host
    else
      null;
  isServer = nfsServer != null && host.hostname == nfsServer;
  isClient =
    nfsServer != null
    && !isServer
    && lib.hasAttr "nfs-client" host.features
    && host.features.nfs-client == (lib.findFirst (h: h.hostname == nfsServer) null hosts).zone;
  isEnable = hasServer && (isServer || isClient);
  inherit (osConfig.darkone.system) srv-dirs;
  baseDir = if isServer then srv-dirs.nfs else "/mnt/nfs";
in
{
  # Home dirs creation
  # IMPORTANT: international names do NOT works with xdg.userDirs
  # This script create links from user dirs to NFS targets
  # NOTE: XDG_DATA_DIRS is required otherwise xdg-user-dirs-update do not find local traductions (mo files)
  home.activation.bindXdgToNfs = lib.mkIf isEnable (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''

      # Required to update correctly user dirs
      rm -f ~/.config/user-dirs.*
      XDG_DATA_DIRS="${pkgs.xdg-user-dirs}/share" ${pkgs.xdg-user-dirs}/bin/xdg-user-dirs-update --force
      . ~/.config/user-dirs.dirs

      function createHomeDir() {
        if [ -d "$2" ] && [ ! -L "$2" ]; then
          rmdir "$2" || mv "$2" "$2".bak
        fi
        if [ -L "$2" ]; then
          if [ "$(readlink -- $2)" != "$1" ]; then
            ln -sfn "$1" "$2"
          fi
          return
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

      if [ -L ${config.home.homeDirectory}'/.config/gtk-3.0/bookmarks' ]; then
        rm -f ${config.home.homeDirectory}'/.config/gtk-3.0/bookmarks'
      fi
      mkdir -p ${config.home.homeDirectory}'/.config/gtk-3.0'
      echo 'file://'$XDG_DOCUMENTS_DIR > ${config.home.homeDirectory}'/.config/gtk-3.0/bookmarks'
      echo 'file://'$XDG_PICTURES_DIR >> ${config.home.homeDirectory}'/.config/gtk-3.0/bookmarks'
      echo 'file://'$XDG_DOWNLOAD_DIR >> ${config.home.homeDirectory}'/.config/gtk-3.0/bookmarks'
      echo 'file://'$XDG_PUBLICSHARE_DIR >> ${config.home.homeDirectory}'/.config/gtk-3.0/bookmarks'
      echo 'file://'$XDG_MUSIC_DIR >> ${config.home.homeDirectory}'/.config/gtk-3.0/bookmarks'
      echo 'file://'$XDG_VIDEOS_DIR >> ${config.home.homeDirectory}'/.config/gtk-3.0/bookmarks'
    ''
  );
}
