#!/usr/bin/env bash
set -euo pipefail

# E2E Test Orchestrator
# Sets up a fully mocked environment, then drops you into a real exomonad init
# tmux session where all GitHub interactions hit mocks instead of real APIs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Phase 0: Preconditions ---

echo ">>> [Phase 0] Checking preconditions..."

EXOMONAD_BIN=""
if command -v exomonad &>/dev/null; then
    EXOMONAD_BIN="$(command -v exomonad)"
elif [[ -x "$PROJECT_ROOT/target/debug/exomonad" ]]; then
    EXOMONAD_BIN="$PROJECT_ROOT/target/debug/exomonad"
else
    echo "ERROR: exomonad binary not found. Run 'just install-all-dev' or 'cargo build -p exomonad'."
    exit 1
fi
echo "  exomonad: $EXOMONAD_BIN"

if [[ ! -d "$PROJECT_ROOT/.exo/wasm" ]] || ! ls "$PROJECT_ROOT/.exo/wasm/"wasm-guest-*.wasm &>/dev/null; then
    echo "ERROR: No WASM plugins found in $PROJECT_ROOT/.exo/wasm/. Run 'just wasm-all'."
    exit 1
fi
echo "  WASM: $(ls "$PROJECT_ROOT/.exo/wasm/"wasm-guest-*.wasm)"

for cmd in tmux python3 git; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd not found in PATH."
        exit 1
    fi
done
echo "  tmux, python3, git: OK"

# --- Phase 1: Create temp environment ---

echo ">>> [Phase 1] Creating temp environment..."

WORK_DIR="$(mktemp -d /tmp/exomonad-e2e.XXXXXXXX)"
echo "  Work dir: $WORK_DIR"

MOCK_PID=""
cleanup() {
    echo ""
    echo ">>> [Cleanup] Tearing down..."
    if [[ -n "$MOCK_PID" ]] && kill -0 "$MOCK_PID" 2>/dev/null; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
        echo "  Killed mock GitHub API (PID $MOCK_PID)"
    fi
    # Clean up tmux global env vars
    for var in GITHUB_API_URL MOCK_LOG GH_MOCK_LOG REMOTE_DIR MOCK_PORT E2E_SCRIPT_DIR; do
        tmux set-environment -gu "$var" 2>/dev/null || true
    done
    tmux kill-session -t e2e-test 2>/dev/null || true
    echo "  Killed tmux session"
    rm -rf "$WORK_DIR"
    echo "  Removed $WORK_DIR"
    echo ">>> Done."
}
trap cleanup EXIT

# Create bare remote for push/fetch
REMOTE_DIR="$WORK_DIR/remote.git"
git init --bare "$REMOTE_DIR" -q

# Create working repo
REPO_DIR="$WORK_DIR/repo"
mkdir -p "$REPO_DIR"
cd "$REPO_DIR"
git init -q -b main
git remote add origin "$REMOTE_DIR"

# Initial commit + push
git commit --allow-empty -m "initial commit" -q
git push -u origin main -q

# Bootstrap via exomonad new — generates .exo/config.toml, .gitignore, copies WASM + rules
"$EXOMONAD_BIN" new 2>&1 | sed 's/^/  /' || true

# Symlink WASM from project (overwrite whatever new copied — symlinks save disk)
mkdir -p .exo/wasm
for wasm_file in "$PROJECT_ROOT/.exo/wasm/"wasm-guest-*.wasm; do
    ln -sf "$wasm_file" ".exo/wasm/$(basename "$wasm_file")"
done

# Patch config: use bash instead of nix develop (temp env has no flake.nix)
if [[ -f .exo/config.toml ]]; then
    # Append/override shell_command
    if grep -q 'shell_command' .exo/config.toml; then
        sed -i 's|^shell_command.*|shell_command = "bash"|' .exo/config.toml
    else
        echo 'shell_command = "bash"' >> .exo/config.toml
    fi
else
    cat > .exo/config.toml <<'EOF'
default_role = "devswarm"
wasm_name = "devswarm"
shell_command = "bash"
EOF
fi

# Set session name, root TL model, poller interval, and companion config
cat >> .exo/config.toml <<'EOF'
tmux_session = "e2e-test"
model = "sonnet"
yolo = true
poll_interval = 10

[[companions]]
name = "test-runner"
agent_type = "claude"
role = "testrunner"
model = "haiku"
command = "claude --dangerously-skip-permissions"
task = "Execute the test plan from your role context. Start immediately."
EOF

# Create e2e test mode rule for the root TL
mkdir -p .claude/rules
cat > .claude/rules/e2e-test.md <<'EOF'
# E2E Test Mode — Root TL Protocol

You are the ROOT TECH LEAD in E2E test mode. A test-runner companion will send you instructions via Teams inbox.

## Your Role
- Use `fork_wave` to spawn parallel Claude subtrees (sub-TLs in own worktrees)
- Use `spawn_gemini` to spawn parallel Gemini leaves (in own worktrees, file PRs)
- Use `spawn_worker` to spawn ephemeral Gemini workers (no branch, no PR)
- Merge child PRs with `merge_pr` when you receive notifications
- IDLE between spawning and receiving notifications — do not poll or investigate

## How fork_wave Works
`fork_wave` creates Claude agents in their own git worktrees. Each child:
1. Gets its own branch (main.{slug})
2. Inherits your conversation context (they know the task)
3. Has TL-role tools (file_pr, notify_parent, etc.)
4. Works independently — implements, commits, pushes, files PR

You do NOT need to scaffold code before forking. The children are Claude — they read CLAUDE.md and figure it out.

## NEVER Do These Things
- NEVER run `gh pr create` or `gh` commands — all GitHub operations go through MCP tools (`file_pr`, `merge_pr`)
- NEVER curl the server socket directly — use MCP tools only
- NEVER debug a child agent's failure by reading files or investigating — note the failure and re-decompose
- NEVER do work that belongs to a child agent (writing code, filing PRs for children)
- NEVER take on a child's identity or act on behalf of a child

## When a Child Reports Failure
A `[from: child-id]` message means the child is reporting status TO YOU. You are the parent, not the child.
If a child says "PR filing failed": wait for the child to retry, or re-spawn a new child. Do NOT try to file the PR yourself.

## Notification Vocabulary
- `[from: id] ...` — status report from child. Read it. Do not act AS the child.
- `[PR READY]` — Copilot approved. Merge with `merge_pr`.
- `[FIXES PUSHED]` — child addressed review. Merge if CI passes.
- `[REVIEW TIMEOUT]` — no review after timeout. Merge if CI passes.
- `[FAILED: id]` — child exhausted retries. Re-decompose or escalate.
EOF

echo "  Repo: $REPO_DIR"
echo "  Remote: $REMOTE_DIR"

# --- Phase 2: Start mock GitHub API ---

echo ">>> [Phase 2] Starting mock GitHub API..."

# Pick ephemeral port
MOCK_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
export MOCK_LOG="$WORK_DIR/mock_github.log"

REMOTE_DIR="$REMOTE_DIR" MOCK_LOG="$MOCK_LOG" python3 "$SCRIPT_DIR/mock_github.py" --port "$MOCK_PORT" &
MOCK_PID=$!

# Poll until responsive
for i in $(seq 1 20); do
    if curl -sf "http://127.0.0.1:$MOCK_PORT/repos/test/repo/pulls" &>/dev/null; then
        echo "  Mock GitHub API listening on port $MOCK_PORT (PID $MOCK_PID)"
        break
    fi
    if [[ $i -eq 20 ]]; then
        echo "ERROR: Mock GitHub API failed to start."
        exit 1
    fi
    sleep 0.25
done

# --- Phase 3: Set environment ---

echo ">>> [Phase 3] Configuring environment..."

export PATH="$SCRIPT_DIR:$PATH"
export GITHUB_TOKEN="test-token-e2e"
export GITHUB_API_URL="http://127.0.0.1:$MOCK_PORT"
export GH_MOCK_LOG="$WORK_DIR/gh_mock.log"

# Set tmux global env vars so companion windows inherit them
tmux set-environment -g GITHUB_API_URL "http://127.0.0.1:$MOCK_PORT"
tmux set-environment -g MOCK_LOG "$MOCK_LOG"
tmux set-environment -g GH_MOCK_LOG "$GH_MOCK_LOG"
tmux set-environment -g REMOTE_DIR "$REMOTE_DIR"
tmux set-environment -g MOCK_PORT "$MOCK_PORT"
tmux set-environment -g E2E_SCRIPT_DIR "$SCRIPT_DIR"

echo "  PATH prepended with: $SCRIPT_DIR (mock_gh)"
echo "  GITHUB_TOKEN=test-token-e2e"
echo "  GITHUB_API_URL=http://127.0.0.1:$MOCK_PORT"
echo "  GH_MOCK_LOG=$GH_MOCK_LOG"
echo "  MOCK_LOG=$MOCK_LOG"
echo "  REMOTE_DIR=$REMOTE_DIR"

# --- Phase 4: Run exomonad init ---

echo ">>> [Phase 4] Launching exomonad init..."

# Copy helper scripts into repo for convenience
cp "$SCRIPT_DIR/validate.sh" "$WORK_DIR/repo/validate.sh" 2>/dev/null || true
cp "$SCRIPT_DIR/post_review.sh" "$WORK_DIR/repo/post_review.sh" 2>/dev/null || true

echo ""
echo "============================================"
echo "  E2E Environment Ready"
echo "  Session: e2e-test"
echo "  Work dir: $WORK_DIR/repo"
echo "  Mock GitHub: http://127.0.0.1:$MOCK_PORT"
echo "  Mock log: $MOCK_LOG"
echo "  GH mock log: $GH_MOCK_LOG"
echo "  Remote dir: $REMOTE_DIR"
echo ""
echo "  Run ./validate.sh from the TL window"
echo "  to verify the pipeline."
echo "============================================"
echo ""

# Launch exomonad init — creates tmux session and attaches
"$EXOMONAD_BIN" init --session e2e-test
