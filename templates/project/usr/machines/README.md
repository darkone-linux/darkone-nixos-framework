# `usr/machines/<hostname>/`

One directory per host, sorted by who writes each file. Seeded by
`just generate` for every host carrying a `disko:` block in `etc/config.yaml`,
completed by `just install` / `just configure`. Imported by the framework,
file by file: there is no `default.nix`.

- `configuration.nix` — **yours**, the only file to edit. Seeded once, never
  rewritten. Import your own extra files from here.
- `install/` — **frozen at install**, never edit:
  - `disko.nix` — disk layout: the `disko.profile` with the `disko.devices`
    of `etc/config.yaml`. Rewritten by `just generate` until the host is
    installed, frozen afterwards (the disk was formatted with it).
  - `state.nix` — `system.stateVersion`, written by `just install`. Keep it
    to reinstall the host with its data; delete it only to rebuild the host
    as a new machine.
- `hardware/` — **probed on the machine** by `just install`, `just copy-hw`,
  `just detect-hw`. Never edit.

Boot flags implied by the layout (software RAID, `neededForBoot`) are written
to `var/generated/hosts/<hostname>.nix` by `just generate`.

This directory stays empty until you declare a host with a `disko:` block.
