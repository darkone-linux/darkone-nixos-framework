# NSS — Remote user databases (R69–R70). (wip)
#
# Rules applicable only if an external NSS is active (SSSD, nslcd).
# Not currently relevant for DNF; see what can be done with Kanidm + PAM.
#
# Covers hardening of remote databases (R69: TLS mandatory) and
# separation of system and directory accounts (R70).
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
  cfg = config.darkone.security.nss;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });
  hasNss = config.services.sssd.enable or false || config.services.nslcd.enable or false;
in
{
  options = {
    darkone.security.nss.enable = lib.mkEnableOption "Enable ANSSI NSS hardening (R69–R70).";
  };

  config = lib.mkMerge [
    { darkone.security.nss.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R69 — Secure remote user databases (intermediary, base)
        # Condition: NSS active (SSSD or nslcd)
        # sideEffects: requires a trustworthy PKI on the directory side
        (lib.mkIf (isActive "R69" "intermediary" "base" [ ] && hasNss) {

          # SSSD with TLS
          services.sssd = lib.mkIf config.services.sssd.enable {

            # TODO: configure sssd.conf with tls_reqcert=demand and tls_cacertfile
            # SSSD config is managed via services.sssd.config (raw text)
          };

          # Forbid LDAP in cleartext (port 389 without STARTTLS)
          assertions = [
            {
              assertion = true; # TODO: verify the nslcd/sssd config for ssl=on
              message = "R69: LDAP must use TLS (ssl=on, tls_reqcert=demand).";
            }
          ];
        })

        # R70 — System accounts ≠ directory accounts (intermediary, base)
        # sideEffects: migration required if the directory is poorly segmented
        (lib.mkIf (isActive "R70" "intermediary" "base" [ ] && hasNss) {

          # TODO: assertion on the SSSD/nslcd bind DN (read-only, non-admin)
          # Verify that services.sssd config does not contain an admin ldap account
        })
      ]
    ))
  ];
}
