# Changelog

All notable changes to the Darkone NixOS Framework are documented here.  
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Versioning: [SemVer](https://semver.org/). While in `0.x`, **MINOR carries the
breaking changes** — `etc/config.yaml` schema, `darkone.*` options and their
observable defaults, `lib.mkConfigurations`, public `just` recipes, the expected
`usr/` layout. `1.0.0` marks the public launch.

## [Unreleased]

## [0.1.0] - 2026-09-09

First versioned release. The framework and its ecosystem existed before this
tag; what is new is the contract — a version consumers can pin, a changelog,
and companion releases known to work together. The entry below inventories the
framework as it stands, not the commits that built it.

### Added

- **Declarative core**: `etc/config.yaml` as the single source of truth;
  the `dnf-generator` Rust crate renders `var/generated/{hosts,users,network}.nix`;
  host templates expand from numbered ranges and keyed lists.
- **Profiles**: host profiles (`minimal`, `server`, `desktop`, `laptop`,
  `gateway`, `hcs`, `vm`, `portable`, `umi`) and eleven inheriting user profiles
  (`minimal` → `normal` → `advanced` → `admin` → `nix-admin`, plus `student`,
  `teenager`, `gamer`, `child`, `baby`, `umi`); per-host feature layers.
- **Module system**: `darkone.{system,admin,console,graphic,service,security,user,mixin,home}.*`
  namespaces, with `modules/default.nix` imports generated from the tree.
- **Home Manager**: twelve bundle modules (advanced, ai, audio, education, games,
  gnome, imagery, mime, music, office, umi, video); streamlined GNOME desktop.
- **Services**: around forty ready-to-run daemons behind Caddy — Nextcloud,
  Forgejo, Immich, Vaultwarden, Matrix/Element, Jitsi Meet, Mattermost, Jellyfin,
  Mealie, Outline, LaSuite Docs, Searx, Homepage, Home Assistant, Geneweb,
  Open WebUI + Ollama, Garage/MinIO, nix-cache (Harmonia).
- **Single sign-on**: Kanidm as OIDC provider for fifteen-plus services,
  `oauth2-proxy` fronting those without native OIDC.
- **Networking**: `/16` zones with a gateway each, zero-conf dnsmasq DNS/DHCP,
  nftables firewalling, AdGuard Home, full-mesh headscale/tailscale, roaming
  DHCP reservations across zones.
- **Deployment**: automated install with nixos-anywhere, disko and colmena —
  `just full-install`, `just build-iso`, `just apply`; fleet-wide binary cache.
- **Security**: sops-nix secrets on age keys, ANSSI hardening tiers, LUKS with
  initrd unlock, kernel/systemd/PAM hardening, fail2ban, hardened SSH, YubiKey 2FA.
- **Supervision and backup**: Prometheus, Grafana, Loki and Alertmanager with
  Matrix alerting; Restic backups on a 3-2-1 strategy.
- **Tooling**: a hundred-plus `just` recipes (`clean`, `generate`, `check`,
  `apply`, `enter`, `luks`…), a dev shell, deadnix/statix linting, formatting,
  GitHub Actions CI.
- **Tests**: three tiers — nix-unit unit tests, auto-discovered VM scenarios,
  install tests.
- **Documentation**: Astro/Starlight site with user, admin and developer guides,
  French and English, module reference generated from the code.
- **Consumer surface**: `lib.mkConfigurations`, the `usr/` overlay, and the
  `dnf-boilerplate` and `dnf-example` starting points.
- **Release contract**: `VERSION`, SemVer tags, `just bump` / `just release`,
  generated changelog, `/etc/dnf-release` and a `dnf-<version>` boot label on
  every deployed host, tag guards in CI.

### Companion releases

| Project | Version |
|---|---|
| [dnf-generator](https://github.com/darkone-linux/dnf-generator) | `v0.1.0` |
| [dnf-doc](https://github.com/darkone-linux/dnf-doc) | `0.1.x` |
| [dnf-boilerplate](https://github.com/darkone-linux/dnf-boilerplate) | `v0.1.0` |
| [dnf-example](https://github.com/darkone-linux/dnf-example) | `v0.1.0` |

[Unreleased]: https://github.com/darkone-linux/darkone-nixos-framework/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/darkone-linux/darkone-nixos-framework/releases/tag/v0.1.0
