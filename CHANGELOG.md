# Changelog

All notable changes to the Darkone NixOS Framework are documented here.  
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Versioning: [SemVer](https://semver.org/). While in `0.x`, **MINOR carries the
breaking changes** — `etc/config.yaml` schema, `darkone.*` options and their
observable defaults, `lib.mkConfigurations`, public `just` recipes, the expected
`usr/` layout. `1.0.0` marks the public launch.

## [Unreleased]

## [0.3.0] - 2026-09-24

### ⚠ Breaking

- **machines**: Split usr/machines by provenance

### Added

- **install**: Detect wired NIC drivers into detected-hardware.nix
- **home**: Delta as git pager, difftastic on demand via aliases
- **gnome**: Hide qt/manual icons, papers as pdf viewer, no donation nag
- **gnome**: Hide extensions icon for non-technical profiles

### Fixed

- **release**: Evaluate template hosts with stubbed hardware
- **smtp**: Network.smtp optional for mail-sending services
- **install**: Commit messages update (just installs)
- **tools**: HM advanced refactorings + new tools for AIs
- **ai**: Merge antigravity settings into a writable file
- **gnome**: Hide extensions icon via XDG_DATA_HOME, shadowed by gnome-shell

### Dependencies

- dnf-generator v0.2.0

## [0.2.2] - 2026-09-23

### Added

- **release**: Push the workspace root at the end of the train

### Fixed

- **release**: Skip flake check on templates without var/generated
- **ci**: Publish to FlakeHub without output paths

## [0.2.1] - 2026-09-23

### Added

- **fleet-update**: Add AI context option
- **release**: Idempotent ordered release train

### Fixed

- **release**: Fetch without tags, verify last release tag
- **release**: One ls-remote per repo in the preflight

### Dependencies

- dnf-generator v0.1.1
- fleet-update v0.7.1

## [0.2.0] - 2026-09-22

### ⚠ Breaking

- **just**: Split recipes into common, dnf, project and codev bootstraps
- **tailscale**: Enroll nodes with single-use tagged keys

### Added

- **pkgs**: Dnf package tree for programs absent from nixpkgs
- **home**: Rename-simple in the advanced essentials
- **headscale**: Generate tailnet ACL policy from topology
- **headscale**: Load generated policy, checked at build time
- **headscale**: OIDC login through Kanidm for personal devices
- **tailscale**: Open WireGuard port on the coordination server
- **headscale**: Audit tailnet nodes, alert on drift
- **gc**: Just gc with period/count argument
- **vbox**: Attach local build-iso output to test VMs
- **git**: Git-cliff / git improvements
- **qemu**: Bridged LAN test VMs via vm-start.sh and darkone.graphic.qemu
- **pkgs**: Add fleet-update (unstable, interface mockup)
- **just**: Pkg-update honours updateScript extra args
- **flake**: Expose pkgs/ packages to consumer flakes
- **just**: Add fleet-update recipe
- **fleet-update**: Add darkone.admin.fleet-update module and timer
- **just**: Pkg-update accepts an explicit version
- **advanced**: New DnfDeveloper profile
- **fleet-update**: Sops in the unattended PATH for --send-report
- **alerts**: Send-msg, one message to a Matrix alert room
- **nix-cache**: Serve the global zone from the global harmonia
- **nextcloud**: Plugins list update
- **pim**: Added planify to gnome calendar/contacts option
- **fleet-update**: Optional AI tools on the unattended run PATH
- **ai**: New ai tools - codex, antigravity...

### Fixed

- **anssi**: R50 stripped x from /var/log/nginx, failing logrotate at boot
- **luks**: Restore the initrd key as root, not through the nix shell
- **just**: Name recipes that exist, pass _fail one argument, no fixed paths
- **configure**: Converge LUKS again now that the key restore works
- **just**: Readable --list summaries and English messages
- **just**: Restore workspace ownership when an install fails
- **luks**: Audit the running system against the colmena node
- **luks**: Guard timesyncd ordering on the unit being enabled
- **prometheus**: Distinct host label on PeerGatewayDown rules
- **matrix**: Start synapse after a ready MAS, drop reverse ordering
- **headscale**: Grant personal devices HTTPS on zone gateway LAN IPs
- **tailscale**: Reconcile SSH and exit-node prefs on running nodes
- **restic**: One alert per backup job, a failing one no longer masked
- **restic**: Watch freshness of hand-declared backup jobs too
- **restic**: Alert on never-successful jobs, drop stamps of removed jobs
- **vbox**: Set bridge adapter on test VM NICs
- **iso**: Print install IP and MAC on the console before the prompt
- **install**: Commit without autoDetach to avoid chown fail
- **services**: Pace exporter/outline restarts, drop pkgs.system alias
- **hive**: Align colmena and nixosConfigurations toplevels
- **opencode**: Pin to 1.18.20, 1.18.30 crashes every prompt
- **opencode**: Revert pinned package -> opencode stable
- **fleet-update**: Guard dnf-generator overlay for aarch64 eval
- **flake**: Bump sops-nix, drops removed buildGo125Module
- **admin**: Nix-eval-jobs built against the system nix
- **d2,opencode**: D2 pkgs stable, opencode unstable
- **headscale**: Wait for oidc issuer before start, not just kanidm unit order
- **opencode**: Pin package to 1.18.29, 1.18.30 crashes on every prompt
- **apply**: Apply-silenced needs sudo for dnf-maintenance
- **fleet-update**: Empty timer.extraArgs, --send-report exits 2
- **mpdris2**: Settings renamed
- **security**: Anssi-orphan-scan no longer blocks activation
- **alerts**: Render the report markdown as Matrix HTML
- **luks**: Ship virtio transports in initrd, audit NIC drivers

### Security

- **anssi**: Raise the gateways and ms-a2 to the intermediary tier
- **anssi**: R79 was posting its nginx headers where nginx drops them
- **anssi**: R28 cannot cross to its hardened /tmp through a switch
- **anssi**: R79 wrote TLS directives nginx already emits
- **anssi**: R8 allocator extras cost more than the wipe they replace
- **anssi**: The allocator extras carried 7 of the 34 seconds, not all of them

### Removed

- **just**: Drop duplicate variables, dead code and deprecated fix-zsh
- **tailscale**: Drop health metric while autopaused on a home LAN
- **advanced**: Drop duplicate openssl when admin+dnf-developer overlap

### Changed

- **just**: Compute the workspace context once
- **just**: One zone lookup shared by _target and _candidates
- **banner**: C11 ssh banner update
- **just-install**: Minor reviews

### Documentation

- **tailscale**: Correct MagicDNS note on gateway DNS flags
- **umi**: UMI -> Unified Multimodal Input + minor fixes

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

[Unreleased]: https://github.com/darkone-linux/darkone-nixos-framework/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/darkone-linux/darkone-nixos-framework/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/darkone-linux/darkone-nixos-framework/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/darkone-linux/darkone-nixos-framework/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/darkone-linux/darkone-nixos-framework/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/darkone-linux/darkone-nixos-framework/releases/tag/v0.1.0
