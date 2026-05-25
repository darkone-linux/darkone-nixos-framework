# Test fixtures — INSECURE, committed on purpose

`keys/test-infra.age` is a **throwaway** age identity used ONLY to encrypt
fake test secrets in `secrets/secrets.yaml` (password = `test`). It is
committed deliberately so simulations are pure and reproducible.

**NEVER** reuse this key or these secrets in production. Regenerate with
`just fixtures gen-secrets`.
