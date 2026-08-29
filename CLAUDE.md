# CLAUDE.md

This file provides guidance to AI Coding Assistants (Claude Code, Gemini CLI, Cursor, Antigravity, etc.) when working with code in this repository.

## What This Repository Is

`genericsuite-fe-scripts` is an **npm package of bash scripts and Makefile targets** consumed by ReactJS frontend projects as a dependency. It is not a React application itself — it provides reusable deployment and development infrastructure for consuming projects.

## Common Commands

```bash
make install          # npm install
make fresh            # Remove node_modules + npm cache, then reinstall
make update           # npm update + audit fix

make pre-publish      # Run SAST security scan + build validation (required before publishing)
make publish          # Publish to npm (runs SAST first; prompts for confirmation)
UPDATE_SNAPSHOTS=1 make publish  # Publish with updated test snapshots

make sast-test        # Run Snyk security scanning (code + dependencies)
```

> Node.js version: **26** (see `.nvmrc`)

## Architecture

### Scripts (`scripts/`)

The core of this package — 16 bash scripts that are invoked by Makefile targets in **consuming projects**:

| Script | Purpose |
|---|---|
| `aws_deploy_to_s3.sh` | Full AWS deployment: S3 bucket, CloudFront distribution, ACM SSL, OAI |
| `run_app_frontend.sh` | Start dev server with stage-specific env (HTTP or HTTPS) |
| `run_method_dependency_manager.sh` | Smart bundler switcher — uninstalls conflicting bundlers, installs the required one |
| `change_env_be_endpoint.sh` | Swap backend API endpoint for a given stage (dev/qa/demo/prod) |
| `run_symlinks_handler.sh` | Create/remove symlinks for `/public/static` assets (avoids build duplication) |
| `npm_publish.sh` | Publishing pipeline with snapshot validation and manual confirmation |
| `sast_test.sh` | Snyk SAST scan (code + dependencies) |
| `create_ssl_certs.sh` | Wrapper for self-signed SSL cert creation for local HTTPS dev |
| `add_github_submodules.sh` | Git submodule management for shared JSON config directories |
| `aws_get_ssl_cert_arn.sh` | Fetch ACM certificate ARNs from AWS |
| `build_prod_test.sh` | Validate production builds |
| `build_copy_images.sh` | Copy image assets during build |
| `link_external_configs.sh` | Link external config files into the project |
| `run_change_module_setting.sh` | Toggle ESM/CJS module type setting |

### Multi-Bundler Support

Scripts support three bundlers, selected via the `RUN_BUNDLER` env variable:
- **`vite`** (default) — modern, fast
- **`webpack`** — traditional, highly configurable
- **`react-app-rewired`** — create-react-app with overrides

`run_method_dependency_manager.sh` automatically uninstalls conflicting bundlers before installing the required one, preventing version conflicts.

### Stage-Aware Environment Management

Consuming projects use `.env` files with stage-specific variables. Scripts handle dev / qa / demo / prod stages, each with its own backend API endpoint. The `change_env_be_endpoint.sh` script updates `.env` to point at the correct backend URL per stage.

### AWS Deployment Stack

`aws_deploy_to_s3.sh` automates the entire AWS setup:
- S3 bucket creation and policy configuration
- CloudFront distribution with Origin Access Identity (OAI)
- ACM certificate provisioning and validation
- Automatic CloudFront cache invalidation post-deploy

## Shell Script Standards

From `docs/codeStyle.md`:
- Use `#!/bin/bash` shebang; call scripts with `bash`, never `sh`
- Start scripts with `set -euo pipefail`
- Quote all variable expansions: `"${var}"`
- Handle macOS vs Linux differences — prefer `perl -pi -e` over `sed -i`
- Use `echo` + `read < /dev/tty` instead of `read -p` for interactive prompts
- Avoid bash-specific features unless explicitly documented

## Environment Variables

Consuming projects must supply (typically via `.env`):
- `RUN_BUNDLER` — bundler selection (`vite`, `webpack`, `react-app-rewired`)
- `AWS_S3_BUCKET_NAME_FE_DEV`, `AWS_S3_BUCKET_NAME_FE_QA`, `AWS_S3_BUCKET_NAME_FE_STAGING`, `AWS_S3_BUCKET_NAME_FE_PROD`, `AWS_S3_BUCKET_NAME_FE_DEMO`, `AWS_REGION` — for deployment
- `APP_FE_URL` — frontend domain
- `APP_API_URL_DEV`, `APP_API_URL_QA`, etc. — backend endpoints per stage
- `FRONTEND_LOCAL_PORT` (default: 3000), `BACKEND_LOCAL_PORT` (default: 5000)
- `GIT_SUBMODULE_URL`, `GIT_SUBMODULE_LOCAL_PATH_FRONTEND` — for config submodules

For SAST (this repo's own `.env`):
- `SNYK_API_KEY`, `SNYK_ENVIRONMENT`, `SNYK_ORG`, `SNYK_ADDITIONAL_FLAGS`

## Publishing

Security scanning (`sast-test`) is **mandatory** before publishing. The `make publish` script enforces this and prompts for manual confirmation before pushing to npm. Use `UPDATE_SNAPSHOTS=1` to regenerate test snapshots when publishing after snapshot changes.

## Important Notes

- The files `AGENTS.md`, `GEMINI.md`, etc. (if present) have only a referece to `@CLAUDE.md` — edit only `CLAUDE.md`.
- Skills live in `.ai/skills/` (source of truth); symlinked under `.agents/skills/`, `.claude/skills/`, `.codex/skills/`, `.gemini/skills/`, and `.devin/skills/`.
