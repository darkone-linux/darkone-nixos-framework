# rename-simple — renames files to clean, ASCII-safe slugs.
#
# Transliterates accents, ligatures, Greek and Cyrillic to ASCII, lowercases,
# and collapses separators. Installed by the `advanced` home profile
# (`enableEssentials`), beside perl's `rename`.
#
# :::note[Not in nixpkgs]
# Upstream ships its own flake, but a runtime tool has no reason to be a
# framework input (cf. `pkgs/README.md`). Bump with `just pkg-update
# rename-simple`; upstream releases at
# <https://github.com/darkone-linux/rename-simple/releases>.
# :::

{
  lib,
  rustPlatform,
  fetchFromGitHub,
  versionCheckHook,
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "rename-simple";
  version = "0.7.2";

  src = fetchFromGitHub {
    owner = "darkone-linux";
    repo = "rename-simple";
    tag = "v${finalAttrs.version}";
    hash = "sha256-YGP5FNgIp/d6TyHkBgDzwvcn1J2MktQnQkuQvvrWLBo=";
  };

  cargoHash = "sha256-ydoIQPmMnpRCfRYRRbfMUPkEoLTfI/meIPg4bcrin9s=";

  # buildRustPackage installs binaries only; without this `man rename-simple`
  # is lost. Nix compresses man pages itself: install the uncompressed source.
  postInstall = ''
    install -Dm644 man/rename-simple.1 $out/share/man/man1/rename-simple.1
  '';

  nativeInstallCheckInputs = [ versionCheckHook ];
  doInstallCheck = true;

  meta = {
    description = "Rename files to clean, ASCII-safe slugs";
    homepage = "https://github.com/darkone-linux/rename-simple";
    changelog = "https://github.com/darkone-linux/rename-simple/blob/v${finalAttrs.version}/CHANGELOG.md";
    license = lib.licenses.mit;
    mainProgram = "rename-simple";
    platforms = lib.platforms.linux;

    # Filled in when the package is submitted to nixpkgs (cf. `pr-nixpkgs`).
    maintainers = [ ];
  };
})
