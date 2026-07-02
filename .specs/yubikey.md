# YubiKey — validation matérielle & phases suivantes

État : v1 livrée et testée **sans clé physique** (VM + eval). Ce document liste
ce qui doit être validé à l'arrivée des premières clés, puis les phases
suivantes prévues.

Livré (commits `feat(yubikey)`, `test(yubikey)`, `doc(yubikey)`) :

- `modules/system/yubikey.nix` : pam_u2f parc-wide (`sufficient`, origin fixe
  `pam://<domain>`, mapping `/etc/u2f_mappings`) + LUKS déclaratif (crypttab
  `fido2-device=auto`, service oneshot `yubikey-luks-enroll` qui synchronise
  keyslots + tokens `systemd-fido2` depuis sops, ledger `/var/lib/yubikey-luks`).
- `just yubikey <user> [main|backup] [enroll|revoke]` : enrollment unique sur
  le poste admin (~3 touches) → registre public `usr/secrets/yubikeys.json` +
  secrets sops (`yubikey/<user>/<clé>/luks-secret`, `luks-passphrase`) + lien
  de reset Kanidm.
- Doc : `doc/fr/doc/admin-guide/operate/yubikey.mdx`.

## 1. À l'arrivée des clés physiques (checklist)

Ordre prudent : PAM d'abord (réversible, sans risque), LUKS ensuite sur UN
host de test, le reste après.

### 1.1 Enrollment + PAM

- [ ] Clé branchée sur le poste admin : `just yubikey <login>`.
  - Vérifier : ligne `pam` + `credId` + `salt` dans `usr/secrets/yubikeys.json`,
    secrets sops créés, `luks-passphrase` demandée une seule fois.
  - Piège possible : accès hidraw — la recette passe par
    `sudo nix shell nixpkgs#pam_u2f nixpkgs#libfido2` (root), ça doit suffire.
- [ ] `git add usr/secrets/yubikeys.json` + commit + `just apply` sur un poste.
- [ ] Login graphique (GDM) et `sudo` : le prompt « touch the key » apparaît,
  un touch connecte ; **sans clé branchée, le mot de passe fonctionne comme
  avant** (nouserok + sufficient).
- [ ] Utilisateur sans clé enrollée : comportement strictement inchangé.

### 1.2 LUKS — LE point à valider (format cryptenroll répliqué)

Le service réplique ce qu'écrit `systemd-cryptenroll` : passphrase de keyslot
= **base64 du hmac-secret** (tel que sorti par `fido2-assert`, sans espace ni
newline) + token JSON `systemd-fido2` (rp `io.systemd.cryptsetup`, up=true,
uv/pin=false). Non testable sans matériel — à valider sur un host de test :

- [ ] `just apply <host-chiffré>` puis `journalctl -u yubikey-luks-enroll` :
  « enrolled <user>/<clé> on <dev> (slot N) », pas d'erreur luksAddKey
  (sinon : `luks-passphrase` sops ≠ passphrase réelle du host).
- [ ] `cryptsetup luksDump <dev>` : keyslot ajouté + token `systemd-fido2`,
  keyslot passphrase d'install toujours présent.
- [ ] Reboot clé branchée → touch → unlock. Reboot sans clé → fallback
  passphrase (timeout fido2 puis prompt).
- [ ] Si l'unlock échoue en initrd : vérifier que systemd-cryptsetup charge
  libfido2 (dlopen) dans l'initrd NixOS ; comparer octet à octet avec un
  enrollment `systemd-cryptenroll --fido2-device=auto` fait à la main sur le
  même volume (dump JSON des deux tokens).
- [ ] **Plan B documenté** si le format résiste : options crypttab officielles
  `fido2-cid=` + salt en keyfile (créées pour les credentials externes),
  limite : une seule clé par volume.
- [ ] Vérifier `nix` (uid 65000) n'a PAS de credential → les serveurs restent
  déverrouillables par les seuls users humains du host.

### 1.3 Kanidm / Vaultwarden / backup / revoke

- [ ] Lien de reset émis par `just yubikey` (ou `just enter hcs` + commande
  affichée) → cérémonie web : passkey utilisable sur tout le SSO.
- [ ] Vaultwarden : ajout WebAuthn dans le coffre web (2FA).
- [ ] Clé de secours : `just yubikey <login> backup` → les DEUX clés marchent
  (PAM + LUKS + passkey Kanidm séparée à enregistrer).
- [ ] Révocation : `just yubikey <login> main revoke` + apply → credential PAM
  retiré, keyslot LUKS supprimé (journal du service), ledger purgé.
  Retirer la passkey côté Kanidm/Vaultwarden à la main (web).

### 1.4 Fin de chantier

- [ ] Mettre à jour la doc avec les retours terrain (pièges réels, timings).
- [ ] `just tags` + `just translate` dans `doc/` (traduction EN).
- [ ] Généraliser au parc (`just apply`), enroller les autres membres.

## 2. Phases suivantes (dans l'ordre suggéré)

1. **SSH FIDO2 + signature git** — clé `ed25519-sk` (`ssh-keygen -t
   ed25519-sk`), pub committable dans `usr/secrets/` ; home module :
   `programs.git.signing.key` (le `signing.format = "ssh"` existe déjà dans
   `home/modules/advanced.nix`). Option : étendre `just yubikey` d'une étape
   ssh-keygen.
2. **sops admin conditionné à la clé** — `age-plugin-fido2-hmac` comme
   recipient additionnel dans `_regen-sops-yaml` (project.just). Les HOSTS
   gardent la clé infra (un déploiement ne peut pas exiger un touch) ; seul le
   déchiffrement admin devient conditionné à la clé.
3. **Mode « 2ᵉ facteur strict » par host** — option
   `darkone.system.yubikey.mode = "sufficient" | "required"` (pam_u2f
   `required` = mdp + touch) pour les hosts sensibles. Attention lockout :
   exiger ≥ 1 clé backup enrollée avant d'autoriser `required`.
4. **PIN FIDO2 pour LUKS** — `fido2-clientPin-required: true` dans le token +
   capture avec PIN dans la recette (2FA au boot). Aujourd'hui : touch seul.
5. **TOTP** — reste côté web uniquement (Kanidm/Vaultwarden, self-service,
   natif). Pas de TOTP PAM (KbdInteractiveAuthentication=false, UX).

## 3. Invariants à ne pas casser

- Mot de passe sops et passphrase LUKS d'install : JAMAIS supprimés (fallback).
- `origin` pam fixe : en changer = ré-enrollment général.
- Le service LUKS ne touche qu'aux credentials de son ledger (les enrollments
  manuels `systemd-cryptenroll` survivent) et ne bloque jamais boot/deploy.
- Registre `yubikeys.json` public par construction (credentials publics) ;
  tout ce qui est secret vit dans sops.
