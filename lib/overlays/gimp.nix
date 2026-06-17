# Overlay : reconstruit `pkgs.gimp` sans `__structuredAttrs`.
#
# :::caution[Pourquoi]
# Le `__structuredAttrs = true` hérité d'amont casse le build de `gimp`
# (variables d'environnement / hook attendant l'ancien format d'attributs).
# On force `__structuredAttrs = false` pour retomber sur le comportement qui
# construit correctement le paquet.
# :::
#
# :::tip[Cleanup]
# À supprimer dès qu'amont rend `gimp` compatible `__structuredAttrs`.
# :::

_final: prev: {

  gimp = prev.gimp.overrideAttrs (_: {
    __structuredAttrs = false;
  });
}
