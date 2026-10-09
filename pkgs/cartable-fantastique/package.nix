# cartable-fantastique — LibreOffice toolbar of the Cartable Fantastique.
#
# Reading, writing, maths, tables and text-to-speech helpers for pupils with
# dyspraxia or other DYS disorders. Three editions (`primaire`, `college`,
# `adaptateur`): same extension identifier, only the toolbar set differs.
# Ships the raw `.oxt`; `darkone.home.office.cartableFantastique` installs it.
#
# :::caution[Bump by hand]
# Upstream replaces `….v5.oxt` in place: new hash, same URL, so `just
# pkg-update` sees nothing. Refresh `hashes` with `nix store prefetch-file
# <url>`; a stale hash only bites once the store copy is garbage-collected.
# :::

{
  lib,
  stdenvNoCC,
  fetchurl,
  edition ? "primaire",
}:

let
  hashes = {
    primaire = "sha256-YJctup/u867f8Em/Fe7AetV3TSknGbUoqPLZqdVqGgs=";
    college = "sha256-stVy6D+EfLWeUhb/mXSPTEP5+Abha9Fo81JQpibYaCU=";
    adaptateur = "sha256-K/WuFX6caz5nwI5e3d4jgLbQWRqgqFERLSUXpy/uvSA=";
  };
in
assert lib.assertOneOf "edition" edition (lib.attrNames hashes);

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "cartable-fantastique";
  version = "5.0.0";

  src = fetchurl {
    url = "https://cartablefantastique.fr/wp-content/uploads/Ressources/OutilsPourCompenser/LibreOffice/Lbo_CartableFantastique_${edition}.v${lib.versions.major finalAttrs.version}.oxt";
    hash = hashes.${edition};
  };

  dontUnpack = true;

  # Edition-independent file name: `unopkg add --force` replaces by identifier.
  installPhase = ''
    runHook preInstall
    install -Dm644 $src $out/share/libreoffice/extensions/cartable-fantastique.oxt
    runHook postInstall
  '';

  passthru = { inherit edition; };

  meta = {
    description = "Cartable Fantastique toolbar for LibreOffice, for pupils with DYS disorders";
    homepage = "https://www.cartablefantastique.fr/outils-pour-compenser/le-plug-in-libre-office/";

    # Free of charge, no published license; macros are password-protected.
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryBytecode ];
    platforms = lib.platforms.all;

    # Filled in when the package is submitted to nixpkgs (cf. `pr-nixpkgs`).
    maintainers = [ ];
  };
})
