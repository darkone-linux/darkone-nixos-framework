# DNF tests

Telegraph style.

## Layout

```
tests/
├── unit/                              # L1 unit — nix-unit on lib/ + config/
│   ├── default.nix                    #   aggregator (feeds dnfLib, sometimes lib)
│   ├── lib/*_test.nix                 #   lib/ helpers + checkSchema engine
│   └── config/*_test.nix              #   config/ registries via dnfLib.checkSchema
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
│       ├── usr -> ../../../_skeleton/usr
│       └── dnf -> ../../../_skeleton/dnf
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

## Config validation (`config/` grammar)

L1 unit tests for the `config/*.nix` registries. Each `tests/unit/config/<file>_test.nix`
declares a **schema** (the expected grammar of `config/<file>.nix`) and asserts
`dnfLib.checkSchema schema value == [ ]`. Engine: `lib/config-schema.nix` (compact
spec in its header). Violations are path-prefixed strings (`ports.foo: ...`) — empty
list == valid.

Run: `just unit-tests`. Schema lives **inline** in the test (one source of truth per
config file); adding e.g. a new port to `network.nix` is validated automatically, no
test edit.

### Grammar

A schema node is an attrset with a `type`. Containers recurse; leaves check a value.

| `type` | Extra fields | Validates |
|--------|--------------|-----------|
| `attrs` | `key`, `fields`, `value` | recursion (see below) |
| `int` | `min`, `max` | integer; bounds **inclusive** |
| `string` | `regex`, `oneOf` | string; full match; literal whitelist |
| `bool` | — | boolean |
| `listOfStrings` | `unique` | list of strings; optionally distinct |

`attrs` node:

| Field | Meaning |
|-------|---------|
| `key.oneOf` | allowed key names (whitelist) |
| `key.regex` | each key fully matches (`builtins.match`, anchored — no `/.../`, no `^`/`$`) |
| `key.fileExists` + `key.root` | `pathExists (root + "/" + tpl)`; `{{value}}` → the key. `root` = Nix path **inside the dnf flake** (`../../..` from a test) |
| `fields.<k>` | sub-schema for known key `<k>` |
| `value` | sub-schema for every key **not** in `fields` |
| `value.unique = true` | all values across the map must be distinct |

Dispatch per key: `fields.<k>` wins; otherwise `value`. `min`/`max`, `regex`, `oneOf`,
`unique`, `fileExists` are all optional.

### Cross-cutting constraints

`checkSchema` is **node-local** — it cannot express rules that aggregate across the
whole tree (e.g. "a value at a wildcard path is unique across distinct owners"). For
those, write a **dedicated test case** in the `*_test.nix` using `lib` directly, and
pass `lib` alongside `dnfLib` in `tests/unit/default.nix`:

```nix
config_modules = import ./config/modules_test.nix { inherit dnfLib lib; };
```

Reference: `modules_test.nix` `testUniqueTriggerKeys` — collects every
`activation.profiles.<*>.triggers.keys.<myKey>`, dedups per module, and rejects a key
claimed by two distinct modules.

### Evolving a config test

1. **New key in a config file** → extend its schema (`key.oneOf` / `fields` / `value`). No engine change.
2. **New value type or constraint** (e.g. `ipv4`, a new leaf predicate) → add it to `lib/config-schema.nix` **and** cover it in `tests/unit/lib/config-schema_test.nix` (CLAUDE.md: every helper change is unit-tested).
3. **New cross-cutting rule** → dedicated test case (pass `lib`), per above.
4. New `config/<file>_test.nix` → add a `config_<file>` entry to `tests/unit/default.nix`.
5. `git add -N` new test files (pure eval sees only git-tracked files), `just unit-tests`, then `just clean`.

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

### 1. Wrap (skip if `modules/service/<X>.nix` exists)

Look up upstream (nixpkgs / PR) :

- Main unit + sub-units (`<X>.service`, `<X>-init.service`, `<X>-setup.service`, …).
- Default port + interface (`null` interface = the binary's own default, often `0.0.0.0`).
- Hard runtime deps (postgres, redis, …) — `requires` / `after` upstream.
- Package option — `services.<X>.package` (`mkPackageOption` upstream).

Then :

- `modules/service/<X>.nix` modelled on `forgejo.nix`. Declare `darkone.service.<X>.enable`, register `darkone.system.services.service.<X>` (persist + `proxy.servicePort`), wire `services.<X>.*` inside `lib.mkIf cfg.enable`.
- `modules/mixin/host/minimal.nix` — auto-bridge entry, once per service :
  ```nix
  darkone.host.minimal.enable<X> = mkOption {
    type = types.bool;
    default = attrsets.hasAttrByPath [ "services" "<x>" ] host;
  };
  # in `config.darkone.service`:
  <x>.enable = cfg.enable<X>;
  ```
- `modules/default.nix` is generated (`# DO NOT EDIT` header) — let `dnf-generator` register the new path. Hand-insertion is fine during iteration : the next regen produces the same alphabetical line, no drift.

### 2. Workspace

- Copy `workspaces/node/configs/server-forgejo/` → `server-<X>/`. Edit `etc/config.yaml` : swap `services.forgejo` for `services.<X>: { title, description, domain }`.
- `usr` + `dnf` → relative symlinks to `_skeleton/` (`../../../_skeleton/{usr,dnf}`).
- Generate this workspace only (faster than `just fixtures generate`, which walks every workspace) :
  ```sh
  cd tests/workspaces/node/configs/server-<X>
  mkdir -p var/generated
  for w in hosts users network disko; do dnf-generator "$w"; done
  ```
- Never hand-enable `darkone.service.<x>` in a workspace — the minimal-mixin bridge derives it from `hosts[].services.<X>`.

### 3. Scenario

- `scenarios/services/node-server-<X>.nix`, `mkNodeTest`, `host = "server1"`.
- Wait for `multi-user.target`, then `wait_for_unit` + `is-active` on every hard runtime dep **and** the main unit. Auto-iterate `<X>-*.service` to catch upstream unit splits.
- HTTP smoke: `wait_for_open_port` + `wait_until_succeeds` with `curl -fsSL … | grep -q '^200$'`. The `-L` follows redirects — some services (forgejo) return 303 on `/`.
- **`git add`** the scenario `.nix` before `just simulate` sees it (pure eval).

### 4. `lan = true`

If the module binds to `host.ip` (e.g. `services.immich.host = host.ip`):

```nix
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  ...
  lan = true;
  testScript = ''… curl http://${host.ip}:<port>/ …'';
}
```

`lan = true` brings up the zone VLAN on `eth1`, pins `host.ip`. Without it, the bind fails with `EADDRNOTAVAIL`; the unit crash-loops on `Restart=on-failure`. Leave default (`false`) when the service binds to `0.0.0.0`/`localhost` (forgejo, fail2ban).

### 5. What NOT to assert

- **caddy**: lives on the **gateway**, not the service host. Test in gateway/network scenarios.
- **kanidm**: OAuth2 client templates inert until kanidm itself is enabled.
- **Optional features**: redis, ML, … default off. Document the gate in the header instead of muting asserts.

### 6. Eval-all

Append workspace path to `scenarios/eval-all.nix` for L1 eval coverage on all hosts.

### 7. Iteration

- `just simulate <check-name>` builds the check VM (no boot).
- Equivalent: `nix build '.#checks.<system>.<check-name>' --no-link`.
- **Dry-run for eval-only validation** : `nix build '.#checks.<system>.<check-name>' --dry-run` — confirms the Nix evaluation chain without compiling.
- **Avoid** `nix build '.#checks.<system>.eval-all'` during iteration — evaluates every workspace, costs minutes per cycle.
- First build of source-heavy packages (OCaml/Haskell : geneweb, …) costs minutes ; the store caches subsequent runs.

### 8. Gotchas

- **Untracked files invisible to pure eval.** New files must be `git add`ed (or committed) before `nix build` / `just simulate` sees them. Staging is enough — no commit needed. The "dirty tree" warning is harmless; missing untracked files cause "attribute missing" errors.
- **`dnf-generator` writes into existing `var/generated/`.** `just fixtures generate` handles this. If running the generator by hand, `mkdir -p var/generated` first.
- **Wrapper module reachable only via `modules/default.nix`.** A new `modules/service/<X>.nix` alone is invisible until its path appears in `modules/default.nix` (generated, or hand-inserted during iteration).
- **`services.<X>.interface = null`** is *not* a guarantee the binary listens on `0.0.0.0`. Verify with `ss -tlnp` inside `simulate-debug` before relying on `localhost` ; if bound to `host.ip`, switch to `lan = true`.

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
