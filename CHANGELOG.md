# Changelog

All notable changes to the Darkone NixOS Framework are documented here.  
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Versioning: [SemVer](https://semver.org/). While in `0.x`, **MINOR carries the
breaking changes** — `etc/config.yaml` schema, `darkone.*` options and their
observable defaults, `lib.mkConfigurations`, public `just` recipes, the expected
`usr/` layout. `1.0.0` marks the public launch.

## [Unreleased]

## [0.6.0] - 2026-10-24

### ⚠ Breaking

- **secrets**: Drop default-password-hash and just passwd-default
- **space**: Space-bot merged into space-init, bot needs network Matrix
- **openclaw**: Gateway password secret for the host CLI, runtime by provider
- **openclaw**: Clone projects into shared projectsDir, coding agents

### Added

- **microvm**: Routed microVM guests, ai-space profile, isolated sops
- **space**: Just space-init, own sops file for isolated hosts
- **home**: Ghostty for every technical profile, no longer behind enableTools
- **home**: Admin profiles without imagery, music and Filezilla, one KeePass app
- **gnome**: Vim, btop and htop hidden from the app grid (hiddenApps)
- **home**: Local network folder for the nix-admin: doc, onboarding, sources
- **microvm**: Guest readiness over vsock, CID derived from the zone IP
- **microvm**: Guests reachable by ping and ssh from the fleet
- **space**: Kanidm group per AI space, proxy.spaceMembersOnly per instance
- **openclaw**: OpenClaw assistant of an AI space behind the zone SSO
- **space**: Light accounts for members, no sudo, space-member home
- **openclaw**: Matrix channel of an AI space, just space-bot
- **space**: AI space agent tooling, MCP, skills, Claude Code, Codex, whisper
- **openclaw**: Space owner approves, gets proactive DMs; Matrix rooms ignored
- **openclaw**: Declared identity of the assistant, the config is read-only
- **installer**: Just try, the installer VM with the project pinned on this tree
- **install**: Install-here takes an extra binary cache for nixos-install
- **openclaw**: Exec policy option, approvals reserved to the owner
- **space**: MCP server secrets from the space's sops file (secretEnv)
- **installer**: Just try serves this machine's store, a relaunch keeps the pin
- **home**: Local network launchers named in French in a French session
- **microvm**: Hypervisor asserted neither gateway nor NetworkManager
- **remote-desktop**: Rd stop mode, host reason on arming failure
- **home**: More games, education and productivity apps for child/teen
- **home**: School, accessibility and coding tools for child/teen
- **umi**: Talon speech recognition asleep at start by default
- **supertuxkart**: Accept players from every zone and the tailnet
- **ai-space**: Opencode for members and the openclaw agent
- **microvm**: Hypervisor whisper.cpp server for guests' voice notes
- **openclaw**: Mutable config option, owner admin in the UI
- **openclaw**: Model catalog, subscriptions first, API keys, providers
- **openclaw**: Browser Talk with OpenAI GPT-Live, ChatGPT login first
- **openclaw**: Lobster workflows, automations declared in Nix
- **openclaw**: CliUsers run the host CLI, bare openclaw opens the TUI
- **headscale**: Policy alias for every declared zone host
- **headscale**: Log real client IPs behind the local Caddy

### Fixed

- **iso**: Tty1 waits for the network, Enter opens nmtui for Wi-Fi
- **init**: Dnf/ link is a GC root, kept by the weekly garbage collection
- **iso**: NetworkManager alone on the NICs, no dhcpcd beside it
- **oauth2-proxy**: Run only where Caddy calls it, not on every zone host
- **hardware**: Zed starts without the emulated GPU warning on a VM
- **space**: Space-init checks file recipients, not infra-key decryption
- **microvm**: No networkd wait-online on a dhcpcd hypervisor
- **microvm**: Keep dhcpcd DNS on the hypervisor, no networkd-pulled resolved
- **microvm**: Writable store layer in guests, Home Manager activates
- **space**: Space-bot parses the MAS token log line, perms restored on failure
- **space**: Space-bot writes its marker with sudo, var/generated is not nix's
- **space**: Space-init writes the bot marker in nixfmt shape
- **sso**: Oauth2-proxy refreshes claims every 15m, group changes apply
- **microvm**: Hypervisor asserts its guests keep its stateDir
- **openclaw**: One DM session per member when a space has several
- **openclaw**: Project clones accept a new SSH server key
- **home**: Image viewer for every graphic profile, Geeqie with the essentials
- **home**: Local network folder waits for the shell's folders, retried on error
- **gnome**: One hidden-apps list with UMI, absent apps no longer shadowed
- **microvm**: Hypervisor fully on networkd, static zone resolver
- **microvm**: Guest resolves through the zone only, no fallback nor LLMNR
- **microvm**: No store optimise on a hypervisor, guest overlays go ESTALE
- **nix-cache**: Resumed NARs bypass the cache, stable pins for broken apps
- **tests**: Sops fixture for the isolated space1 host of eval-all
- **virtualbox**: Sign kernel modules with kmodigest, aggregator needs .ko.cer
- **nextcloud**: Create admin via occ, adminuser option removed upstream
- **openclaw**: Seed mutable config per key, keep UI-set shapes
- **openclaw**: Icon & description
- **openclaw**: Patch Node runtime with patchelf --no-sort, ld.so segfault
- **headscale**: Wait for a real 200 from the OIDC issuer before starting
- **headscale**: Reach local Kanidm on loopback, no boot-time OIDC fallback

### Security

- **microvm**: Guest state dirs closed to the hypervisor's users (0770)
- **openclaw**: Hardened gateway unit, agent writes to its state only
- **microvm**: Guest state bound nosuid,nodev on the hypervisor
- **adguardhome**: Upstream and fallback DNS over TLS/HTTPS only
- **c8**: Zone resolvers encrypt upstream, clients only drop the fallback

### Removed

- **adguardhome**: Drop deprecated host/port, set settings.http.address
- **games**: Drop warzone2100, build broken against abseil 20260817
- **headscale**: Drop :443 from server_url, matching the OIDC redirect

### Changed

- **adguardhome**: DNS cache on, dnsmasq local answers stay uncached
- **nix-cache**: Raise default cache size from 40g to 100g
- **microvm**: Align whisper OpenMP threads with the server's

### Documentation

- **template**: Project README rewritten as the admin's welcome guide
- **openclaw**: Commands run without approval, the microVM is the boundary
- **space**: Monitoring-node in the header examples, alerts need it
- **template**: README asks for git add before a build, commits for history

### Dependencies

- dnf-generator v0.3.1
- dnf-generator v0.3.2
- fleet-update v0.7.5

## [0.5.0] - 2026-10-17

### ⚠ Breaking

- **office**: Darkone.home.office.huntspellLang renamed hunspellLang
- **home**: VS Code and slidev opt-in, enableVscode and enableSlidev
- **printing**: Laptops no longer load every driver, loadAll opt-in

### Added

- **office**: Element as soon as Matrix runs, Fractal with enableCommunication
- **hm**: Ghostty installs its terminfo on ssh hosts (ssh-terminfo)
- **gnome**: EnableGdmSelector option shows the GDM user list
- **umi**: Eye tracker calibration from a Cinnamon menu favorite
- **umi**: HeadSpeed option dampens head control, live tuning from the REPL
- **umi**: Rofi application grid, panel button and hiddenApps option
- **home**: Games/education excludePackages, umi dark theme by default
- **office**: Cartable Fantastique LibreOffice toolbar for child profile
- **umi**: Application windows open maximized (enableMaximize)
- **umi**: Tobii 5 defaults, head control on, headSpeed 5, gaze filter 1
- **umi**: Hover click defaults, 1.6 s delay and 30 px motion threshold
- **umi**: Single click once button, hover click pauses after one left click
- **umi**: EnableStkWithMouse, play SuperTuxKart with the mouse alone
- **templates**: Project template, nix flake new -t creates a DNF project
- **schema**: Ship config.schema.json, editors validate etc/config.yaml
- **iso**: Installer ISO attached to each release, keyless setup hint
- **hardware**: No firmware on virtual machines, detected by detect-hw
- **configure**: Bootstrap-keys creates admin keys without the nix account
- **install**: Install-here, local install of the admin host from the ISO
- **iso**: Generic image ships darkone, its tools and the framework tree
- **install**: Install-here installs an encrypted admin host with LUKS
- **install**: Admin key backup on USB, assistant on tty1, welcome page
- **iso**: #try app, serial console, installer VM test gating the release

### Fixed

- **just**: Luks target description
- **gnome**: Reset the login keyring after an admin password change
- **alerts**: NodeDown description names the 5m delay of WAN-reached hosts
- **secrets**: One generation unit per bundle rule, not per generator
- **just**: Locale-independent order of the generated import lists
- **profiles**: Every profile value overridable per user (mkDefault)
- **advanced**: MANPAGER through bat only when bat is enabled
- **education**: Tuxpaint under enableDraw, not enableMusic
- **advanced**: No empty TERMINAL, ~/.local/bin once in PATH
- **vim**: Broken visual * and # maps, Neovim-only plugins, git branch shown
- **ai**: Copilot CLI installed as a package, never loaded as a gh extension
- **office**: Element and Fractal autostart tied to the graphical session
- **student**: Music with GNOME only, the profile failed on hosts without it
- **ai**: Unparsable settings.json set aside instead of failing the switch
- **nfs**: XDG dir quoted in the home link script
- **home**: Overwrite an older .bkp instead of failing the activation
- **home**: Audacious, vlc and GNOME games only with a GNOME session
- **ai**: Claude Code status line gets node in its PATH
- **core**: Xterm-ghostty terminfo installed fleet-wide
- **hm**: TERM no longer forced to xterm-256color in session variables
- **umi**: Mint-cursor-themes excluded, Bibata cursors from bibata-cursors only
- **gnome**: Nix maintenance account hidden from the GDM user list
- **umi**: Passwordless keyring for the autologin user on encrypted hosts too
- **umi**: Talon waits for the panel tray, Tobii screen size limit documented
- **invite**: Instructions improvements
- **flake**: Fetch firefox-addons over git+https, gitlab: API returns 403
- **monitoring**: FilesystemReadOnly ignores intended read-only mounts
- **configure**: Explicit error when the nix deploy account is missing
- **i18n**: Keyboard per locale from config/locales.json, en_GB pt be ch se
- **iso**: Welcome hint, darkone new no longer needs an answers file
- **iso**: Assistant launched once per boot on tty1, not again on sudo -i
- **install**: Backup-admin keeps the previous backup until the new one is in

### Security

- **ai**: Claude Code asks before git checkout, permission labels fixed
- **yubikey**: Expire the cached LUKS passphrase (KeyringMode=shared)

### Removed

- **office**: Drop mattermost-desktop
- **audio**: Drop the easyeffects-fw16 preset, defined nowhere
- **hm**: Removed nc alias + zed assistant config
- **gnome**: Drop GDM greeter Exclude list, ignored by GDM
- **umi**: Drop corner bar and Bluetooth icon, even launcher spacing

### Changed

- **lib**: Factor service params cascade, zone lookups and alert groups
- **services**: Split the registry, Caddy and oauth2-proxy modules
- **srv-dirs**: One layout table drives defaults and prefix assertions
- **i18n**: Locale regex shared through dnfLib, drop dead keymap code
- **yubikey**: Reuse the luks volume detection, concise comments
- **matrix**: Split MAS, MatrixRTC and bridges into sub-modules
- **monitoring**: One textfile collector dir constant in dnfLib
- **headscale**: Split pivot DNS, audit and enrollment into sub-modules
- **tailscale**: Split cert sync, self-heal and auto-pause into sub-modules
- **idm**: Split replication and provisioning, reuse the resolved registry
- **restic**: Split the REST server and freshness metrics into sub-modules
- **nextcloud**: Phone region and tailnet range from dnfLib
- **modules**: Tailnet range from dnfLib constants, English comment
- **gateway**: Backup uplinks in their own sub-module
- **monitoring**: One isNode source, the monitoring module option
- **home**: Named package conditions, shared palettes in advanced and umi
- **office**: DnfLib locale and homepage lookups, concise comments
- **music**: MPD session variables left to the home-manager module
- **home**: User profile imported by path, errors name the profile file
- **advanced**: EDITOR and VISUAL left to programs.vim.defaultEditor
- **office**: Split into browsers, matrix, nextcloud, pandoc sub-modules
- **zsh**: P10k plugin ships p10k.zsh alone, not the whole assets/ tree
- **user**: NixOS user profiles merged with mkMerge, not a shallow //
- **eval**: Backport fork modules, drop the nixpkgs-oxicloud input

### Documentation

- **modules**: Sub-module documentation moved into the main module header
- **home**: Module headers and comments match the code
- **mime**: Header describes the actual defaults, dead branch dropped
- **templates**: Admin recipes run on a DNF host, as its nix account

### Dependencies

- dnf-generator v0.3.0

## [0.4.0] - 2026-10-05

### ⚠ Breaking

- **office**: Move darkone.console.pandoc to darkone.home.office.enablePandoc
- **manage**: Just enter is port 22 only, just unlock takes the initrd prompt
- **nextcloud**: Move to 35, drop news/memories/recognize plugins

### Added

- **vaultwarden**: Allow emergency access for master password recovery
- **invite**: Just invite, welcome sheet and Kanidm reset link
- **secrets**: Warn on a hashed vaultwarden admin token
- **umi**: Derive UMI users from their user profile
- **gnome**: Let users override the pointer size, UMI users get 48 px
- **umi**: Native GNOME a11y for UMI users outside UMI hosts
- **user**: SSH keys via authorized_keys registry and rbw agent
- **home**: Rbw vault lock after 12h of inactivity
- **pandoc**: Added typst
- **office**: Make ConTeXt optional in the pandoc toolchain
- **office**: Default pandoc PDF engine, language and fonts
- **office**: Md2pdf command with ConTeXt and typst layouts
- **office**: Nautilus entries to convert Markdown to PDF
- **office**: Md2pdf typst layout closer to ConTeXt, schemas fit width
- **office**: Md2pdf typst renders raw TeX breaks and TOC, ConTeXt-like title
- **office**: Md2pdf --tablet on A6 at 9pt, the layout tuned for tablets
- **office**: Md2pdf and pandoc default to the typst engine
- **office**: Md2pdf typst polish: TOC, rules, lists, footnotes, inline code
- **office**: Md2pdf typst footnotes at 80%, tight as with ConTeXt
- **office**: Md2pdf typst sizes table columns from their content
- **oxicloud**: Trusted proxy, kanidm admins, nextcloud api, smtp, locale
- **dns**: Resolve tailnet node names from zone LANs
- **admin**: Dnf-locate routes ssh to roaming fleet hosts
- **engine**: Presence probe over the deploy ssh connection
- **enter**: Dnf-locate logs
- **headscale**: Unbound view gives tagged nodes the LAN address of zone globals
- **umi**: Larger Cinnamon panel, icons and text, single-click Nemo
- **umi**: Eye tracker plugged in enables gaze control and hover click
- **umi**: Gaze panel with hover click types, pause zone and keyboard toggle
- **umi**: No terminal launcher, text scaling 1.4
- **umi**: Roomier Cinnamon menu entries
- **umi**: Panel gaze switch, Talon action user.umi_gaze
- **umi**: Accessibility on from first login, no Onboard prompt
- **umi**: Onboard starts hidden, replaces its own autostart entry
- **umi**: Hide click type buttons while hover click is paused
- **umi**: Faster Talon gaze filters, head control and mouse jump off
- **umi**: Gaze button off pauses hover click, back on resumes it
- **umi**: Declarative Talon eye tracking modes (gaze, head, jumps, focus)
- **umi**: Gaze settings updates
- **nix-cache**: Roaming host feature sets the roaming substituters

### Fixed

- **invite**: Todo -> just log
- **gdm**: Realign gdm-greeter UIDs with nixpkgs
- **umi**: Pin UMI users' GDM session to Cinnamon at every boot
- **umi**: Hide Cinnamon panels through XDG_DATA_HOME, drop dead GNOME entry
- **umi**: Keep Cinnamon GSettings defaults out of GNOME and the GDM greeter
- **office**: Md2pdf typst tolerates stray citations and dead links
- **office**: Md2pdf ConTeXt no longer drops table rows at page breaks
- **security**: C7 NTP servers as absolute FQDN, immune to search domain
- **ai**: Disable herdr, unstable build fails to link
- **outline**: Overlay fixing 1.10.1 yarn patch and hashes
- **dns**: Undeclared zone names no longer resolve to the gateway
- **manage**: Just enter reaches roaming hosts through dnf-locate
- **child**: Enable education module, enableChild alone installed nothing
- **student**: Enable education module, enableStudent alone installed nothing
- **umi**: No X forwarding through su on UMI hosts, prompts lock the screen
- **umi**: Talon 1.0 support in the tracker script, Always On switched off
- **umi**: No mousetweaks in Cinnamon, click types, wheel and no hover popup
- **home**: GUI apps off pkgs-stable, glibc mismatch with Mesa driver
- **home**: Disable apostrophe, its python 3.12 deps fail to build
- **adguardhome**: No rate limit on the zone resolver
- **nextcloud**: Declarative smtp password via services.nextcloud.secrets

### Security

- **vaultwarden**: Restrict /admin to internal networks
- **umi**: Seed passwordless keyring for the autologin user only
- **umi**: Grant input/uinput groups on UMI hosts only

### Removed

- **oxicloud**: Drop target-cpu overlay, fixed in nixpkgs
- **education**: Drop celestia, build broken against FFmpeg 8
- **printing**: Drop hplip duplicate of hplipWithPlugin in CUPS drivers

### Changed

- **umi**: Align internal identifiers on the umi naming

### Documentation

- **umi**: Profile header describes the session per host
- **office**: Md2pdf table width rule in the enablePandoc description

### Dependencies

- dnf-generator v0.2.1
- fleet-update v0.7.4

## [0.3.1] - 2026-09-25

### Added

- **gateway**: Backup links with health-checked failover
- **gateway**: Standby wifi backup radios until preferred links fail
- **gateway**: Uplinks back from an outage stay on probation until proven
- **gateway**: Carrier bounce puts an uplink on probation
- **fleet-update**: AiContext reaches interactive runs through /etc

### Fixed

- **alerts**: Keep SystemdUnitFailed firing 30m across oneshot retries

### Removed

- **music**: Drop mpdris2, clashes with mpd-mpris on MPRIS bus name

### Changed

- **admin**: Stop copying nixpkgs twice into admin host closures

### Dependencies

- fleet-update v0.7.3

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

[Unreleased]: https://github.com/darkone-linux/darkone-nixos-framework/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/darkone-linux/darkone-nixos-framework/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/darkone-linux/darkone-nixos-framework/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/darkone-linux/darkone-nixos-framework/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/darkone-linux/darkone-nixos-framework/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/darkone-linux/darkone-nixos-framework/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/darkone-linux/darkone-nixos-framework/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/darkone-linux/darkone-nixos-framework/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/darkone-linux/darkone-nixos-framework/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/darkone-linux/darkone-nixos-framework/releases/tag/v0.1.0
