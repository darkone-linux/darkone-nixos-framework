# Messagerie locale (R74–R75).
#
# Couvre le MTA local durci en loopback-only (R74) et les alias de messagerie
# vers l'adresse de l'administrateur (R75). Ces règles ne s'appliquent que si
# un service MTA est actif (Postfix ou OpenSMTPD).
#
# :::caution[Activation]
# L'option `enable` suit `darkone.system.security.enable` par défaut.
# Les règles (Rxx/Cxx) s'activent selon le niveau, la catégorie et les
# excludes définis dans `darkone.system.security` (via `isActive`).
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
    darkone.security.mta.enable = lib.mkEnableOption "Active la sécurisation MTA ANSSI (R74–R75).";
  };

  config = lib.mkMerge [
    { darkone.security.mta.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R74 — Messagerie locale durcie (intermediary, base)
        # Condition : MTA actif
        # sideEffects: loopback-only interdit la réception de mails externes
        (lib.mkIf (isActive "R74" "intermediary" "base" [ ] && hasMta) {
          services.postfix = lib.mkIf config.services.postfix.enable {
            config = {
              inet_interfaces = "loopback-only";
              mydestination = "$myhostname, localhost";
              smtpd_relay_restrictions = "reject_unauth_destination";

              # TLS sortant obligatoire
              smtp_tls_security_level = "encrypt";
              smtp_tls_loglevel = "1";
            };
          };
          # TODO: config équivalente pour OpenSMTPD
        })

        # R75 — Alias de messagerie (intermediary, base)
        # sideEffects: nul si la passerelle SMTP sortante est fiable
        (lib.mkIf (isActive "R75" "intermediary" "base" [ ] && hasMta && adminMail != "") {

          # Générer les alias pour tous les comptes système vers adminMailbox
          services.postfix.extraAliases = lib.mkIf config.services.postfix.enable (
            lib.concatStringsSep "\n" (
              lib.mapAttrsToList (
                name: user:
                lib.optionalString (user.isSystemUser or false || (user.uid or 1000) < 1000) "${name}: ${adminMail}"
              ) config.users.users
            )
          );

          # TODO: alias pour root
        })
      ]
    ))
  ];
}
