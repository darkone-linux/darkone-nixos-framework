# Network services — isolation and supervision (R78–R80). (wip)
#
# Covers isolation of network services (R78: server category),
# hardening and monitoring of exposed services (R79: fail2ban,
# HTTP headers, ANSSI TLS) and reduction of the network surface (R80).
#
# :::caution[Activation]
# The `enable` option follows `darkone.system.security.enable` by default.
# Rules (Rxx/Cxx) are activated based on level, category, and excludes
# defined in `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R79 — Strict CSP]
# `Content-Security-Policy: default-src 'self'` breaks tools without nonces
# (dashboards with CDN, third-party widgets). HSTS preload is irreversible —
# only set on a fully controlled domain.
# :::
#
# :::caution[R80 — Listener filtering]
# Some services (KDE Connect, mDNS) listen by default on all interfaces.
# Declare them in `network.publicListeners` or reconfigure them.
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
    darkone.security.network.enable = lib.mkEnableOption "Enable ANSSI network hardening (R78–R80).";

    darkone.security.network.exposedServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "nginx"
        "gitea"
      ];
      description = "Public services for which fail2ban and supervision will be enabled (R79).";
    };

    darkone.security.network.publicListeners = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Services allowed to listen on 0.0.0.0 / :: (R80).";
    };

    darkone.security.network.httpsHeaders = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Adds ANSSI HTTP security headers in Nginx/Caddy (R79).";
    };

    darkone.security.network.tlsCiphers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "ECDHE-ECDSA-AES256-GCM-SHA384"
        "ECDHE-RSA-AES256-GCM-SHA384"
        "ECDHE-ECDSA-CHACHA20-POLY1305"
        "ECDHE-RSA-CHACHA20-POLY1305"
      ];
      description = "ANSSI TLS cipher suite for Nginx (R79).";
    };
  };

  config = lib.mkMerge [
    { darkone.security.network.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R78 — Isolate network services (reinforced, server)
        # sideEffects: significant packaging effort for containers
        (lib.mkIf (isActive "R78" "reinforced" "server" [ ]) {

          # PrivateNetwork=yes + IPAddressAllow/Deny via mkHardenedServiceConfig (cf. R63)
          # The nftables deny-by-default policy is in complement.nix (C4)
          # TODO: apply IPAddressDeny=any + IPAddressAllow to isolated network services
        })

        # R79 — Harden and monitor exposed services (intermediary, server)
        # sideEffects: strict CSP breaks tools without nonces, HSTS preload is irreversible
        (lib.mkIf (isActive "R79" "intermediary" "server" [ ]) {

          # fail2ban for declared exposed services
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

          # ANSSI HTTP security headers in Nginx
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

          # TODO: equivalent config for Caddy (already partially handled by services.nix)
        })

        # R80 — Reduced network surface (minimal, base)
        # sideEffects: some services (mDNS, KDE Connect) listen on all interfaces
        (lib.mkIf (isActive "R80" "minimal" "base" [ ]) {

          # Detection timer for undeclared listeners on 0.0.0.0/::
          systemd.services.anssi-listeners-check = {
            description = "ANSSI R80: check for network listeners";
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
                    echo "WARNING: undeclared listener on 0.0.0.0:$port ($proc)" | \
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
