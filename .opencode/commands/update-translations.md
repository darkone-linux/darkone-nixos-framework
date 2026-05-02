---
description: Traduit la documentation fr <-> en
agent: build
model: opencode/minimax-m2.5-free
---

Traduit les fichiers de documentation demandés.

IMPORTANT : Dans les listes suivantes, ne traduit QUE le ou les fichiers dont les noms contiennent le ou les mots clés "$ARGUMENTS" ! 

A traduire du français à l'anglais :

- doc/src/content/docs/fr/doc/admin-guide.mdx -> doc/src/content/docs/en/doc/admin-guide.mdx
- doc/src/content/docs/fr/doc/how-to.mdx -> doc/src/content/docs/en/doc/how-to.mdx
- doc/src/content/docs/fr/doc/user-guide.mdx -> doc/src/content/docs/en/doc/user-guide.mdx
- doc/src/content/docs/fr/doc/specifications.mdx -> doc/src/content/docs/en/doc/specifications.mdx

A traduire de l'anglais au français :

- doc/src/content/docs/en/ref/modules.mdx -> doc/src/content/docs/fr/ref/modules.mdx

---

Règles importantes :

- Copie l'entête et ne traduit que le titre (title:) et la description (description:) s'ils existent.
- Copie tel quel le ou les imports commençant par le mot clé "import".
- Traduit les titres et les phrases.
- Ne traduit jamais le code, les noms de variables, de types, de dossiers et fichiers, les urls de liens, les noms de commandes, les icônes et émojis, qui doivent être copiés tels quels.
- Ne copie pas ce qui est en commentaire (entre {/* et */}).
- S'il existe des données en commentaire (entre {/* et */}), les laisser tel quel, ne pas les supprimer.
- Ces fichiers sont au format mdx pour starlight, ils doivent rester compatibles avec ce format.
- Les liens internes doivent être maintenus.
- Les caractères html tels que "&lt;" doivent être copiés tel quel.
