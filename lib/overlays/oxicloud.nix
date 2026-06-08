# Overlay : reconstruit `pkgs.oxicloud` pour une cible CPU portable.
#
# :::caution[Pourquoi]
# Le dépôt OxiCloud embarque un `.cargo/config.toml` avec
# `target-cpu=native`. Le binaire est donc compilé pour le CPU du *deployer*
# (colmena build avec `buildOnTarget = false`, puis copie de la closure sur
# chaque nœud). Sur un hôte au CPU plus ancien que le deployer, les
# instructions absentes (AVX-512, AVX2…) provoquent un `SIGILL` au démarrage.
# DNF construit une fois et distribue : le binaire DOIT être portable.
# :::
#
# :::tip[Cleanup]
# À supprimer si le paquet nixpkgs neutralise lui-même `target-cpu=native`
# (via `env.RUSTFLAGS` ou suppression du `.cargo/config.toml`). À remonter en
# amont : `target-cpu=native` casse le contrat de portabilité du cache binaire.
# :::

_final: prev: {

  oxicloud = prev.oxicloud.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''

      # Neutralise le `target-cpu=native` amont (binaire non portable entre nos
      # hôtes) : sans ce fichier, cargo retombe sur la baseline x86-64 générique.
      rm -f .cargo/config.toml .cargo/config
    '';
  });
}
