# dnf/modules/host/nav.nix
#
# Host profile (mixin) qui intègre pypilot-nix dans le Darkone NixOS Framework.
#
# Couture entre :
#   - pypilot-nix : services.navigation.*  (domaine maritime, HATs, Signal K…)
#   - DNF         : darkone.*              (users, DNS dnsmasq, firewall, proxy…)
#
# Le module N'IMPLÉMENTE RIEN du métier maritime : il importe le module de
# pypilot-nix et règle ses options à partir des facts DNF de l'hôte.
#
# Dépendances (specialArgs DNF) : pkgs, lib, config, inputs (pour pypilot-nix),
# host (hostname, profile, users, groups, arch), network, users.
{
  config,
  lib,
  inputs,
  host,
  ...
}:
let
  cfg = config.darkone.host.nav;
in
{
  #--------------------------------------------------------------------------
  # IMPORT du module métier de pypilot-nix (à exporter côté pypilot-nix,
  # cf. INTEGRATION.md → nixosModules.navigation)
  #--------------------------------------------------------------------------
  imports = [ inputs.pypilot-nix.nixosModules.navigation ];

  options.darkone.host.nav = {
    enable = lib.mkEnableOption "Profil hôte nav (navigation maritime DNF, basé pypilot-nix)";

    hardware = lib.mkOption {
      type = lib.types.enum [
        "pypilot-hat"
        "macarthur-hat"
        "none"
      ];
      default = "pypilot-hat";
      description = "HAT physique monté sur le Pi.";
    };

    # On expose le registre série de pypilot-nix tel quel : il vit
    # naturellement dans usr/machines/<bateau> (specifics matériels).
    serialDevices = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Passé tel quel à services.navigation.serialDevices.";
    };

    gps = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Passé tel quel à services.navigation.gps.";
    };

    # Le bateau est-il aussi le nœud réseau du LAN bateau (DNS/DHCP) ?
    # Cas par défaut : oui (réseau autonome embarqué).
    networkNode = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Active le profil DNF network-node (dnsmasq DNS/DHCP) sur ce Pi.";
    };

    # Domaine interne servi par dnsmasq sur le LAN bateau.
    domain = lib.mkOption {
      type = lib.types.str;
      default = "boat.lan";
      description = "Domaine DNS interne du réseau bateau.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [

      #------------------------------------------------------------------------
      # 1. NAVIGATION : on allume la stack pypilot et on mappe le matériel.
      #------------------------------------------------------------------------
      {
        services.navigation = {
          enable = true;
          hardware = cfg.hardware;
          serialDevices = cfg.serialDevices;
          gps = cfg.gps;

          # IMPORTANT : on NE laisse PAS pypilot ouvrir le firewall lui-même.
          # C'est nftables DNF qui ouvre les ports (cf. bloc firewall).
          signalk.openFirewall = false;
        };
      }

      #------------------------------------------------------------------------
      # 2. USERS : on supprime le défaut « skipper » codé en dur de pypilot,
      #    on laisse la gestion DNF (config.yaml -> var/generated/users.nix)
      #    créer les comptes. On garde juste un groupe pour l'accès série.
      #------------------------------------------------------------------------
      {
        # Le groupe qui possède /dev/pypilot_motor, /dev/gps0, dialout…
        users.groups.navigation = { };

        # Tout user DNF du host membre du groupe "navigation" (déclaré dans
        # config.yaml -> host.groups) obtient l'accès matériel. On évite ainsi
        # de hardcoder un login.
        users.users = lib.genAttrs host.users (_: {
          extraGroups = lib.mkAfter [
            "navigation"
            "dialout"
          ];
        });
      }

      #------------------------------------------------------------------------
      # 3. HORLOGE : UTC par défaut sur ces postes. Source de temps :
      #    NTP internet quand dispo, sinon GPS (gpsd+chrony) prend le relais.
      #    timesyncd off : chrony (fourni par services.navigation) gère tout.
      #------------------------------------------------------------------------
      {
        time.timeZone = lib.mkForce "UTC";
        services.timesyncd.enable = lib.mkForce false;

        # chrony est activé par services.navigation avec gpsd en source.
        # On s'assure ici que des serveurs NTP internet restent déclarés en
        # source PRIMAIRE (préférés tant qu'ils sont joignables), le GPS servant
        # de repli automatique quand internet tombe. Adapter aux serveurs voulus.
        services.chrony.servers = lib.mkDefault [
          "0.nixos.pool.ntp.org"
          "1.nixos.pool.ntp.org"
        ];
        # (le refclock GPS/PPS est injecté par le module navigation ; chrony
        #  bascule seul vers lui quand les serveurs deviennent injoignables.)
      }

      #------------------------------------------------------------------------
      # 4. FIREWALL : nftables DNF maître. On ouvre Signal K + NMEA0183 TCP
      #    via l'abstraction DNF si elle existe, sinon directement.
      #------------------------------------------------------------------------
      {
        # Adapter au nom réel de ton abstraction firewall DNF si tu en as une
        # (ex: darkone.network.firewall.allowedTCPPorts). Fallback générique :
        networking.firewall.allowedTCPPorts = [
          3000 # Signal K
          10110 # NMEA0183 over TCP
        ];
      }

      #------------------------------------------------------------------------
      # 5. NETWORK-NODE : le Pi sert le DNS/DHCP du LAN bateau (dnsmasq DNF).
      #    On réutilise le profil réseau DNF plutôt que la simple mDNS pypilot.
      #------------------------------------------------------------------------
      (lib.mkIf cfg.networkNode {
        # Active ton profil network-node DNF existant. Adapter au vrai nom
        # d'option (ex: darkone.host.network-node.enable).
        darkone.host.network-node.enable = lib.mkDefault true;

        # Domaine interne servi par dnsmasq.
        networking.domain = cfg.domain;

        # On garde la résolution .local pour OpenCPN/Signal K en complément.
        services.avahi = {
          enable = lib.mkDefault true;
          nssmdns4 = lib.mkDefault true;
          publish = {
            enable = lib.mkDefault true;
            addresses = lib.mkDefault true;
          };
        };
      })

      #------------------------------------------------------------------------
      # 6. REVERSE-PROXY + HOMEPAGE : exposer les services nav dans l'écosystème
      #    DNF (Caddy + homepage). TLS = ACME CENTRALISÉ : les certificats sont
      #    générés ailleurs et transférés sur la passerelle ; une connexion
      #    internet ponctuelle suffit à les renouveler. Pas de `tls internal`.
      #------------------------------------------------------------------------
      {
        # Passer par l'abstraction reverse-proxy DNF est préférable : elle pose
        # déjà les certs transférés. Si tu écris du Caddy brut, référence les
        # certs distribués par DNF (adapter le chemin à ta distribution sops/acme) :
        #
        #   tls /var/lib/dnf/certs/${cfg.domain}/fullchain.pem \
        #       /var/lib/dnf/certs/${cfg.domain}/key.pem
        #
        services.caddy.virtualHosts."signalk.${cfg.domain}".extraConfig = ''
          reverse_proxy 127.0.0.1:3000
        '';
        services.caddy.virtualHosts."pilot.${cfg.domain}".extraConfig = ''
          reverse_proxy 127.0.0.1:8080
        '';

        # Enregistrement homepage DNF (adapter au nom réel de l'option).
        # darkone.service.homepage.services.navigation = [
        #   { name = "Signal K"; href = "https://signalk.${cfg.domain}"; }
        #   { name = "Pypilot";  href = "https://pilot.${cfg.domain}"; }
        # ];
      }
    ]
  );
}
