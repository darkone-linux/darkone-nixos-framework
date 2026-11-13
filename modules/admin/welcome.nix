# First-boot welcome page of the admin host installed by `darkone new`.
#
# At the first GNOME session of each `wheel` member, the browser opens a local
# page: step 1 of 4 done (the admin host), the gateway next, then services and
# the coordination server, with links to the documentation. Shown once per
# user (`~/.local/state/dnf/welcome-shown`). The "Onboarding" launcher of the
# nix-admin reopens it (`darkone.admin.welcome.command`).
#
# While the witness `/var/lib/dnf/backup-admin` of `just backup-admin` is
# missing, the page opens with a banner: the admin keys are not backed up.
#
# :::note[Set by the installer]
# `darkone new` writes `darkone.admin.welcome.enable = true;` in the
# `configuration.nix` of the admin host. Remove the line to stop the page for
# the users who have not seen it yet.
# :::

{
  lib,
  config,
  pkgs,
  host,
  network,
  ...
}:
let
  cfg = config.darkone.admin.welcome;

  page = pkgs.replaceVars ./../../assets/welcome/index.html {
    inherit (host) hostname;
    inherit (network) domain;
  };

  # Written by `just backup-admin` (just/scripts/backup-admin.sh), world-readable.
  witness = "/var/lib/dnf/backup-admin";

  # Marked once the browser got the page: a failed open shows it next time.
  # `--again` (launcher): neither marker nor wheel check, always opens.
  open = pkgs.writeShellScript "dnf-welcome" ''
    marker="''${XDG_STATE_HOME:-$HOME/.local/state}/dnf/welcome-shown"
    again=false
    [ "''${1:-}" != --again ] || again=true
    if ! $again; then
      [ ! -e "$marker" ] || exit 0
      ${pkgs.coreutils}/bin/id -nG | ${pkgs.gnugrep}/bin/grep -qw wheel || exit 0
    fi

    # Fragment, not `?query`: gio behind xdg-open drops the query of a
    # file:// URL and keeps the fragment, which the page reads.
    url=file://${page}
    [ -e ${witness} ] || url="$url#backup=missing"
    ${pkgs.xdg-utils}/bin/xdg-open "$url" || exit 0
    ! $again || exit 0
    ${pkgs.coreutils}/bin/mkdir -p "''${marker%/*}"
    ${pkgs.coreutils}/bin/touch "$marker"
  '';
in
{
  options.darkone.admin.welcome.enable =
    lib.mkEnableOption "the first-boot welcome page of the admin host";

  # Behind the "Onboarding" launcher too (home/modules/advanced/network-folder.nix)
  options.darkone.admin.welcome.command = lib.mkOption {
    type = lib.types.path;
    default = open;
    readOnly = true;
    internal = true;
    description = "The script opening the welcome page, `--again` to reopen it";
  };

  config = lib.mkIf cfg.enable {
    environment.etc."xdg/autostart/dnf-welcome.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=DNF welcome
      Exec=${open}
      OnlyShowIn=GNOME;
      NoDisplay=true
    '';
  };
}
