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

# Build images locally for testing
docker build -t claude-docker-base:test images/base
docker build -t claude-docker-node:test --build-arg BASE_TAG=test images/node
```

There is **no test or lint suite**. Verify behavior via `--dry-run` for the CLI and by running containers end-to-end. Verify entrypoint hook logic by inspecting the generated `settings.json` inside a running container.

Unified release: CLI and images share a single version.
- Bump `IMAGE_VERSION` at the top of `bin/claude-docker` and push to `main`.
- `.github/workflows/build-images.yml` detects the change, builds all four images (base first, then java/node/python in parallel, all pinned to `BASE_TAG=<version>`, multi-arch amd64+arm64), then creates the `v<version>` git tag and GitHub Release.
- `workflow_dispatch` is an escape hatch for re-running a build at an existing version without bumping.
- The Homebrew tap (`hansvd/homebrew-claude-docker`) is still updated by hand after each release — copy `Formula/claude-docker.rb`, bump `url` and `sha256`.

## Architecture

Flow: host CLI → docker run → in-container entrypoint → Claude Code with dynamically-registered guard hooks.

- **`bin/claude-docker`** (host, macOS bash) — Parses `.claude-docker.yml` via `yq` (falls back to `grep` for flat keys), resolves config precedence (CLI flags > yaml > defaults), creates a worktree at `.claude-workspaces/<task>` on branch `ai-tasks/<task>`, and invokes `docker run` with the worktree, `~/.agent-home`, and `~/.ssh` (ro) mounted. Passes rules to the container as `CLAUDE_DOCKER_*` env vars.
- **`lib/entrypoint.sh`** (in-container) — Backs up Claude's `settings.json`, generates `branch-guard.sh` and `file-guard.sh` from env vars (with `__PREFIX__` / pattern placeholder substitution), registers them as hooks, launches `claude --dangerously-skip-permissions`, and restores original settings via EXIT trap. Also sets `git safe.directory` for the mounted worktree.
- **`images/`** — Layered Dockerfiles. `base` = Ubuntu 24.04 + Node 20 + Claude CLI + Playwright/Chromium + official Claude plugins + Playwright MCP. Stacks extend base: `java` adds Temurin JDK 24 (arch-agnostic symlink for `JAVA_HOME`), `python` adds python3/pip/uv, `node` is a pass-through for explicit selection. Stack builds use `--build-arg BASE_TAG=latest`, so base and stacks have decoupled release cycles. The container runs as whatever `--user` the CLI passes (host UID on macOS = 501; 1000 on Linux); hooks are generated at runtime into `$HOME/.claude-docker-hooks` so they're writable regardless of UID.
- **`Formula/claude-docker.rb`** — Homebrew formula (deps: `yq`, `jq`). The tap itself lives in a separate repo `hansvd/homebrew-claude-docker`; this formula is the source of truth copied into the tap. `version` and `sha256` must be bumped manually on each release (see commits `711f155`, `416897a`).

## Key conventions

- **Defaults** when config is absent: `image: node`, `base-branch: origin/main`, `branch-prefix: ai-tasks/`, `protected-files: .env, *.pem, *.key`.
- **Safety model**: Claude is launched with `--dangerously-skip-permissions` — its native permission prompts are bypassed and all enforcement comes from the custom hooks. Editing the hook generation in `lib/entrypoint.sh` directly affects what Claude can and cannot do. Take hook changes seriously.
- **Branch guard** restricts `git checkout/switch/push/merge/rebase` to the configured prefix and **blocks branch deletion entirely**. `--no-hooks` disables all guards.
- **Persistent state**: `~/.agent-home` is shared across tasks (Claude config, plugins, auth). `.claude-workspaces/` holds the worktrees and should be gitignored in consumer repos.
- **`bin/claude-docker` runs on user macOS hosts**, not in the container. Keep it portable bash; don't depend on GNU-only flags. Dependencies are limited to what Homebrew pulls in (`yq`, `jq`) plus `docker` and `git`.
- **Config parsing**: when adding new config keys, update both the `yq` path and the `grep`-based fallback in `bin/claude-docker` so flat YAML still works without `yq`.
