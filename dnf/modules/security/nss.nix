# NSS — Bases utilisateur distantes (R69–R70). (wip)
#
# Règles applicables uniquement si un NSS externe est actif (SSSD, nslcd).
# Pour le moment, pas pertinent pour DNF, voir ce qu'on peut faire avec Kanidm + PAM.
#
# Couvre la sécurisation des bases distantes (R69 : TLS obligatoire) et la
# séparation des comptes système et annuaire (R70).
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
  cfg = config.darkone.security.nss;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });
  hasNss = config.services.sssd.enable or false || config.services.nslcd.enable or false;
in
{
  options = {
    darkone.security.nss.enable = lib.mkEnableOption "Active la sécurisation NSS ANSSI (R69–R70).";
  };

  config = lib.mkMerge [
    { darkone.security.nss.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R69 — Bases utilisateur distantes sécurisées (intermediary, base)
        # Condition : NSS actif (SSSD ou nslcd)
        # sideEffects: besoin d'une PKI fiable côté annuaire
        (lib.mkIf (isActive "R69" "intermediary" "base" [ ] && hasNss) {

          # SSSD avec TLS
          services.sssd = lib.mkIf config.services.sssd.enable {

            # TODO: configurer sssd.conf avec tls_reqcert=demand et tls_cacertfile
            # La config SSSD est gérée via services.sssd.config (texte brut)
          };

          # Interdire LDAP en clair (port 389 sans STARTTLS)
          assertions = [
            {
              assertion = true; # TODO: vérifier la config nslcd/sssd pour ssl=on
              message = "R69: LDAP doit utiliser TLS (ssl=on, tls_reqcert=demand).";
            }
          ];
        })

        # R70 — Comptes système ≠ comptes annuaire (intermediary, base)
        # sideEffects: migration nécessaire si l'annuaire est mal segmenté
        (lib.mkIf (isActive "R70" "intermediary" "base" [ ] && hasNss) {

          # TODO: assertion sur le DN de bind SSSD/nslcd (lecture seule, non admin)
          # Vérifier que services.sssd config ne contient pas un compte admin ldap
        })
      ]
    ))
  ];
}
