# Services réseau — cloisonnement et supervision (R78–R80). (wip)
#
# Couvre le cloisonnement des services réseau (R78 : catégorie server),
# le durcissement et la surveillance des services exposés (R79 : fail2ban,
# headers HTTP, TLS ANSSI) et la réduction de la surface réseau (R80).
#
# :::caution[Activation]
# L'option `enable` suit `darkone.system.security.enable` par défaut.
# Les règles (Rxx/Cxx) s'activent selon le niveau, la catégorie et les
# excludes définis dans `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R79 — CSP stricte]
# `Content-Security-Policy: default-src 'self'` casse les outils sans nonces
# (dashboards avec CDN, widgets tiers). HSTS preload est irréversible — ne
# poser qu'en domaine pleinement maîtrisé.
# :::
#
# :::caution[R80 — Filtrage des listeners]
# Certains services (KDE Connect, mDNS) écoutent par défaut sur toutes les
# interfaces. Les déclarer dans `network.publicListeners` ou les reconfigurer.
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
  cfg = config.darkone.security.network;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });
in
{
  options = {
    darkone.security.network.enable = lib.mkEnableOption "Active la sécurisation réseau ANSSI (R78–R80).";

    darkone.security.network.exposedServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "nginx"
        "gitea"
      ];
      description = "Services publics pour lesquels fail2ban et la supervision seront activés (R79).";
    };

    darkone.security.network.publicListeners = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Services autorisés à écouter sur 0.0.0.0 / :: (R80).";
    };

    darkone.security.network.httpsHeaders = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Ajoute les headers de sécurité HTTP ANSSI dans Nginx/Caddy (R79).";
    };

    darkone.security.network.tlsCiphers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "ECDHE-ECDSA-AES256-GCM-SHA384"
        "ECDHE-RSA-AES256-GCM-SHA384"
        "ECDHE-ECDSA-CHACHA20-POLY1305"
        "ECDHE-RSA-CHACHA20-POLY1305"
      ];
      description = "Suite de chiffrement TLS ANSSI pour Nginx (R79).";
    };
  };

  config = lib.mkMerge [
    { darkone.security.network.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R78 — Cloisonner les services réseau (reinforced, server)
        # sideEffects: effort de packaging non négligeable pour les containers
        (lib.mkIf (isActive "R78" "reinforced" "server" [ ]) {

          # PrivateNetwork=yes + IPAddressAllow/Deny via mkHardenedServiceConfig (cf. R63)
          # La politique nftables deny-by-default est dans complement.nix (C4)
          # TODO: appliquer IPAddressDeny=any + IPAddressAllow aux services réseau isolés
        })

        # R79 — Durcir et surveiller les services exposés (intermediary, server)
        # sideEffects: CSP stricte casse les outils sans nonces, HSTS preload irréversible
        (lib.mkIf (isActive "R79" "intermediary" "server" [ ]) {

          # fail2ban pour les services exposés déclarés
          services.fail2ban = lib.mkIf (cfg.exposedServices != [ ]) {
            enable = true;
            jails = lib.genAttrs cfg.exposedServices (svc: {
              settings = {
                enabled = true;
                filter = svc;
                maxretry = 5;
                findtime = 600;
                bantime = 3600;
              };
            });
          };

          # Headers de sécurité HTTP ANSSI dans Nginx
          services.nginx = lib.mkIf (config.services.nginx.enable && cfg.httpsHeaders) {
            commonHttpConfig = ''
              add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
              add_header X-Content-Type-Options "nosniff" always;
              add_header X-Frame-Options "DENY" always;
              add_header Content-Security-Policy "default-src 'self'" always;
              add_header Referrer-Policy "no-referrer" always;
              ssl_protocols TLSv1.3 TLSv1.2;
              ssl_ciphers "${lib.concatStringsSep ":" cfg.tlsCiphers}";
              ssl_prefer_server_ciphers on;
            '';
          };

          # TODO: config équivalente pour Caddy (déjà en partie géré par services.nix)
        })

        # R80 — Surface réseau réduite (minimal, base)
        # sideEffects: certains services (mDNS, KDE Connect) écoutent sur toutes interfaces
        (lib.mkIf (isActive "R80" "minimal" "base" [ ]) {

          # Timer de détection des listeners non déclarés sur 0.0.0.0/::
          systemd.services.anssi-listeners-check = {
            description = "ANSSI R80 : vérification des listeners réseau";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = pkgs.writeShellScript "anssi-listeners-check" ''
                ALLOWED="${lib.escapeShellArgs cfg.publicListeners}"
                ss -lntp | awk 'NR>1 && $4 ~ /^(0\.0\.0\.0|\*|\[::\]):/' | while read -r line; do
                  port=$(echo "$line" | awk '{print $4}' | awk -F: '{print $NF}')
                  proc=$(echo "$line" | awk '{print $NF}')
                  found=0
                  for svc in $ALLOWED; do echo "$proc" | grep -q "$svc" && found=1; done
                  [ $found -eq 0 ] && \
                    echo "WARNING: listener non déclaré sur 0.0.0.0:$port ($proc)" | \
                    logger -t anssi-r80 -p security.warning
                done
              '';
            };
          };
          systemd.timers.anssi-listeners-check = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = "daily";
              Persistent = true;
            };
          };
        })
      ]
    ))
  ];
}
