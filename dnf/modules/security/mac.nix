# Mandatory Access Control — MAC (R37, R45–R49). (wip)
#
# R37 is a meta rule: valid if at least R45 (AppArmor) or R46 (SELinux)
# is active. SELinux (R46–R49) is not supported on NixOS and is excluded
# by default via `exceptions`. AppArmor (R45) is partially supported.
#
# :::tip[Sandboxing]
# When MAC is unavailable, NixOS often relies on systemd options
# (systemd sandboxing) to isolate services.
# :::
#
# :::note[NixOS and MAC]
# SELinux is structurally unsupported on NixOS (R46–R49 are exceptions by
# default). AppArmor is available but with few ready-to-use profiles.
# The absence of a profile for an exposed service is a false sense of security.
# :::
#
# :::caution[Activation]
# The `enable` option follows `darkone.system.security.enable` by default.
# Rules (Rxx/Cxx) are activated based on level, category, and excludes
# defined in `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[Tag no-mac]
# Use the `no-mac` tag in `excludes` to disable R37 and R45 with an explicit
# justification in `exceptions.R37.rationale`.
# :::

{
  lib,
  dnfLib,
  config,
  ...
}:
let
  mainSecurityCfg = config.darkone.system.security;
  cfg = config.darkone.security.mac;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });
in
{
  options = {
    darkone.security.mac.enable = lib.mkEnableOption "Enable ANSSI MAC module — AppArmor/SELinux (R37, R45–R49).";
  };

  config = lib.mkMerge [
    { darkone.security.mac.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R37 — Use a MAC (reinforced, base, tag: no-mac)
        # Meta rule: valid iff R45 OR R46 is active.
        # On NixOS: R46 is an exception → R37 valid only if R45 is active.
        (lib.mkIf (isActive "R37" "reinforced" "base" [ "no-mac" ]) {
          # Assertion: at least one MAC active
          assertions = [
            {
              assertion =
                config.security.apparmor.enable

                # SELinux unsupported: no check
                || lib.hasAttr "R37" mainSecurityCfg.exceptions;
              message =
                "R37: At least one MAC (AppArmor) must be active at the 'reinforced' level. "
                + "Use exceptions.R37.rationale to document the absence of MAC.";
            }
          ];
        })

        # R45 — AppArmor (reinforced, base, tag: no-mac)
        # sideEffects: few ready-to-use NixOS profiles; custom profiles to maintain
        (lib.mkIf (isActive "R45" "reinforced" "base" [ "no-mac" ]) {
          security.apparmor = {
            enable = true;

            # Profiles in enforce mode (not learn/complain)
            # TODO: add DNF in-house profiles for registered services
            packages = [ ]; # e.g. pkgs.apparmor-profiles
            policies = {
              # Example inline profile:
              # "dnf-nginx".profile = ''
              #   /usr/sbin/nginx {
              #     ...
              #   }
              # '';
            };
          };
        })

        # R46 — SELinux targeted enforcing (high, base) → NixOS exception by default
        # R47 — Confine interactive users (high) → same
        # R48 — SELinux boolean variables (high) → same
        # R49 — Uninstall SELinux debug tools (high) → same
        # These rules are in mainSecurityCfg.exceptions by default (see security.nix).
        # Without SELinux: the checkScript would return code 2 (undetermined).

      ]
    ))
  ];
}
