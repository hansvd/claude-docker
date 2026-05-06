#!/bin/bash
set -e

# ---------------------------------------------------------------------------
# claude-docker entrypoint
#
# Generates guard hooks from environment variables at container startup,
# registers them in Claude Code's settings.json, and restores the original
# settings on exit.
#
# Environment variables (set by the CLI):
#   WORKTREE_PATH                    - path to the git worktree
#   CLAUDE_DOCKER_TASK_NAME          - task name (for display / session context)
#   CLAUDE_DOCKER_BRANCH_PREFIX      - branch prefix to enforce (default: ai-tasks/)
#   CLAUDE_DOCKER_PROTECTED_FILES    - comma-separated glob patterns to block
#   CLAUDE_DOCKER_PROTECTED_PATHS    - comma-separated directory prefixes to block
#   CLAUDE_DOCKER_NO_HOOKS           - set to 1 to skip hook generation
#   CLAUDE_DOCKER_AUTO_UPDATE        - set to 0 to skip Claude auto-update (default: on)
#   CLAUDE_DOCKER_SETUP_SCRIPT       - absolute path inside container; runs before Claude
#
# Optional read-only mount:
#   /opt/host-claude-settings.json   - host's ~/.claude/settings.json. When
#                                      present, enabledPlugins is synced into
#                                      ~/.claude/settings.json and missing
#                                      plugins are installed.
# ---------------------------------------------------------------------------

HOOKS_DIR="$HOME/.claude-docker-hooks"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOOKS_DIR"

# --- Cleanup: restore original settings.json on exit ---
cleanup() {
    if [ -n "${ORIG_SETTINGS:-}" ]; then
        echo "$ORIG_SETTINGS" > "$CLAUDE_SETTINGS"
    fi
}
trap cleanup EXIT

# --- Mark worktree as safe for git ---
if [ -n "${WORKTREE_PATH:-}" ]; then
    git config --global --add safe.directory "$WORKTREE_PATH"
fi

# --- Update Claude to the latest release (unless disabled) ---
if [ "${CLAUDE_DOCKER_AUTO_UPDATE:-1}" = "1" ]; then
    if curl -fsSL --max-time 30 https://claude.ai/install.sh | bash >/dev/null 2>&1; then
        echo "claude-docker: updated Claude in $HOME/.local/bin"
    else
        echo "claude-docker: Claude update skipped (network error) — using image binary" >&2
    fi
fi
export PATH="$HOME/.local/bin:$PATH"

# --- Sync host ~/.claude/settings.json plugins (if mounted) ---
# Mounted read-only at /opt/host-claude-settings.json by the CLI when the host
# has a ~/.claude/settings.json. We install any missing plugins into
# ~/.agent-home/.claude/plugins/ (idempotent — fast no-op for already-present
# plugins) and merge enabledPlugins into the container settings file. Runs
# before the later settings backup so the merged enabledPlugins survives the
# EXIT-trap restore.
HOST_SETTINGS=/opt/host-claude-settings.json
if [ -f "$HOST_SETTINGS" ]; then
    mkdir -p "$HOME/.claude"
    [ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"

    # Marketplace ID -> source mapping. Extend here if the user enables
    # plugins from other marketplaces.
    declare -A MARKETPLACE_SRC=(
        [claude-plugins-official]=anthropics/claude-plugins-official
    )

    mapfile -t HOST_PLUGINS < <(jq -r '.enabledPlugins // {} | to_entries[] | select(.value==true) | .key' "$HOST_SETTINGS" 2>/dev/null || true)

    if [ "${#HOST_PLUGINS[@]}" -gt 0 ]; then
        echo "claude-docker: syncing ${#HOST_PLUGINS[@]} plugin(s) from host ~/.claude/settings.json"

        declare -A SEEN_MP
        for entry in "${HOST_PLUGINS[@]}"; do
            mp="${entry##*@}"
            [ -n "${SEEN_MP[$mp]:-}" ] && continue
            SEEN_MP[$mp]=1
            src="${MARKETPLACE_SRC[$mp]:-}"
            if [ -z "$src" ]; then
                echo "claude-docker: skipping plugins from unknown marketplace '$mp'" >&2
                continue
            fi
            claude plugin marketplace add "$src" >/dev/null 2>&1 || true
        done

        for entry in "${HOST_PLUGINS[@]}"; do
            mp="${entry##*@}"
            [ -n "${MARKETPLACE_SRC[$mp]:-}" ] || continue
            if ! claude plugin install "$entry" >/dev/null 2>&1; then
                echo "claude-docker: plugin install failed for $entry" >&2
            fi
        done

        # Merge enabledPlugins from host file into container settings file.
        if jq --slurpfile host "$HOST_SETTINGS" \
              '.enabledPlugins = ($host[0].enabledPlugins // {})' \
              "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp" 2>/dev/null; then
            mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
        else
            rm -f "$CLAUDE_SETTINGS.tmp"
            echo "claude-docker: failed to merge enabledPlugins into $CLAUDE_SETTINGS" >&2
        fi
    fi
fi

# --- Run per-task setup script (after Claude update, before hook generation) ---
if [ -n "${CLAUDE_DOCKER_SETUP_SCRIPT:-}" ]; then
    if [ ! -f "$CLAUDE_DOCKER_SETUP_SCRIPT" ]; then
        echo "claude-docker: setup script not found in container: $CLAUDE_DOCKER_SETUP_SCRIPT" >&2
        exit 1
    fi
    echo "claude-docker: running setup script $CLAUDE_DOCKER_SETUP_SCRIPT"
    pushd "${WORKTREE_PATH:-$(pwd)}" >/dev/null
    if ! bash "$CLAUDE_DOCKER_SETUP_SCRIPT"; then
        rc=$?
        echo "claude-docker: setup script failed (exit $rc); aborting before Claude launch" >&2
        exit $rc
    fi
    popd >/dev/null
    echo "claude-docker: setup script completed"
fi

# --- Skip hook generation if disabled ---
if [ "${CLAUDE_DOCKER_NO_HOOKS:-}" = "1" ]; then
    bash -c "$@"
    exit $?
fi

PREFIX="${CLAUDE_DOCKER_BRANCH_PREFIX:-ai-tasks/}"

# ---------------------------------------------------------------------------
# Generate branch-guard.sh
# ---------------------------------------------------------------------------
cat > "$HOOKS_DIR/branch-guard.sh" << 'HOOKEOF'
#!/bin/bash
# Auto-generated by claude-docker entrypoint. Do not edit.
[ -z "$CLAUDE_DOCKER" ] && exit 0

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$COMMAND" ] && exit 0
echo "$COMMAND" | grep -q '^git ' || exit 0

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
PREFIX="__PREFIX__"

deny() {
  jq -n --arg reason "$1" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $reason
    }
  }'
  exit 0
}

# Block checkout/switch to branches outside the allowed prefix
if echo "$COMMAND" | grep -qE '^git (checkout|switch)'; then
  if echo "$COMMAND" | grep -qE "^git (checkout|switch) (-b )?${PREFIX}"; then
    exit 0
  fi
  if echo "$COMMAND" | grep -qE '^git checkout --'; then
    exit 0
  fi
  if echo "$COMMAND" | grep -qE '^git (checkout|switch) [^-]'; then
    TARGET=$(echo "$COMMAND" | sed -E 's/^git (checkout|switch) //')
    if [[ ! "$TARGET" =~ ^${PREFIX} ]]; then
      deny "Branch restricted: only ${PREFIX}* branches allowed. Attempted: $TARGET"
    fi
  fi
fi

# Block push when not on an allowed branch
if echo "$COMMAND" | grep -q '^git push'; then
  if [[ ! "$CURRENT_BRANCH" =~ ^${PREFIX} ]]; then
    deny "Push blocked: not on a ${PREFIX}* branch (current: $CURRENT_BRANCH)"
  fi
fi

# Block destructive operations outside allowed prefix
if echo "$COMMAND" | grep -qE '^git (reset|merge|rebase)'; then
  if [[ ! "$CURRENT_BRANCH" =~ ^${PREFIX} ]]; then
    deny "Destructive git operation blocked: not on a ${PREFIX}* branch (current: $CURRENT_BRANCH)"
  fi
fi

# Block branch deletion
if echo "$COMMAND" | grep -qE '^git branch -[dD]'; then
  deny "Branch deletion blocked. Manage branch cleanup manually."
fi

exit 0
HOOKEOF

sed -i "s|__PREFIX__|${PREFIX}|g" "$HOOKS_DIR/branch-guard.sh"
chmod +x "$HOOKS_DIR/branch-guard.sh"

# ---------------------------------------------------------------------------
# Generate file-guard.sh (only if patterns are configured)
# ---------------------------------------------------------------------------
HOOKS_JSON='[]'
HOOKS_JSON=$(echo "$HOOKS_JSON" | jq --arg cmd "$HOOKS_DIR/branch-guard.sh" '. + [{"type":"command","command":$cmd}]')

if [ -n "${CLAUDE_DOCKER_PROTECTED_FILES:-}" ] || [ -n "${CLAUDE_DOCKER_PROTECTED_PATHS:-}" ]; then

cat > "$HOOKS_DIR/file-guard.sh" << 'HOOKEOF'
#!/bin/bash
# Auto-generated by claude-docker entrypoint. Do not edit.
[ -z "$CLAUDE_DOCKER" ] && exit 0

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Extract the relevant path/command based on tool type
case "$TOOL" in
  Read|Edit|Write)
    TARGET=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    ;;
  Bash)
    TARGET=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
    ;;
  *)
    exit 0
    ;;
esac

[ -z "$TARGET" ] && exit 0

deny() {
  jq -n --arg reason "$1" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $reason
    }
  }'
  exit 0
}

# Check protected paths
IFS=',' read -ra PATHS <<< "__PROTECTED_PATHS__"
for p in "${PATHS[@]}"; do
  [ -z "$p" ] && continue
  if echo "$TARGET" | grep -q "$p"; then
    deny "Access denied: $p is a protected path."
  fi
done

# Check protected file patterns
IFS=',' read -ra PATTERNS <<< "__PROTECTED_FILES__"
for pattern in "${PATTERNS[@]}"; do
  [ -z "$pattern" ] && continue
  # For file tools, match against the basename
  if [ "$TOOL" = "Read" ] || [ "$TOOL" = "Edit" ] || [ "$TOOL" = "Write" ]; then
    BASENAME=$(basename "$TARGET")
    if [[ "$BASENAME" == $pattern ]]; then
      deny "Access denied: files matching '$pattern' are protected."
    fi
  else
    # For Bash, check if the pattern appears in the command
    if echo "$TARGET" | grep -qE "$pattern"; then
      deny "Access denied: commands referencing '$pattern' are blocked."
    fi
  fi
done

exit 0
HOOKEOF

sed -i "s|__PROTECTED_FILES__|${CLAUDE_DOCKER_PROTECTED_FILES:-}|g" "$HOOKS_DIR/file-guard.sh"
sed -i "s|__PROTECTED_PATHS__|${CLAUDE_DOCKER_PROTECTED_PATHS:-}|g" "$HOOKS_DIR/file-guard.sh"
chmod +x "$HOOKS_DIR/file-guard.sh"

HOOKS_JSON=$(echo "$HOOKS_JSON" | jq --arg cmd "$HOOKS_DIR/file-guard.sh" '. + [{"type":"command","command":$cmd}]')
fi

# ---------------------------------------------------------------------------
# Register hooks in Claude Code settings.json
# ---------------------------------------------------------------------------
mkdir -p "$HOME/.claude"
if [ -f "$CLAUDE_SETTINGS" ]; then
    ORIG_SETTINGS=$(cat "$CLAUDE_SETTINGS")
else
    ORIG_SETTINGS='{}'
fi

echo "$ORIG_SETTINGS" | jq --argjson hooks "$HOOKS_JSON" \
  '.hooks.PreToolUse = [{"hooks": $hooks}]' > "$CLAUDE_SETTINGS"

# Run the command as a child process so the EXIT trap fires on container stop
bash -c "$@"
