# Durcissement des services systemd (R62–R66). (wip)
#
# Couvre la désactivation des services inutiles (R62), la réduction des
# fonctionnalités via les options de sécurité systemd (R63), la restriction
# des privilèges (R64), le cloisonnement (R65) et le durcissement des
# composants de conteneurisation (R66).
#
# :::caution[Activation]
# L'option `enable` suit `darkone.system.security.enable` par défaut.
# Les règles (Rxx/Cxx) s'activent selon le niveau, la catégorie et les
# excludes définis dans `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R63 — MemoryDenyWriteExecute]
# Casse les runtimes JIT (Java, V8, .NET, LuaJIT, Wasm). Utiliser le tag
# `needs-jit` dans `excludes` ou exclure le service individuellement.
# :::
#
# :::caution[R66 — userns-remap Docker]
# Casse les bind-mounts d'hôte vers conteneur (décalage UID). Migration des
# volumes existants nécessaire avant activation.
# :::

{
  lib,
  dnfLib,
  config,
  ...
}:
let
  mainSecurityCfg = config.darkone.system.security;
  cfg = config.darkone.security.services;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });

  # Helper : produit les options systemd de durcissement de service (R63, R65)
  # À appliquer via `systemd.services.<name>.serviceConfig`

  # Liste des services à désactiver en catégorie server (R62)
  serverDisabledServices = [
    "cups"
    "avahi-daemon"
    "bluetooth"
    "ModemManager"
    "wpa_supplicant"
    "accounts-daemon"
    "geoclue"
  ];

  # Services toujours désactivés (protocoles obsolètes)
  alwaysDisabledServices = [
    "telnet"
    "rsh"
    "rlogin"
    "tftp"
    "talk"
  ];
in
{
  options = {
    darkone.security.services.enable = lib.mkEnableOption "Active le durcissement des services systemd ANSSI (R62–R66).";

    darkone.security.services.rootServicesAllowed = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Services systemd autorisés à tourner en root sans CapabilityBoundingSet (R64).";
    };
  };

  # Exposer mkHardenedServiceConfig pour les autres modules DNF
  # DÉCISION ARCHITECTURALE : pour partager ce helper avec les modules de service DNF,
  # on pourrait l'ajouter à dnfLib. Pour l'instant, il reste local à security.
  # TODO: migrer vers dnfLib.mkHardenedServiceConfig si adoption large

  config = lib.mkMerge [
    { darkone.security.services.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R62 — Désactiver les services non nécessaires (minimal, base)
        # sideEffects: couper avahi casse découverte imprimantes, bluetooth casse claviers BT
        (lib.mkIf (isActive "R62" "minimal" "base" [ ]) {
          systemd.services = lib.mkMerge [

            # Services toujours désactivés (protocoles obsolètes)
            (lib.genAttrs alwaysDisabledServices (_: {
              enable = false;
            }))

            # Services désactivés en mode server uniquement
            (lib.optionalAttrs (mainSecurityCfg.category == "server") (
              lib.genAttrs serverDisabledServices (_: {
                enable = false;
              })
            ))
          ];
        })

        # R63 — Réduire les fonctionnalités des services (intermediary, base)
        # sideEffects: MemoryDenyWriteExecute casse JIT (compilation à la volée), ProtectSystem=strict impose ReadWritePaths
        (lib.mkIf (isActive "R63" "intermediary" "base" [ ]) {

          # TODO: appliquer mkHardenedServiceConfig aux services DNF enregistrés
          # via darkone.system.services.service.<name> (intégration services.nix)
          # Pour l'instant : les services individuels appliquent le helper manuellement.
          # Exemple :
          # systemd.services.monservice.serviceConfig = mkHardenedServiceConfig { };
        })

        # R64 — Privilèges des services (reinforced, base)
        # sideEffects: audit lourd sur les services hérités
        (lib.mkIf (isActive "R64" "reinforced" "base" [ ]) {
          assertions = [
            {
              assertion = lib.all (
                name:
                let
                  svc = config.systemd.services.${name};
                  user = svc.serviceConfig.User or "";
                  caps = svc.serviceConfig.CapabilityBoundingSet or null;
                in
                user != "root" || caps != null || lib.elem name cfg.rootServicesAllowed
              ) (lib.attrNames config.systemd.services);
              message =
                "R64: Tout service root doit déclarer CapabilityBoundingSet ou être "
                + "listé dans darkone.security.services.rootServicesAllowed.";
            }
          ];
        })

        # R65 — Cloisonner les services (reinforced, base)
        # sideEffects: PrivateNetwork=yes interdit l'IPC réseau (inadapté aux daemons réseau)
        (lib.mkIf (isActive "R65" "reinforced" "base" [ ]) {

          # TODO: appliquer PrivateNetwork=yes et PrivateUsers=yes aux services
          # qui n'ont pas besoin du réseau (via une option par service DNF)
        })

        # R66 — Durcir les composants de cloisonnement (high, base)
        # sideEffects: userns-remap Docker casse les bind-mounts, migration volumes nécessaire
        (lib.mkIf (isActive "R66" "high" "base" [ ]) {

          # Docker
          virtualisation.docker.daemon.settings = lib.mkIf config.virtualisation.docker.enable {
            "userns-remap" = "default";
            "no-new-privileges" = true;
            "live-restore" = true;
            icc = false;
            "userland-proxy" = false;
          };

          # Podman
          virtualisation.podman = lib.mkIf config.virtualisation.podman.enable { dockerCompat = false; };
        })
      ]
    ))
  ];
}
