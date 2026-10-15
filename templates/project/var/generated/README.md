# `var/generated/` — generator output

`hosts.nix`, `users.nix` and `network.nix` are produced by `dnf-generator`
from `etc/config.yaml`. **Never edit them by hand**: edit the YAML, then

```sh
just generate     # or: just clean (fix + check + generate + format)
```

`matrix.nix` appears only if you run `just configure-alert-bot`; it holds the
alert bot identity and room IDs, and is generated too.

> [!IMPORTANT]
> These files must be **committed**. Nix flakes only see files git knows
> about: an untracked `var/generated/hosts.nix` makes every build fail.
