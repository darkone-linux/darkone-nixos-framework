# `usr/home/profiles/<name>/`

Your own home-manager user profiles, referenced from
`etc/config.yaml:users.<login>.profile`. A profile declared here **shadows** a
framework profile of the same name (the generator looks up
`usr/home/profiles/<name>/` first, then `dnf/home/profiles/<name>/`).

A custom profile has two halves:

- `usr/home/profiles/<name>/default.nix` — the home-manager side (packages,
  dotfiles, program configuration);
- `usr/home/nixos/<name>.nix` — the NixOS side, merged into
  `users.users.<login>` (groups, shell, ssh keys, sudo). **Required**: it is
  imported unconditionally for every user of that profile.

Take `dnf/home/profiles/normal/` and `dnf/home/nixos/normal.nix` as a model
(`dnf/` is the framework symlink created by `nix run …#init`).

Built-in profiles you can use as-is: `nix-admin`, `admin`, `advanced`,
`normal`, `student`, `teenager`, `child`, `baby`, `gamer`, `minimal`.
