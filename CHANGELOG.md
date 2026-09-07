# Changelog

All notable changes to the Darkone NixOS Framework are documented here.  
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Versioning: [SemVer](https://semver.org/). While in `0.x`, **MINOR carries the
breaking changes** — `etc/config.yaml` schema, `darkone.*` options and their
observable defaults, `lib.mkConfigurations`, public `just` recipes, the expected
`usr/` layout. `1.0.0` marks the public launch.

## [Unreleased]

## [0.1.0] - 2026-09-07

First versioned release. The framework and its ecosystem existed before this
tag; what is new is the contract — a version consumers can pin, a changelog,
and companion releases known to work together.

### Added

- Versioning policy: `VERSION`, SemVer tags, `just bump` / `just release`,
  generated changelog, tag guards in CI.
- `/etc/dnf-release` and a `dnf-<version>` boot label on every deployed host.

### Companion releases

| Project | Version |
|---|---|
| [dnf-generator](https://github.com/darkone-linux/dnf-generator) | pinned in `flake.lock` |
| [dnf-doc](https://github.com/darkone-linux/dnf-doc) | `0.1.x` |
| [dnf-boilerplate](https://github.com/darkone-linux/dnf-boilerplate) | `v0.1.0` |
| [dnf-example](https://github.com/darkone-linux/dnf-example) | `v0.1.0` |

### Scope at this release

Multi-host, multi-user NixOS framework for self-hosted networks: host and user
profiles, automated install (nixos-anywhere, disko, colmena), zone networking
(dnsmasq, nftables, headscale/tailscale), SSO with Kanidm, service modules
behind Caddy, sops-nix secrets, ANSSI hardening tiers, Prometheus/Alertmanager
supervision with Matrix alerting, Restic backups, and a three-tier test suite
(nix-unit, VM scenarios, install tests).

[Unreleased]: https://github.com/darkone-linux/darkone-nixos-framework/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/darkone-linux/darkone-nixos-framework/releases/tag/v0.1.0
