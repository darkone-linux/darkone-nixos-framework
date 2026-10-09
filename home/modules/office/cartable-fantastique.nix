# DNF office: Cartable Fantastique toolbar in LibreOffice. Doc: `../office.nix` header.

{
  lib,
  config,
  pkgs,
  ...
}:
let
  inherit (lib) mkIf;
  cfg = config.darkone.home.office;
  edition = cfg.cartableFantastique;
  extension = pkgs.cartable-fantastique.override { inherit edition; };
  oxt = "${extension}/share/libreoffice/extensions/cartable-fantastique.oxt";
  profileDir = "${config.home.homeDirectory}/.config/libreoffice/4/user";

  # The stamp holds the installed `.oxt` store path: unopkg refuses a
  # same-version re-add. New edition or upstream file = new path = reinstall.
  installExtension = pkgs.writeShellScript "cartable-fantastique-install" ''
    set -eu
    stamp="${profileDir}/cartable-fantastique.dnf-stamp"
    installed=""
    if [ -f "$stamp" ]; then
      read -r installed < "$stamp" || true
    fi
    [ "$installed" = "${oxt}" ] && exit 0

    # `--force` replaces an older copy or another edition (same identifier).
    # `SAL_LOG` drops hundreds of `warn:` lines from the xcu parser.
    SAL_LOG=-WARN ${pkgs.libreoffice-stable}/bin/unopkg add --force --suppress-license "${oxt}" < /dev/null
    printf '%s\n' "${oxt}" > "$stamp"
  '';
in
{

  # Per account, not in the store: the macros write their settings
  # (`opt*.conf`) into the extension folder.
  config = mkIf (cfg.enable && cfg.enableOffice && edition != null) {

    # After `onFilesChange` (user tmpfiles): unopkg rewrites
    # `registrymodifications.xcu`; Colibre survives only through its seed link.
    home.activation.cartableFantastique = lib.hm.dag.entryAfter [ "onFilesChange" ] ''
      run ${installExtension} || warnEcho "Cartable Fantastique: install failed, retried at next activation"
    '';
  };
}
