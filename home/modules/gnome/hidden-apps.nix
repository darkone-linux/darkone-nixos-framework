# Launchers hidden from the app grid, gathered from `gnome.nix` and `umi.nix`.

{
  lib,
  config,
  osConfig,
  pkgs,
  ...
}:
let
  ids = lib.unique config.darkone.home.gnome.hiddenEntries;

  # Full copies with `NoDisplay` forced: a bare stub would also shadow the
  # entry for launches by id and file associations. Leading blanks allowed,
  # as GKeyFile does: talon-nix indents its whole entry.
  entries = pkgs.runCommand "hidden-apps" { } ''
    mkdir -p $out
    for id in ${lib.escapeShellArgs ids} ; do
      for dir in ${osConfig.system.path}/share/applications ${config.home.path}/share/applications ; do
        if [ -e "$dir/$id" ] ; then
          sed -e '/^[[:blank:]]*NoDisplay=/d' -e '/^[[:blank:]]*\[Desktop Entry\]/a NoDisplay=true' "$dir/$id" > "$out/$id"
          break
        fi
      done
    done
  '';
in
{
  options.darkone.home.gnome.hiddenEntries = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    internal = true;
    description = "Desktop file ids hidden from the app grid: `gnome.hiddenApps`, `umi.hiddenApps` of a UMI host";
  };

  # Linked file by file into a real directory: an absent app gets nothing,
  # and the entries other programs write there (web apps, games) still land.
  config.home.file.".local/share/applications" = lib.mkIf (ids != [ ]) {
    source = entries;
    recursive = true;
  };
}
