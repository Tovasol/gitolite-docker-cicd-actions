# CI self-test (`gitolite` → this runner, dogfooded)

This repo runs its own CI through itself. On every push to `main`, gitolite's
`post-receive` hook hands the push to the installed runner, which executes the jobs
declared in [`.gitolite/ci.yml`](../.gitolite/ci.yml):

| job | when | image | needs secrets |
|---|---|---|---|
| `smoke` | every push to `main` | `alpine` | no — liveness check |
| `test` | every push to `main` | `node:lts-bookworm-slim` | no — lint + unit + adversarial |

`test` is self-contained: it installs its own deps in-container (ShellCheck via apt;
`yq` + `duckdb` pinned + sha256-verified into the `/cache` volume by
[`bin/fetch-tools.sh`](../bin/fetch-tools.sh)), then runs the full suite via
[`test/run.sh`](../test/run.sh). A red job fires `notify-email`.

Run the same suite locally:
```sh
bash test/run.sh
```
