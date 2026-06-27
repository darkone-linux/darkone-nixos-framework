# Overlay: replace `pkgs.logseq` (broken electron-forge build) with the official AppImage.
#
# :::caution[Why]
# The `logseq` source build loops forever inside `electron-forge package`
# (nixpkgs#535206): >3h compile, never completes, and pulls EOL/vulnerable
# `electron_39`. We repackage the official AppImage (electron bundled) via
# `appimageTools` — same version, no compile, no `permittedInsecurePackages`.
# :::
#
# :::tip[Cleanup]
# Drop once upstream fixes the source build (nixpkgs#535206) and migrates to
# electron >= 40. Bump `version`/`hash` by hand from the logseq releases
# (https://github.com/logseq/logseq/releases).
# :::

final: _prev:
let

  pname = "logseq";
  version = "0.10.15";

  src = final.fetchurl {
    url = "https://github.com/logseq/logseq/releases/download/${version}/Logseq-linux-x64-${version}.AppImage";
    hash = "sha256-i5EQUvSW1ix+8NT8nCs6mGH2B9xF7G4mB7vBhDJ7JdE=";
  };

  # Extracted tree: source of the `.desktop` entry and the hicolor icons.
  contents = final.appimageTools.extractType2 { inherit pname version src; };

  inherit (final.lib) licenses sourceTypes;
in
{

  logseq = final.appimageTools.wrapType2 {
    inherit pname version src;

    # Upstream `.desktop` points to `Exec=Logseq` (inner binary); repoint it to
    # the `logseq` wrapper exposed by wrapType2, and copy the icons.
    extraInstallCommands = ''
      install -Dm444 ${contents}/Logseq.desktop $out/share/applications/logseq.desktop
      substituteInPlace $out/share/applications/logseq.desktop \
        --replace-fail 'Exec=Logseq' 'Exec=logseq'
      cp -r ${contents}/usr/share/icons $out/share/
    '';

    meta = {
      description = "Privacy-first, open-source knowledge base (official AppImage)";
      homepage = "https://logseq.com";
      license = licenses.agpl3Only;
      sourceProvenance = [ sourceTypes.binaryNativeCode ];
      platforms = [ "x86_64-linux" ];
      mainProgram = "logseq";
    };
  };
}
