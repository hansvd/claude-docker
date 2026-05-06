# claude-docker

Run Claude Code autonomously on macOS in Docker with git worktree isolation and configurable safety guardrails.

Each task runs in its own git worktree and Docker container, with guard hooks that restrict branch access and protect sensitive files.

Pre-built multi-arch (amd64 + arm64) images are available for three language stacks — **Node**, **Java** (Temurin JDK 24), and **Python** (with `pip` and `uv`) — all on a shared Ubuntu 24.04 base that includes the Claude CLI, Playwright + Chromium, the official Claude plugins, and the Playwright MCP. Pick one with `image: java | node | python` in `.claude-docker.yml`.

## Install

```bash
brew tap hansvd/claude-docker
brew install claude-docker
```

Requires Docker to be running.

## Quick Start

```bash
# Authenticate Claude (one-time setup)
mkdir -p ~/.agent-home
claude-docker login

# Run a task
claude-docker run fix-login "Fix the login timeout in the auth module"

# List active tasks
claude-docker list

# Clean up when done
claude-docker cleanup fix-login
```

## Working alongside an IDE

If you want Claude's prompt to share a window with your IDE's diffs, tests, and
git tools, prepare the worktree first, open it in the IDE, and launch Claude
from the IDE's terminal:

```bash
# Create the worktree without launching the container.
# Prints the worktree path on stdout; idempotent — safe to chain.
idea "$(claude-docker prepare fix-login)"

# Then, from a terminal inside that IDE window:
claude-docker run fix-login
```

`prepare` accepts the same `--from`, `--branch-prefix`, `--workspaces-dir`,
`--config`, and `--dry-run` flags as `run`. `run` invoked from inside an
existing worktree reuses it — it won't create a nested one.

## Configuration

Drop a `.claude-docker.yml` in your repo root:

```yaml
# Which pre-built image stack to use: java | node | python
image: java

# Base branch for new worktrees
base-branch: origin/master

# Branch prefix for task branches
branch-prefix: ai-tasks/

# Where to put task worktrees. Supports $REPO_ROOT and ~ expansion.
# Default: $REPO_ROOT/.claude-workspaces
workspaces-dir: ~/claude-workspaces/$REPO_ROOT

# Guard hooks — protect sensitive files and directories
guards:
  protected-files:
    - "configuration.*.xml"
    - ".env"
  protected-paths:
    - "deployment/kubernetes/configurations"

# Extra flags passed to the `claude` CLI inside the container.
# `$task_name` (or `${task_name}`) is interpolated with the current task name.
claude-flags: "--remote-control $task_name"

# Extra environment variables for the container
env:
  GRADLE_OPTS: "-Xmx2g"

# Update Claude to the latest release on every container start (default: true).
# Set to false for offline use or to pin to the version baked into the image.
auto-update-claude: true

# Bootstrap script run inside the container before Claude launches.
# Path is relative to the worktree root. Cwd is the worktree root.
# Use it for project setup like `npm install` in subdirs, lockfile workarounds,
# warming caches, etc. A non-zero exit aborts the container.
setup-script: scripts/claude-bootstrap.sh
```

All fields are optional. Without a config file, sensible defaults apply:

| Field | Default |
|-------|---------|
| `image` | `node` |
| `base-branch` | `origin/main` |
| `branch-prefix` | `ai-tasks/` |
| `workspaces-dir` | `$REPO_ROOT/.claude-workspaces` |
| `guards.protected-files` | `.env, *.pem, *.key` |
| `guards.protected-paths` | _(none)_ |
| `claude-flags` | _(none)_ |
| `auto-update-claude` | `true` |
| `setup-script` | _(none)_ |

## Commands

### `claude-docker run <task-name> ["prompt"]`

Creates a git worktree and launches a Docker container with Claude Code.

| Option | Description                                                                                                           |
|--------|-----------------------------------------------------------------------------------------------------------------------|
| `-d, --dir <subdir>` | Start Claude in a subdirectory                                                                                        |
| `--from <branch>` | Base branch for the worktree                                                                                          |
| `--image <stack>` | Override image stack                                                                                                  |
| `--branch-prefix <prefix>` | Override branch prefix                                                                                                |
| `--workspaces-dir <path>` | Directory for worktrees (default `$REPO_ROOT/.claude-workspaces`). Supports `$REPO_ROOT` and `~` expansion             |
| `--prompt-file <path>` | Read prompt from a file                                                                                               |
| `--claude-flags "<flags>"` | Extra flags passed to `claude`. `$task_name` / `${task_name}` are interpolated (e.g. `"--remote-control $task_name"`) |
| `--setup-script <path>` | Bootstrap script (relative to worktree) run inside the container before Claude launches                               |
| `--no-setup` | Skip the configured setup script                                                                                      |
| `--no-hooks` | Disable all guard hooks                                                                                               |
| `--no-update` | Skip updating Claude before start                                                                                     |
| `--dry-run` | Show what would happen                                                                                                |

### `claude-docker prepare <task-name>`

Creates the worktree without launching the container, then prints its absolute
path on stdout. Use it to open the worktree in an IDE before starting Claude
(see [Working alongside an IDE](#working-alongside-an-ide)). Idempotent:
re-running on an existing task just prints the path. Accepts `--from`,
`--branch-prefix`, `--workspaces-dir`, `--config`, and `--dry-run`.

### `claude-docker cleanup <task-name>`

Removes the worktree. The branch is preserved unless `--delete-branch` is passed.

### `claude-docker list`

Lists active git worktrees.

### `claude-docker login`

Runs `claude login` inside a container to authenticate.

## Docker Images

Pre-built images are available on GitHub Container Registry:

| Stack | Image |
|-------|-------|
| Node | `ghcr.io/hansvd/claude-docker-node` |
| Java | `ghcr.io/hansvd/claude-docker-java` |
| Python | `ghcr.io/hansvd/claude-docker-python` |

All images include: Node 20, Claude CLI, Playwright + Chromium, git, jq, and common Claude plugins.

## Guard Hooks

Guard hooks are generated at container startup from your config and registered in Claude Code's settings. They enforce:

- **Branch guard**: Restricts git operations to branches matching the configured prefix (default `ai-tasks/*`). Blocks checkout, push, and destructive operations on other branches.
- **File guard**: Blocks Read/Edit/Write/Bash access to files matching protected patterns and paths.

Disable with `--no-hooks` for unrestricted access.

## Persistent State

- `~/.agent-home` — Claude CLI config, plugins, and settings (shared across tasks)
- `~/.ssh` — SSH keys mounted read-only for git operations
- `.claude-workspaces/` — Git worktrees (add to `.gitignore`, or relocate via `workspaces-dir` / `--workspaces-dir`)
