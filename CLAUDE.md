# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A bash CLI (`bin/claude-docker`) that launches Claude Code inside Docker containers, one per task, each in its own git worktree with guard hooks enforcing branch + file restrictions. Distributed via Homebrew.

## Common commands

```bash
# Use the CLI locally (without installing)
./bin/claude-docker run <task> ["prompt"]
./bin/claude-docker cleanup <task>
./bin/claude-docker list
./bin/claude-docker login        # one-time Claude auth (writes to ~/.agent-home)
./bin/claude-docker --dry-run run <task>   # inspect the docker invocation without executing

# Two-step workflow: prepare worktree, open IDE on it, then run Claude from the
# IDE's terminal so diffs/commits/tests share one window with Claude's prompts.
./bin/claude-docker prepare <task>                    # creates worktree, prints path on stdout
idea "$(./bin/claude-docker prepare <task>)"          # idempotent — safe to chain
./bin/claude-docker run <task>                        # from the worktree IDE's terminal

# Build images locally for testing
docker build -t claude-docker-base:test images/base
docker build -t claude-docker-node:test --build-arg BASE_TAG=test images/node
```

There is **no test or lint suite**. Verify behavior via `--dry-run` for the CLI and by running containers end-to-end. Verify entrypoint hook logic by inspecting the generated `settings.json` inside a running container.

Unified release: CLI and images share a single version.
- Bump `IMAGE_VERSION` at the top of `bin/claude-docker` and push to `main`.
- `.github/workflows/build-images.yml` detects the change, builds all four images (base first, then java/node/python in parallel, all pinned to `BASE_TAG=<version>`, multi-arch amd64+arm64), then creates the `v<version>` git tag and GitHub Release.
- `workflow_dispatch` is an escape hatch for re-running a build at an existing version without bumping.
- After the release job, an `update-tap` job downloads the source tarball, computes its `sha256`, rewrites `url` + `sha256` in `Formula/claude-docker.rb`, commits the result back to `main` here (with `[skip ci]`) and mirrors the same file to the `hansvd/homebrew-claude-docker` tap. This needs a fine-grained PAT scoped to the tap repo (Contents: Read & Write), stored as the `HOMEBREW_TAP_TOKEN` secret on this repo.

### Rotating `HOMEBREW_TAP_TOKEN` (when the PAT expires)

Symptom: a release builds fine but the `update-tap` job fails at the
"Mirror formula to homebrew tap" step with a `403` / `Bad credentials`
error from `git push`. GitHub also emails the token owner ~7 days before
expiry.

To rotate:

1. **Generate a replacement PAT.** Open
   <https://github.com/settings/personal-access-tokens> →
   **Generate new token (fine-grained)**:
   - Resource owner: `hansvd`
   - Repository access: **Only `hansvd/homebrew-claude-docker`**
   - Repository permissions → **Contents: Read and write**
   - Pick a new expiration date.
   Copy the token value — it's shown only once.
2. **Update the secret** on this repo at
   <https://github.com/hansvd/claude-docker/settings/secrets/actions>:
   click **`HOMEBREW_TAP_TOKEN`** → **Update secret** → paste the new
   value → **Update secret**. (Do not delete and recreate; updating in
   place avoids a window where the secret is missing.)
3. **Re-run the failed release** if a release was blocked by the expired
   token: open the failed Actions run → **Re-run failed jobs**. Only
   `update-tap` will re-execute; the build/release outputs are still
   valid. If you'd rather drive it manually, re-run the workflow via
   `workflow_dispatch` with the same `version` and
   `create_release=false` — but that path skips `update-tap` (gated on
   `should_release`), so prefer **Re-run failed jobs**.
4. **Revoke the old PAT** once the new one is confirmed working, at
   <https://github.com/settings/personal-access-tokens> → old token →
   **Revoke**.

Tip: set a calendar reminder a week before the new token's expiration so
rotation happens before, not after, a blocked release. GitHub does not
currently support fine-grained PATs without an expiration.

## Architecture

Flow: host CLI → docker run → in-container entrypoint → Claude Code with dynamically-registered guard hooks.

- **`bin/claude-docker`** (host, macOS bash) — Parses `.claude-docker.yml` via `yq` (falls back to `grep` for flat keys), resolves config precedence (CLI flags > yaml > defaults), creates a worktree at `.claude-workspaces/<task>` on branch `ai-tasks/<task>`, and invokes `docker run` with the worktree, `~/.agent-home`, and `~/.ssh` (ro) mounted. Also mounts `~/.claude/settings.json` read-only at `/opt/host-claude-settings.json` (when present, opt out with `--no-host-settings`) so the entrypoint can sync the host's plugin list. Passes rules to the container as `CLAUDE_DOCKER_*` env vars. Resolves the optional setup-script path against the worktree and forwards it as `CLAUDE_DOCKER_SETUP_SCRIPT`.
- **`lib/entrypoint.sh`** (in-container) — Optionally syncs the host's `enabledPlugins` from `/opt/host-claude-settings.json` (running `claude plugin install` for any missing plugins, then merging `enabledPlugins` into the container's settings.json). Backs up Claude's `settings.json`, generates `branch-guard.sh` and `file-guard.sh` from env vars (with `__PREFIX__` / pattern placeholder substitution), registers them as hooks, launches `claude --dangerously-skip-permissions`, and restores original settings via EXIT trap (so the merged `enabledPlugins` persists across runs while hooks are removed). Also sets `git safe.directory` for the mounted worktree.
- **`images/`** — Layered Dockerfiles. `base` = Ubuntu 24.04 + Node 20 + Claude CLI + Playwright/Chromium + Playwright MCP. Plugins are **not** baked into the image — they're synced at runtime from the host's `~/.claude/settings.json`, since `~/.agent-home` shadows `/home/agent/.claude/` anyway. Stacks extend base: `java` adds Temurin JDK 24 (arch-agnostic symlink for `JAVA_HOME`), `python` adds python3/pip/uv, `node` is a pass-through for explicit selection. Stack builds use `--build-arg BASE_TAG=latest`, so base and stacks have decoupled release cycles. The container runs as whatever `--user` the CLI passes (host UID on macOS = 501; 1000 on Linux); hooks are generated at runtime into `$HOME/.claude-docker-hooks` so they're writable regardless of UID.
- **`Formula/claude-docker.rb`** — Homebrew formula (deps: `yq`, `jq`). The tap itself lives in a separate repo `hansvd/homebrew-claude-docker`; this formula is the source of truth copied into the tap. `version` and `sha256` must be bumped manually on each release (see commits `711f155`, `416897a`).

## Key conventions

- **Defaults** when config is absent: `image: node`, `base-branch: origin/main`, `branch-prefix: ai-tasks/`, `protected-files: .env, *.pem, *.key`.
- **Setup script**: `setup-script: <path>` in `.claude-docker.yml` (or `--setup-script <path>`) runs `bash <path>` inside the container after Claude auto-update and before hook generation, with cwd = worktree root. Independent of `--no-hooks`. Disable with `--no-setup`. A non-zero exit aborts the container before Claude launches.
- **Safety model**: Claude is launched with `--dangerously-skip-permissions` — its native permission prompts are bypassed and all enforcement comes from the custom hooks. Editing the hook generation in `lib/entrypoint.sh` directly affects what Claude can and cannot do. Take hook changes seriously.
- **Branch guard** restricts `git checkout/switch/push/merge/rebase` to the configured prefix and **blocks branch deletion entirely**. `--no-hooks` disables all guards.
- **Persistent state**: `~/.agent-home` is shared across tasks (Claude config, plugins, auth). `.claude-workspaces/` holds the worktrees and should be gitignored in consumer repos.
- **Host plugin sync**: at startup, the entrypoint reads the host's `~/.claude/settings.json` (mounted read-only) and installs any plugin in its `enabledPlugins` that isn't already present in `~/.agent-home/.claude/plugins/`, then merges `enabledPlugins` into the container's settings file. Marketplace IDs are resolved via the `MARKETPLACE_SRC` map in `lib/entrypoint.sh` — only `claude-plugins-official → anthropics/claude-plugins-official` ships out of the box; plugins from unmapped marketplaces are skipped with a warning. Hosts hooks/`env`/`permissions` are not synced. Disable with `--no-host-settings`.
- **`bin/claude-docker` runs on user macOS hosts**, not in the container. Keep it portable bash; don't depend on GNU-only flags. Dependencies are limited to what Homebrew pulls in (`yq`, `jq`) plus `docker` and `git`.
- **Config parsing**: when adding new config keys, update both the `yq` path and the `grep`-based fallback in `bin/claude-docker` so flat YAML still works without `yq`.
