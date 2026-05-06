# PAM — Authentification et stockage des mots de passe (R67–R68).
#
# Couvre les authentifications PAM distantes sécurisées (R67 : SSSD, Kerberos,
# pam_faillock) et le stockage chiffré des mots de passe (R68 : yescrypt).
#
# :::caution[Activation]
# L'option `enable` suit `darkone.system.security.enable` par défaut.
# Les règles (Rxx/Cxx) s'activent selon le niveau, la catégorie et les
# excludes définis dans `darkone.system.security` (via `isActive`).
# :::
#
# :::note[Compléments]
# pam_faillock (anti brute-force) est configuré ici pour R67 et dans
# complement.nix (C10). La politique de complexité (R31) est dans users.nix.
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
  cfg = config.darkone.security.pam;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });
in
{
  options = {
    darkone.security.pam.enable = lib.mkEnableOption "Active le module PAM ANSSI — authentification et mots de passe (R67–R68).";
  };

  config = lib.mkMerge [
    { darkone.security.pam.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R67 — Authentifications PAM distantes sécurisées (intermediary, base)
        # sideEffects: SSSD requiert un service supplémentaire et un cache local
        (lib.mkIf (isActive "R67" "intermediary" "base" [ ]) {

          # pam_faillock : verrouillage anti brute-force
          # deny=3 : 3 tentatives max, unlock_time=900 : 15 min de verrouillage
          security.pam.services.login.rules.auth.faillock = {
            control = "required";
            modulePath = "${pkgs.pam}/lib/security/pam_faillock.so";
            settings = {
              preauth = true;
              deny = 3;
              unlock_time = 900;
              even_deny_root = false; # Ne pas bloquer root (risque de lock-out)
            };
          };

          # Assertion : pam_ldap doit utiliser TLS si présent
          # TODO: vérifier la config nslcd/sssd si services.sssd.enable ou services.nslcd.enable
        })

        # R68 — Stockage chiffré des mots de passe (minimal, base)
        # sideEffects: incompatible avec les systèmes sans support yescrypt (noyaux < 5.14)
        (lib.mkIf (isActive "R68" "minimal" "base" [ ]) {
          security.pam.services.passwd.rules.password.unix = {
            control = "sufficient";
            modulePath = "${pkgs.pam}/lib/security/pam_unix.so";
            settings = {
              obscure = true;
              yescrypt = true;
              rounds = 11;
            };
          };

          # login.defs : forcer yescrypt
          environment.etc."login.defs".text = lib.mkAfter ''
            ENCRYPT_METHOD YESCRYPT
            YESCRYPT_COST_FACTOR 11
          '';
        })
      ]
    ))
  ];
}
