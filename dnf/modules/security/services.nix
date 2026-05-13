# Hardening of systemd services (R62–R66). (wip)
#
# Covers disabling unnecessary services (R62), reducing functionality via
# systemd security options (R63), privilege restriction (R64),
# isolation (R65), and hardening of containerization components (R66).
#
# :::caution[Activation]
# The `enable` option follows `darkone.system.security.enable` by default.
# Rules (Rxx/Cxx) are activated based on level, category, and excludes
# defined in `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R63 — MemoryDenyWriteExecute]
# Breaks JIT runtimes (Java, V8, .NET, LuaJIT, Wasm). Use the
# `needs-jit` tag in `excludes` or exclude the service individually.
# :::
#
# :::caution[R66 — Docker userns-remap]
# Breaks host-to-container bind-mounts (UID shift). Migration of existing
# volumes required before enabling.
# :::

{
  lib,
  dnfLib,
  config,
  ...
}:
let
  mainSecurityCfg = config.darkone.system.security;
  cfg = config.darkone.security.services;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });

  # Helper: produces systemd hardening options for a service (R63, R65)
  # To be applied via `systemd.services.<name>.serviceConfig`

  # List of services to disable in the server category (R62)
  serverDisabledServices = [
    "cups"
    "avahi-daemon"
    "bluetooth"
    "ModemManager"
    "wpa_supplicant"
    "accounts-daemon"
    "geoclue"
  ];

  # Services always disabled (obsolete protocols)
  alwaysDisabledServices = [
    "telnet"
    "rsh"
    "rlogin"
    "tftp"
    "talk"
  ];
in
{
  options = {
    darkone.security.services.enable = lib.mkEnableOption "Enable ANSSI hardening of systemd services (R62–R66).";

    darkone.security.services.rootServicesAllowed = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "systemd services allowed to run as root without CapabilityBoundingSet (R64).";
    };
  };

  # Expose mkHardenedServiceConfig to other DNF modules.
  # ARCHITECTURAL DECISION: to share this helper with DNF service modules,
  # we could add it to dnfLib. For now, it stays local to security.
  # TODO: migrate to dnfLib.mkHardenedServiceConfig if adoption is broad

  config = lib.mkMerge [
    { darkone.security.services.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R62 — Disable unnecessary services (minimal, base)
        # sideEffects: disabling avahi breaks printer discovery, bluetooth breaks BT keyboards
        (lib.mkIf (isActive "R62" "minimal" "base" [ ]) {
          systemd.services = lib.mkMerge [

            # Always-disabled services (obsolete protocols)
            (lib.genAttrs alwaysDisabledServices (_: {
              enable = false;
            }))

            # Services disabled in server mode only
            (lib.optionalAttrs (mainSecurityCfg.category == "server") (
              lib.genAttrs serverDisabledServices (_: {
                enable = false;
              })
            ))
          ];
        })

        # R63 — Reduce service functionality (intermediary, base)
        # sideEffects: MemoryDenyWriteExecute breaks JIT (just-in-time compilation), ProtectSystem=strict enforces ReadWritePaths
        (lib.mkIf (isActive "R63" "intermediary" "base" [ ]) {

          # TODO: apply mkHardenedServiceConfig to registered DNF services
          # via darkone.system.services.service.<name> (services.nix integration)
          # For now: individual services apply the helper manually.
          # Example:
          # systemd.services.myservice.serviceConfig = mkHardenedServiceConfig { };
        })

        # R64 — Service privileges (reinforced, base)
        # sideEffects: heavy audit on legacy services
        (lib.mkIf (isActive "R64" "reinforced" "base" [ ]) {
          assertions = [
            {
              assertion = lib.all (
                name:
                let
                  svc = config.systemd.services.${name};
                  user = svc.serviceConfig.User or "";
                  caps = svc.serviceConfig.CapabilityBoundingSet or null;
                in
                user != "root" || caps != null || lib.elem name cfg.rootServicesAllowed
              ) (lib.attrNames config.systemd.services);
              message =
                "R64: Every root service must declare CapabilityBoundingSet or be "
                + "listed in darkone.security.services.rootServicesAllowed.";
            }
          ];
        })

        # R65 — Isolate services (reinforced, base)
        # sideEffects: PrivateNetwork=yes forbids network IPC (unsuitable for network daemons)
        (lib.mkIf (isActive "R65" "reinforced" "base" [ ]) {

          # TODO: apply PrivateNetwork=yes and PrivateUsers=yes to services
          # that do not need the network (via a per-DNF-service option)
        })

        # R66 — Harden isolation components (high, base)
        # sideEffects: Docker userns-remap breaks bind-mounts, volume migration required
        (lib.mkIf (isActive "R66" "high" "base" [ ]) {

          # Docker
          virtualisation.docker.daemon.settings = lib.mkIf config.virtualisation.docker.enable {
            "userns-remap" = "default";
            "no-new-privileges" = true;
            "live-restore" = true;
            icc = false;
            "userland-proxy" = false;
          };

          # Podman
          virtualisation.podman = lib.mkIf config.virtualisation.podman.enable { dockerCompat = false; };
        })
      ]
    ))
  ];
}
