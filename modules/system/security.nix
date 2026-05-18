# ANSSI BP-028 v2.0 (GNU/Linux) system hardening. (wip)
#
# Recommended module, enabled in certain host profiles or manually
# depending on needs. Progressively applies
# ANSSI recommendations according to the chosen level and machine category.
# Each host profile defines its level and category:
#
# :::danger[Module under development]
# - Refine and test options, features, etc.
# - Create the "checkScript", a security config introspection tool.
# - Simple local config for hardware-specific and needs-specific settings.
# :::
#
# ```nix
# darkone.system.security = {
#   level    = "intermediary"; # minimal | intermediary | reinforced | high
#   category = "server";       # base | client | server
# };
# ```
#
# Rules incompatible with the environment are excluded by tag:
#
# ```nix
# darkone.system.security.excludes = [ "needs-jit" "needs-hibernation" ];
# ```
#
# A specific rule can be bypassed with a mandatory rationale:
#
# ```nix
# darkone.system.security.exceptions = {
#   R9.rationale = "Docker rootless required during development.";
# };
# ```
#
# :::note[ANSSI hardening level]
# - `minimal`      : common base, any system (default).
# - `intermediary` : recommended for almost all systems.
# - `reinforced`   : sensitive or multi-tenant systems.
# - `high`         : dedicated skills and budget; implies kernel
#                    recompilation (tag `kernel-recompile`) if not excluded.
# :::
#
# :::note[Machine category]
# - `base`   : universal rules, always applied (default).
# - `client` : workstation (GUI, USB, session, locking).
# - `server` : server (hardened network, centralized logging, exposed services).
#
# Independent of `host.profile` — to be explicitly defined in each host profile.
# :::
#
# :::note[Exclusion tags]
# - `kernel-recompile`             : ignores R15–R27, C1 (no custom kernel).
# - `disable-kernel-module-loading`: ignores R10 (may break devices).
# - `no-ipv6`                      : ignores R13, R22 (IPv6 disable).
# - `no-mac`                       : ignores R37, R45 (no active MAC).
# - `no-sealing`                   : ignores R76, R77 (no HIDS/AIDE).
# - `no-auditd`                    : ignores R73 (auditd not configurable).
# - `embedded`                     : relaxes /var, /home constraints, etc.
# - `needs-jit`                    : allows relaxed W^X (Java, .NET, V8, Wasm).
# - `needs-kexec`                  : keeps kexec for kdump.
# - `needs-binfmt`                 : keeps binfmt_misc (Java, qemu-static).
# - `needs-hibernation`            : keeps hibernation (laptops).
# - `needs-usb-hotplug`            : disables USBGuard / deny_new_usb.
# :::
#
# :::note[Per-rule exceptions]
# A rule with an exception is excluded from activation even if the level would cover it.
# Mandatory rationale in `rationale`.
# :::
#
# :::caution[Side effects]
# Some rules may break common usage: `noexec /tmp` (R28),
# SMT disabled (R8), unsigned modules (R18), rootless containers (R9),
# JIT (R63). Check `sideEffects` comments in each themed file before
# raising the level on a production system.
# :::

{ lib, network, ... }:
{
  options = {
    darkone.system.security = {
      enable = lib.mkEnableOption "Enable the ANSSI BP-028 v2.0 hardening module.";

      level = lib.mkOption {
        type = lib.types.enum [
          "minimal"
          "intermediary"
          "reinforced"
          "high"
        ];
        default = "minimal";
        description = "Targeted ANSSI hardening level.";
      };

      category = lib.mkOption {
        type = lib.types.enum [
          "base"
          "client"
          "server"
        ];
        default = "base";
        description = "Machine category that selects rule subsets.";
      };

      excludes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "kernel-recompile"
          "no-ipv6"
          "needs-usb-hotplug"
          "needs-jit"
        ];
        description = "Tags that disable entire rule groups.";
      };

      exceptions = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options.rationale = lib.mkOption {
              type = lib.types.lines;
              description = "Mandatory rationale for disabling this specific rule.";
            };
          }
        );
        default = {

          # SELinux is unsupported on NixOS — structural exception
          R46.rationale = "SELinux is unsupported on NixOS.";
          R47.rationale = "SELinux is unsupported on NixOS.";
          R48.rationale = "SELinux is unsupported on NixOS.";
          R49.rationale = "SELinux is unsupported on NixOS.";
        };
        description = "Per-rule exceptions with mandatory rationale.";
      };

      # --- Cross-cutting options (used by multiple themed files) ---

      adminMailbox = lib.mkOption {
        type = lib.types.str;
        default = "admin@${network.domain}";
        example = "admin@exemple.fr";
        description = "Administrator email address (sudo R39, MTA aliases R75).";
      };

      useHardenedKernel = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Use linuxPackages_hardened (R60, C1) instead of the default kernel.";
      };

      allowedActiveUsers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Exhaustive list of active user accounts (R30 validation).";
      };
    };
  };
}
