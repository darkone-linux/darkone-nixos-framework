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

### Interactive driver

```bash
just simulate-debug node-sops                          # REPL
echo -e 'start_all()\nnode1.succeed("true")\n' | just simulate-debug node-sops  # pipe
```

Primitives: `start_all()`, `wait_for_unit`, `succeed`, `fail`, `shell_interact`, `screenshot`, `get_screen_text`. 

## Adding a scenario

1. Pick subdir: `scenarios/{machines,modules,services}/`.
2. Name: `node-<what>.nix`.
3. Template — `mkNodeTest`, point at workspace + host:

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

4. `git add <new-files>` — nix pure eval only sees git-tracked files. Untracked files cause "attribute missing" errors even though they exist on disk.
5. Verify: `just simulate <check-name>` builds the VM (no boot).
6. New workspace variant: `etc/config.yaml` under `workspaces/<axis>/configs/<variant>/`, symlink `usr` + `dnf` to `_skeleton/`, then `just fixtures generate`.
7. Append workspace path to `scenarios/eval-all.nix` for L1 coverage.

## Adding a service test

Pattern for `darkone.service.<X>` on a "server" profile host.

### 1. Workspace

- `workspaces/node/configs/server-<X>/etc/config.yaml`: copy `server-forgejo` as template (one zone, gw1, server1 with `hosts[].services.<X>`).
- Minimal-mixin auto-bridge: `host.services.<X>` → `darkone.host.minimal.enable<X> = true` → `darkone.service.<X>.enable = true`. Don't hand-enable modules.
- `usr` + `dnf` → symlinks to `_skeleton/`. `just fixtures generate`.

### 2. Scenario

- `scenarios/services/node-server-<X>.nix`, `mkNodeTest`, `host = "server1"`.
- Wait for `multi-user.target`, then `wait_for_unit` + `is-active` on every hard runtime dep **and** the main unit. Auto-iterate `<X>-*.service` to catch upstream unit splits.
- HTTP smoke: `wait_for_open_port` + `wait_until_succeeds` with `curl -fsSL … | grep -q '^200$'`. The `-L` follows redirects — some services (forgejo) return 303 on `/`.
- **`git add`** the scenario `.nix` before `just simulate` sees it (pure eval).

### 3. `lan = true`

If the module binds to `host.ip` (e.g. `services.immich.host = host.ip`):

```nix
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  ...
  lan = true;
  testScript = ''… curl http://${host.ip}:<port>/ …'';
}
```

`lan = true` brings up the zone VLAN on `eth1`, pins `host.ip`. Without it, the bind fails with `EADDRNOTAVAIL`; the unit crash-loops on `Restart=on-failure`. Leave default (`false`) when the service binds to `0.0.0.0`/`localhost` (forgejo, fail2ban).

### 4. What NOT to assert

- **caddy**: lives on the **gateway**, not the service host. Test in gateway/network scenarios.
- **kanidm**: OAuth2 client templates inert until kanidm itself is enabled.
- **Optional features**: redis, ML, … default off. Document the gate in the header instead of muting asserts.

### 5. Eval-all

Append workspace path to `scenarios/eval-all.nix` for L1 eval coverage on all hosts.

### 6. Iteration

- `just simulate <check-name>` builds the check VM (no boot).
- Equivalent: `nix build '.#checks.<system>.<check-name>' --no-link`.
- **Avoid** `nix build '.#checks.<system>.eval-all'` during iteration — evaluates every workspace, costs minutes per cycle.

### 7. Gotchas

- **Untracked files invisible to pure eval.** New files must be `git add`ed (or committed) before `nix build` / `just simulate` sees them. Staging is enough — no commit needed. The "dirty tree" warning is harmless; missing untracked files cause "attribute missing" errors.
- **`dnf-generator` writes into existing `var/generated/`.** `just fixtures generate` handles this. If running the generator by hand, `mkdir -p var/generated` first.

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
