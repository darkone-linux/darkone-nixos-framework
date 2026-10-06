# DNF — helpers for the security modules (ANSSI rules).

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

  # An ANSSI rule is active iff the module is enabled, the level reaches the
  # rule severity, the category matches (`base` = universal), no rule tag is
  # in `excludes` and no exception names the rule.
  mkIsActive =
    cfg: ruleId: severity: category: tags:
    cfg.enable
    && levelMapping.${severity} <= levelMapping.${cfg.level}
    && (category == "base" || category == cfg.category)
    && lib.all (tag: !(lib.elem tag cfg.excludes)) tags
    && !(lib.hasAttr ruleId cfg.exceptions);

  # `serviceConfig` hardening baseline (R63, with R52 runtime dir and R55
  # PrivateTmp). `needsJit` drops `MemoryDenyWriteExecute`, the one knob that
  # breaks JIT runtimes (Java, V8, .NET, LuaJIT, Wasm).
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
