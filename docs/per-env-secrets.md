# Per-environment secret scoping

Lets a **single repo** hold secrets for multiple environments (dev/qa/prod) and deploy
them via a **branching model**, without every job seeing every secret. Replaces the
"one repo per environment" workaround.

## How it works

- The runner runs per `(repo, branch)`. `branch` comes from the git hook (archive-push)
  and is gated by gitolite refex ACLs — it is **trusted, unforgeable by the pushed tree.**
- The run's **environment** is resolved from that branch (see [env resolution](#env-resolution)).
- The runner decrypts **only** `ci/secrets.<env>.enc.yaml`, **with only that tier's private
  key** (`$AGE_KEY_DIR/<env>.age`), and injects it. Sibling tiers' files sit in `/work` as
  ciphertext, the age key never enters the container, and each tier is encrypted to a
  *different* key — so they are inert to the job.

Result: a pusher who can only push `dev` (per gitolite) can never cause `prod` secrets to
be decrypted. Branch protection = deploy authorization. Because tier selection is enforced by
the **key** (not the filename), copying or symlinking `prod` ciphertext into `secrets.dev.enc.yaml`
still fails — the dev key isn't a recipient of the prod blob.

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

## Tiered keys (`.sops.yaml`)

Two independent axes:

1. **Runner age keys — one per tier.** Each tier file is encrypted to **only its own** age
   recipient; there is **no shared master key**. The runner loads only the resolved env's private
   key at decrypt, so a wrong-tier blob (even copied/symlinked under this name) can't be decrypted.
2. **Human PGP keys — tiered read/edit.** Higher tiers are supersets. A dev (only `DEV_FPR`) can
   `sops` the dev file but cannot decrypt qa/prod.

```yaml
creation_rules:
  - path_regex: (^|/)secrets\.prod\.enc\.ya?ml$
    key_groups: [{ age: ["age1PROD_RUNNER"], pgp: ["PROD_FPR_1","PROD_FPR_2"] }]
  - path_regex: (^|/)secrets\.qa\.enc\.ya?ml$
    key_groups: [{ age: ["age1QA_RUNNER"],   pgp: ["QA_FPR","PROD_FPR_1","PROD_FPR_2"] }]
  - path_regex: (^|/)secrets\.dev\.enc\.ya?ml$
    key_groups: [{ age: ["age1DEV_RUNNER"],  pgp: ["DEV_FPR","QA_FPR","PROD_FPR_1","PROD_FPR_2"] }]
```

To also stop a lower tier from *clobbering* a higher-tier ciphertext blind, add a gitolite path
VREF: `- VREF/NAME/ci/secrets.prod.enc.yaml = @dev @qa`.

## Runner key management

The runner holds one private age key **per tier** in a ramfs dir (`AGE_KEY_DIR`, cleared on
reboot). `runner.conf` (host-owned, persistent — see below) declares the map:

```sh
AGE_KEY_DIR=/run/ci-keys
AGE_ENVS="dev qa prod"
AGE_RECIPIENT_dev=age1…      # PUBLIC recipient of each tier's key (age-keygen -y)
AGE_RECIPIENT_qa=age1…
AGE_RECIPIENT_prod=age1…
```

**`unlock-ci` is identity-routed:** pipe a key, it derives the pub and files it into the slot
whose `AGE_RECIPIENT_<env>` matches — so a fat-fingered or omitted name can't put prod's key in
dev's slot. An unmatched key falls to the **legacy** slot `SOPS_AGE_KEY_FILE` (for repos still on
one `secrets.enc.yaml`), with a warning. Run once per key per boot:

```sh
pass gitolite-ci/age-key-dev  | ssh cicd-runner@vps unlock-ci   # -> dev.age
pass gitolite-ci/age-key-qa   | ssh cicd-runner@vps unlock-ci   # -> qa.age
pass gitolite-ci/age-key-prod | ssh cicd-runner@vps unlock-ci   # -> prod.age
```

`runner.conf` itself is **not secret** (public recipients + paths) but its **integrity matters** —
a tampered recipient map could mis-route a key. Keep it operator-writable on **persistent disk**
(NOT ramfs: the conf defines where the ramfs key dir *is*, so it must survive reboot). `restore-conf`
writes it from the same reboot-restore ritual: `pass gitolite-ci/runner-conf | ssh … restore-conf`.

## Security properties

1. Env from **branch** (gitolite-gated), never the manifest.
2. Declared-env **mismatch is refused**.
3. Only the resolved tier's file is selected → other tiers' plaintext never enters the job.
4. Decryption uses **only that tier's key** → a copied/renamed wrong-tier blob can't be decrypted.
5. The decrypt input is symlink-guarded (`secret_in_tree`) → a planted `secrets.<env>.enc.yaml`
   symlink can't make host-side sops read the age key or another host file.
6. Teardown recovers the branch from a job-writable mount, so its env is anchored to the env
   dir's name (`recover_env_branch`) → a job can't forge it to decrypt another tier.
7. Age keys stay host-side, one per tier → sibling ciphertext in `/work` is inert.
