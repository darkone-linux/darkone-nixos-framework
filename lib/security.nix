# Helpers for the security modules (ANSSI rules).

{ lib }:
let
  levelMapping = {
    "minimal" = 0;
    "intermediary" = 1;
    "reinforced" = 2;
    "high" = 3;
  };
in
{
  inherit levelMapping;

  # Activation predicate for an ANSSI rule.
  #
  # A rule is active iff:
  #   - the security module is enabled;
  #   - current level >= rule severity;
  #   - the category is compatible (base = universal);
  #   - none of the rule tags is in `excludes`;
  #   - no explicit exception exists for this identifier.
  mkIsActive =
    cfg: ruleId: severity: category: tags:
    cfg.enable
    && levelMapping.${severity} <= levelMapping.${cfg.level}
    && (category == "base" || category == cfg.category)
    && lib.all (tag: !(lib.elem tag cfg.excludes)) tags
    && !(lib.hasAttr ruleId cfg.exceptions);

  # ANSSI systemd hardening baseline (R63), reused by R52/R55 too.
  #
  # Returns a `serviceConfig` attrset to merge into a unit. Covers
  # ProtectSystem/ProtectHome confinement, RuntimeDirectoryMode=0750 (R52),
  # PrivateTmp (R55), a `@system-service` syscall filter and an empty
  # capability set. `MemoryDenyWriteExecute` is the only W^X knob that breaks
  # JIT runtimes (Java, V8, .NET, LuaJIT, Wasm); `needsJit = true` (or the
  # `needs-jit` exclude tag, resolved by the caller) drops it.
  mkHardenedServiceConfig =
    {
      needsJit ? false,
    }:
    {
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      RuntimeDirectoryMode = "0750";
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
        "~@resources"
      ];
      CapabilityBoundingSet = "";
      UMask = "0027";
    }
    // lib.optionalAttrs (!needsJit) { MemoryDenyWriteExecute = true; };
}
