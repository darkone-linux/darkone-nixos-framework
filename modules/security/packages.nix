# Package management and updates (R58–R61). (wip)
#
# Covers installing only what is strictly necessary (R58), trusted repositories (R59),
# hardened repositories (R60: linux_hardened), and regular updates (R61).
#
# :::caution[Activation]
# The `enable` option follows `darkone.system.security.enable` by default.
# Rules (Rxx/Cxx) are activated based on level, category, and excludes
# defined in `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R59 — allow-import-from-derivation=false]
# Breaks some complex flakes (Haskell, heavy Python with Nix generators).
# Document exceptions in nix.settings.
# :::
#
# :::caution[R60 — linux_hardened]
# The linux_hardened kernel may lag a minor version behind nixpkgs-unstable.
# Third-party modules (NVIDIA, ZFS) are not guaranteed compatible.
# :::

{
  lib,
  dnfLib,
  config,
  pkgs,
  ...
}:
let
  mainSecurityCfg = config.darkone.system.security;
  cfg = config.darkone.security.packages;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });
in
{
  options = {
    darkone.security.packages.enable = lib.mkEnableOption "Enable ANSSI package management (R58–R61).";

    darkone.security.packages.trustedSubstituters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "https://cache.nixos.org" ];
      description = "Allowlist of authorized Nix binary caches (R59).";
    };

    darkone.security.packages.trustedPublicKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
      description = "Public keys for authorized binary caches (R59).";
    };
  };

  config = lib.mkMerge [
    { darkone.security.packages.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R58 — Install only what is strictly necessary (minimal, base)
        # sideEffects: surprises users used to wget/curl/vim by default
        (lib.mkIf (isActive "R58" "minimal" "base" [ ]) {

          # Empty NixOS default packages
          environment.defaultPackages = lib.mkDefault [ ];

          # man documentation remains useful over SSH
          documentation.man.enable = lib.mkDefault true;

          # TODO: soft warning assertion if systemPackages exceeds a threshold
          # (option darkone.security.packages.maxSystemPackages to add if desired)
        })

        # R59 — Trusted repositories (minimal, base)
        # sideEffects: allow-import-from-derivation=false breaks some complex flakes
        (lib.mkIf (isActive "R59" "minimal" "base" [ ]) {
          nix.settings = {

            # Only substituters listed in trustedSubstituters are allowed
            substituters = cfg.trustedSubstituters;
            trusted-public-keys = cfg.trustedPublicKeys;
            require-sigs = true;

            # Restrict imports from derivations
            allow-import-from-derivation = false;

            # TODO: option to restrict allowed-uris to internal mirrors
            # allowed-uris = [ "https://cache.nixos.org" ];
          };
        })

        # R60 — Hardened repositories: linux_hardened kernel (reinforced, base)
        # Handled by kernel-build.nix via mainSecurityCfg.useHardenedKernel
        # sideEffects: minor version lag, third-party modules potentially incompatible
        (lib.mkIf (isActive "R60" "reinforced" "base" [ ] && mainSecurityCfg.useHardenedKernel) {
          boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_hardened;
        })

        # R61 — Regular updates (minimal, base)
        # DNF: centralized upgrade management — not applicable for now...
        # sideEffects: on critical servers, allowReboot must stay false
        # (lib.mkIf (isActive "R61" "minimal" "base" [ ]) {
        #   system.autoUpgrade = {
        #     enable = lib.mkDefault true;
        #     dates = lib.mkDefault "Sun 03:00";
        #     allowReboot = lib.mkDefault false; # Manual reboot for servers

        #     # TODO: timer comparing current-system to the latest channel commit
        #     # and alerting if drift > 7 days
        #   };
        # })
      ]
    ))
  ];
}
