# DNF tests

Telegraph style.

## Layout

```
tests/
├── unit/                              # L1 unit — nix-unit on lib/
│   ├── default.nix
│   └── lib/*_test.nix
├── fixtures/                          # pre-generated, committed, shared
│   ├── keys/test-infra.age            #   throwaway age key (INSECURE)
│   ├── secrets/{secrets.yaml,.sops.yaml}
│   └── tls/{cert.pem,key.pem}         #   stub ACME cert (100y self-signed)
├── lib/                               # helpers
│   ├── workspace.nix                  #   loader: workDir -> { ws, nodes, hostNames, nodeOf, hostByName }
│   ├── test-tuning.nix                #   seam ON, sops key injected, TLS fixture (VM-agnostic)
│   ├── mkEvalTest.nix                 #   L1 — eval-only guard
│   └── mkNodeTest.nix                 #   L2 — single-node VM
├── workspaces/                        # generic, few variants
│   ├── _skeleton/usr/                 #   inert parts, symlinked by each variant
│   │   └── secrets -> ../../fixtures/secrets
│   └── node/configs/<variant>/
│       ├── etc/config.yaml            #   inventory source
│       ├── var/generated/             #   COMMITTED output of dnf-generator
│       └── usr -> ../../../_skeleton/usr
└── scenarios/                         # auto-discovered checks
    ├── default.nix                    #   walks the tree, exposes checks attrset
    ├── eval-all.nix                   #   L1 — all workspaces × all hosts
    ├── machines/  node-*.nix          #   per-host smoke / sops / ...
    ├── modules/   node-*.nix          #   per-module assertions
    └── services/  node-*.nix          #   per-service assertions
```

## Tiers

| Tier | Helper | Boots VM? | Covers |
|------|--------|-----------|--------|
| L1 eval | `mkEvalTest` | no | `toplevel.drvPath` of every host of every workspace |
| L2 node | `mkNodeTest` | 1 | one machine (module / service / profile) |
| L3 network | `mkNetworkTest` | N + VLANs | multi-host LAN (planned, phase 7) |
| L3+ vpn | `mkVpnTest` | N + VLANs | multi-zone + headscale stub (planned, phase 8) |
| L4 install | `mkInstallTest` | 1 | disko + `nixos-anywhere --vm-test` (planned, phase 9) |

Spatial axis = `node` / `network` / `vpn`. Orthogonal modes = `eval` (any workspace) and `install` (node + disko).

## Commands

| Command | Effect |
|---------|--------|
| `just unit-tests` | L1 unit: `nix-unit --flake .#libTests` |
| `just simulate` | Run every check via `nix flake check` |
| `just simulate <name>` | Build one check (`.#checks.<system>.<name>`); name = path with `/`→`-` minus `.nix` |
| `just simulate-debug <name>` | Launch the scenario's `driverInteractive` — Python REPL inside the test driver |
| `just fixtures generate` | Regenerate `var/generated/` for every workspace (in place) |
| `just fixtures check` | Anti-drift: regenerate in a tmp dir, diff against committed |
| `just fixtures gen-secrets` | (Rare) Regenerate throwaway age key + sops store + self-signed TLS |

### Interactive driver — usage

```bash
# REPL — type Python commands directly
just simulate-debug node-sops

# Smoke-run with piped commands
echo -e 'start_all()\nnode1.succeed("true")\n' | just simulate-debug node-sops
```

Useful primitives: `start_all()`, `node1.wait_for_unit("multi-user.target")`, `node1.succeed("cmd")`, `node1.fail("cmd")`, `node1.shell_interact()`, `node1.screenshot("name")`, `node1.get_screen_text()`.

## Adding a scenario

1. Pick the right subdir: `scenarios/{machines,modules,services}/` (or future `networks/`, `installs/`).
2. Name the file `node-<what>.nix` (prefix matches the spatial axis: `node-`, `network-`, `vpn-`).
3. Write the scenario — `mkNodeTest` for L2, point at a workspace + host, add assertions:

   ```nix
   { pkgs, inputs }:
   (import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
     name = "node-foo";
     workspace = ../../workspaces/node/configs/_smoke;
     host = "node1";
     testScript = ''
       node1.wait_for_unit("multi-user.target")
       node1.succeed("foo --version")
     '';
   }
   ```

4. Auto-discovery does the rest — `scenarios/default.nix` walks the tree and exposes the check as `<subdir>-<filename>` (e.g. `services/node-foo.nix` → `services-node-foo`).
5. If a new workspace variant is needed: drop `etc/config.yaml` under `workspaces/<axis>/configs/<variant>/`, symlink `usr` and `dnf` to `_skeleton/`, then `just fixtures generate`.
6. Append the workspace path to `scenarios/eval-all.nix` so L1 covers its hosts too.

## Adding a service test

Pattern for a `darkone.service.<X>` module exercised on a real "server" profile host.

### 1. Workspace

- `workspaces/node/configs/server-<X>/etc/config.yaml`: copy `server-forgejo` as a starting template (one zone, one gateway `gw1`, one server host `server1` with the service declared under `hosts[].services.<X>`).
- The minimal-mixin auto-bridge does the rest: `host.services.<X>` present → `darkone.host.minimal.enable<X> = true` → `darkone.service.<X>.enable = true` (see `modules/mixin/host/minimal.nix`). Don't enable the service module by hand.
- `usr` + `dnf` → symlinks to `_skeleton/`. `just fixtures generate`.

### 2. Scenario

- `scenarios/services/node-server-<X>.nix`, `mkNodeTest`, `host = "server1"`.
- Wait for `multi-user.target`, then `wait_for_unit` + `is-active` on every hard runtime dep (postgresql, redis, ...) **and** the main unit. Auto-iterate `<X>-*.service` to catch upstream unit splits without pinning a nixpkgs version.
- HTTP smoke: `wait_for_open_port` + `wait_until_succeeds` with `curl -fsS | grep -q '^200$'`.

### 3. Bind address — `lan = true`

If the module pins its bind to `host.ip` (e.g. `services.immich.host = host.ip`), opt-in:

```nix
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  ...
  lan = true;
  testScript = ''… curl http://${host.ip}:<port>/ …'';
}
```

`lan = true` brings up the zone VLAN on `eth1` and pins `host.ip` statically. Without it, the bind fails with `EADDRNOTAVAIL` and the unit crash-loops on systemd `Restart=on-failure` (typical log: "starting … worker → postgres → worker"). Leave default (`false`) when the service binds to `0.0.0.0`/`localhost` (forgejo, fail2ban, ...).

### 4. What NOT to assert in a service test

- **Reverse proxy (caddy)**: lives on the **gateway** in real DNF topology, not on the service host. Assert on caddy in a gateway / network test instead.
- **idm / kanidm**: most service modules register an OAuth2 client *template* under `darkone.service.idm.oauth2.<X>`. The template is inert until kanidm itself is enabled in the workspace.
- **Optional features**: redis, machine-learning, ... default off. Document the gate (`darkone.service.<X>.enable<Feature>`) in the scenario's header instead of muting the assert.

### 5. Eval-all

Append the new workspace path to `scenarios/eval-all.nix` so L1 catches eval regressions on every host of the workspace, not just the one booted by L2.

## Invariants

### Fixtures purity

- **No key/secret generation at eval or run.** `fixtures/keys/test-infra.age`, `secrets/`, `tls/` are pre-generated and committed.
- `keys/test-infra.age` is **throwaway, INSECURE** — protects only fake test passwords. Never reuse in production.
- `workDir` always points at a real source directory (no `symlinkJoin`, no IFD). Shared parts are wired via relative symlinks committed in the tree.

### `mkNodes` invariant (framework ↔ test seam)

- `lib/mk-configuration.nix` exposes `mkNodes { forTest ? false }` — single source of truth. Each host = `{ modules; specialArgs; system; }`.
- All downstreams derive from it:
  - `nixosConfigurations.<h>` ← `mkNodes {}`
  - `colmena.<h>` ← `mkNodes {}`
  - test driver `nodes.<h>` ← `mkNodes { forTest = true; }` (drops driver-owned bits: nixpkgs misc module + hostPlatform)
- **`modules/` NEVER references `tests/`.** Test-only behaviour goes through the `darkone.test.standalone` seam (`modules/system/testing.nix`) or `tests/lib/test-tuning.nix`.
- Seam neutralizes only what's irreducibly external/runtime — headscale, tailscale, ACME (→ self-signed). sops runs **for real** in VMs via the injected throwaway key.

### Workspace generation

- `var/generated/{hosts,users,network,config}.nix` is **committed** — `just fixtures check` enforces it matches what `dnf-generator` produces from `etc/config.yaml`. Drift fails CI.
- New variant → `just fixtures generate` once, commit the output.

## See also

Only if there are doubts about the organisation of the tests!

- Spec: `.specs/2026-05-25-tests-simulation-design.md`
