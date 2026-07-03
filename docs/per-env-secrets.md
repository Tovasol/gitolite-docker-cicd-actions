# Per-environment secret scoping

Lets a **single repo** hold secrets for multiple environments (dev/qa/prod) and deploy
them via a **branching model**, without every job seeing every secret. Replaces the
"one repo per environment" workaround.

## How it works

- The runner runs per `(repo, branch)`. `branch` comes from the git hook (archive-push)
  and is gated by gitolite refex ACLs — it is **trusted, unforgeable by the pushed tree.**
- The run's **environment** is resolved from that branch (see [env resolution](#env-resolution)).
- The runner decrypts **only** `ci/secrets.<env>.enc.yaml` and injects it. Sibling tiers'
  files sit in `/work` as ciphertext, and the age key never enters the container, so they
  are inert to the job.

Result: a pusher who can only push `dev` (per gitolite) can never cause `prod` secrets to
be decrypted. Branch protection = deploy authorization.

## Repo layout

```
ci/
  secrets.dev.enc.yaml     # dev tier
  secrets.qa.enc.yaml      # qa  tier
  secrets.prod.enc.yaml    # prod tier
.sops.yaml                 # tiered recipients (below)
```

Legacy `ci/secrets.enc.yaml` still works unchanged. **But** if ANY `ci/secrets.*.enc.yaml`
exists, the per-env files are authoritative: a run whose env has no matching file is
**refused** (status `secrets-decrypt-failed`) rather than silently handed the legacy blob.

## Env resolution

1. Host-side map `$RUNNER_BASE/etc/environments.map` (or `CICD_ENV_MAP`), first match wins:
   `` <repo-glob> <branch-glob> <env> ``. See `etc/environments.map.sample`. The map is
   operator-owned — the pushed manifest cannot influence it.
2. If no map entry matches: **env = sanitized branch name** (`dev`->`dev`, `prod`->`prod`,
   `feat/x`->`feat-x`).

A job may optionally declare `jobs.<job>.environment: <env>` in `.gitolite/ci.yml` for
readability; it must **equal** the branch-resolved env or the job is refused (guards
against misconfig and any attempt to claim another tier).

## Tiered human access (`.sops.yaml`)

The runner's single **master age key** is a recipient on every tier file (so it can decrypt
whichever the branch selects). Human read/edit access is tiered by listing PGP recipients
per file — higher tiers are supersets:

```yaml
creation_rules:
  - path_regex: (^|/)secrets\.prod\.enc\.ya?ml$
    age: "age1RUNNER_MASTER"
    pgp: "PROD_FPR_1,PROD_FPR_2"
  - path_regex: (^|/)secrets\.qa\.enc\.ya?ml$
    age: "age1RUNNER_MASTER"
    pgp: "QA_FPR,PROD_FPR_1,PROD_FPR_2"
  - path_regex: (^|/)secrets\.dev\.enc\.ya?ml$
    age: "age1RUNNER_MASTER"
    pgp: "DEV_FPR,QA_FPR,PROD_FPR_1,PROD_FPR_2"
```

A dev (only `DEV_FPR`) can `sops` the dev file but cannot decrypt qa/prod → cannot edit
them. To also stop a dev from *clobbering* a higher-tier ciphertext file blind, add a
gitolite path VREF: `- VREF/NAME/ci/secrets.prod.enc.yaml = @devs @qa`.

## Security properties

1. Env from **branch** (gitolite-gated), never the manifest.
2. Declared-env **mismatch is refused**.
3. Only the resolved tier's file is decrypted → other tiers' plaintext never enters the job.
4. Age key stays host-side → sibling ciphertext in `/work` is inert.
