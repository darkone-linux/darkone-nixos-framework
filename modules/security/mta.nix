# Local mail handling (R74–R75). (wip)
#
# Covers the local MTA hardened to loopback-only (R74) and mail aliases
# routed to the administrator's address (R75). These rules only apply if
# an MTA service is active (Postfix or OpenSMTPD).
#
# :::caution[Activation]
# The `enable` option follows `darkone.system.security.enable` by default.
# Rules (Rxx/Cxx) are activated based on level, category, and excludes
# defined in `darkone.system.security` (via `isActive`).
# :::

{
  lib,
  dnfLib,
  config,
  ...
}:
let
  mainSecurityCfg = config.darkone.system.security;
  cfg = config.darkone.security.mta;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });

  hasMta = config.services.postfix.enable or false || config.services.opensmtpd.enable or false;
  adminMail = mainSecurityCfg.adminMailbox;
in
{
  options = {
    darkone.security.mta.enable = lib.mkEnableOption "Enable ANSSI MTA hardening (R74–R75).";
  };

  config = lib.mkMerge [
    { darkone.security.mta.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R74 — Hardened local mail (intermediary, base)
        # Condition: MTA active
        # sideEffects: loopback-only forbids receiving external mail
        (lib.mkIf (isActive "R74" "intermediary" "base" [ ] && hasMta) {
          services.postfix = lib.mkIf config.services.postfix.enable {
            settings.main = {
              inet_interfaces = "loopback-only";
              mydestination = "$myhostname, localhost";
              smtpd_relay_restrictions = "reject_unauth_destination";

              # Outbound TLS mandatory
              smtp_tls_security_level = "encrypt";
              smtp_tls_loglevel = "1";
            };
          };

          # OpenSMTPD is intentionally not configured here: Postfix is the DNF
          # default MTA. The hasMta guard already covers opensmtpd presence;
          # the equivalent loopback-only hardening would be added when/if a
          # host opts into OpenSMTPD.
        })

        # R75 — Mail aliases (intermediary, base)
        # sideEffects: none if the outbound SMTP gateway is trustworthy
        (lib.mkIf (isActive "R75" "intermediary" "base" [ ] && hasMta && adminMail != "") {

          # Route root and every system account toward adminMailbox. `root` is
          # set explicitly (it is the most important alias) and filtered out of
          # the generated list to avoid a duplicate newaliases entry.
          services.postfix.extraAliases = lib.mkIf config.services.postfix.enable (
            lib.concatStringsSep "\n" (
              [ "root: ${adminMail}" ]
              ++ lib.mapAttrsToList (
                name: user:
                lib.optionalString (
                  name != "root" && (user.isSystemUser or false || (user.uid != null && user.uid < 1000))
                ) "${name}: ${adminMail}"
              ) config.users.users
            )
          );
        })
      ]
    ))
  ];
}
