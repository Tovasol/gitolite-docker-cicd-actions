#!/usr/bin/env sh
# Production deploy — runs inside node:20-alpine, cwd=/work (repo checkout).
# Env from cicd-runner: CI_*, npm_config_cache=/cache/npm (shared, integrity-checked).
# Secrets from ci/secrets.enc.yaml: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID.
set -eu

cd site/scaffold
npm ci --prefer-offline
npm run build
npx wrangler pages deploy dist --project-name=pipelineforge-site --branch=main
echo "deployed pipelineforge-site (main) @ ${CI_SHA:-?}"
