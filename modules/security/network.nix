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
# :::caution[R79 — Every jail needs a filter]
# fail2ban runs on the systemd backend here: a jail needs both a `filter.d`
# definition and a `journalmatch`, or it aborts the whole daemon at startup —
# losing the working `sshd` jail. `exposedServices` is therefore asserted
# against `filters`; caddy, matrix and idm still need theirs written.
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

  # Filters fail2ban ships AND that carry their own journalmatch — the only
  # ones usable as-is on the systemd backend. Anything else goes to `filters`.
  stockFilters = [ "sshd" ];
  knownFilters = cfg.filters;
  unknownExposed = lib.subtractLists (stockFilters ++ lib.attrNames knownFilters) cfg.exposedServices;
in
{
  options = {
    darkone.security.network.enable = lib.mkEnableOption "Enable ANSSI network hardening (R78–R80).";

    darkone.security.network.exposedServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "sshd"
        "vaultwarden"
      ];
      description = ''
        Public services to jail with fail2ban (R79). Each entry MUST resolve to
        a filter — one shipped by fail2ban, or one declared in `filters` — or
        the assertion refuses the build.
      '';
    };

    darkone.security.network.filters = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            journalmatch = lib.mkOption {
              type = lib.types.str;
              example = "_SYSTEMD_UNIT=forgejo.service";
              description = "Journal match for the jail (fail2ban runs on the systemd backend).";
            };
            failregex = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = ''
                Failure pattern, written to `filter.d/<name>.conf`. Empty when
                fail2ban already ships the filter and only the match is missing.
              '';
            };
          };
        }
      );
      default = {

        # Ships a filter but no journalmatch, so the stock file alone yields a
        # jail that watches nothing.
        vaultwarden.journalmatch = "_SYSTEMD_UNIT=vaultwarden.service";
      };
      description = ''
        Filters usable in `exposedServices`, on top of those fail2ban ships.
        Caddy, Synapse and Kanidm need theirs written against real journal
        output — declare them here once the patterns are confirmed.
      '';
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

          # A jail whose filter or journalmatch is missing aborts fail2ban at
          # startup — taking the working sshd jail down with it. Refuse at
          # eval instead, naming the service.
          assertions = [
            {
              assertion = unknownExposed == [ ];
              message =
                "R79: no fail2ban filter for "
                + lib.concatStringsSep ", " unknownExposed
                + ". Declare it in darkone.security.network.filters "
                + "(known: "
                + lib.concatStringsSep ", " (lib.attrNames knownFilters)
                + ").";
            }
          ];

          # Custom filter definitions, dropped next to the stock filter.d ones.
          environment.etc = lib.mapAttrs' (
            name: f:
            lib.nameValuePair "fail2ban/filter.d/${name}.conf" {
              text = ''
                [Definition]
                failregex = ${f.failregex}
                ignoreregex =
              '';
            }
          ) (lib.filterAttrs (name: f: f.failregex != "" && lib.elem name cfg.exposedServices) cfg.filters);

          services.fail2ban = lib.mkIf (cfg.exposedServices != [ ]) {
            enable = true;
            jails = lib.genAttrs cfg.exposedServices (svc: {
              settings = {
                enabled = true;
                filter = svc;
                maxretry = 5;
                findtime = 600;
                bantime = 3600;
              }

              # `backend = systemd` is the NixOS default: a jail without a
              # journal match watches nothing and fails.
              // lib.optionalAttrs ((knownFilters.${svc} or null) != null) {
                inherit (knownFilters.${svc}) journalmatch;
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

          # Caddy has no global header directive (unlike nginx commonHttpConfig),
          # so expose the ANSSI headers as an importable snippet. DNF Caddy
          # vhosts add `import dnf-security-headers;` to opt in. Reuses the
          # shared dnfLib helper for a single source of truth.
          services.caddy = lib.mkIf (config.services.caddy.enable && cfg.httpsHeaders) {
            extraConfig = ''
              (dnf-security-headers) {
                ${dnfLib.mkCaddySecurityHeaders {
                  extraHeaders = ''
                    X-Content-Type-Options "nosniff"
                    X-Frame-Options "DENY"
                    Content-Security-Policy "default-src 'self'"
                    Referrer-Policy "no-referrer"
                  '';
                }}
              }
            '';
          };
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
                ${pkgs.iproute2}/bin/ss -lntp | ${pkgs.gawk}/bin/awk 'NR>1 && $4 ~ /^(0\.0\.0\.0|\*|\[::\]):/' | while read -r line; do
                  port=$(echo "$line" | ${pkgs.gawk}/bin/awk '{print $4}' | ${pkgs.gawk}/bin/awk -F: '{print $NF}')
                  proc=$(echo "$line" | ${pkgs.gawk}/bin/awk '{print $NF}')
                  found=0
                  for svc in $ALLOWED; do echo "$proc" | ${pkgs.gnugrep}/bin/grep -q "$svc" && found=1; done
                  [ $found -eq 0 ] && \
                    echo "WARNING: undeclared listener on 0.0.0.0:$port ($proc)" | \
                    ${pkgs.util-linux}/bin/logger -t anssi-r80 -p security.warning
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
