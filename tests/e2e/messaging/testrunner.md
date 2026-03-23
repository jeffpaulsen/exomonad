# Messaging E2E Test Plan

You are an E2E test runner companion. This test validates Teams inbox message delivery through the full MCP stack: `.mcp.json` → `mcp-stdio` → UDS → WASM `send_message` handler → Rust `EventHandler` → `teams_mailbox::write_to_inbox` → CC InboxPoller → `<teammate-message>`.

## Hard Rules

1. **NEVER call server endpoints directly.** No `curl --unix-socket`, no direct HTTP requests to `.exo/server.sock`.
2. **NEVER create branches, files, or PRs yourself.** No git operations beyond read-only observation.
3. **NEVER use MCP tools other than `instruct` and `notify_parent`.** You do not have orchestration tools.
4. **Root does nothing in this test.** You are testing message delivery, not orchestration. Root just creates a team and idles.

## Available MCP Tools

- **`instruct`** — Send a message to the root TL (wraps `send_message` through full MCP pipeline)
- **`notify_parent`** — Report results to the human operator

## Allowed Bash (Read-Only Observation)

- `ls ~/.claude/teams/` — Check team directories
- `ls ~/.claude/teams/*/inboxes/` — Check inbox files
- `cat ~/.claude/teams/*/inboxes/*.json` — Read inbox contents
- `tmux list-windows -t $EXOMONAD_TMUX_SESSION` — Check session windows

## Test Plan: Teams Inbox Message Delivery

```
Test Runner (you)
├── [Step 1] Wait for root TL to create team
├── [Step 2] instruct: basic delivery test
├── [Step 3] instruct: ordering test (second message)
├── [Step 4] instruct: special characters test
├── [Step 5] notify_parent: parent resolution test
└── [Step 6] Report results
```

This exercises: `instruct` (send_message through full WASM→Rust→Teams pipeline), `notify_parent` (parent resolution + inbox routing), content fidelity (special characters through WASM↔Rust↔JSON), and message ordering.

---

### Phase 0: Wait for team creation

Poll every 5 seconds, max 90 seconds. Check:
- `ls ~/.claude/teams/` — wait for a team directory to appear
- `tmux list-windows -t $EXOMONAD_TMUX_SESSION` — confirm TL window exists

The root TL should create a team automatically (it's in its rules). Once a team directory exists, proceed.

---

### Phase 1: Basic message delivery

#### Step 1.1: Send first message

Use `instruct` to send:

"[E2E-MSG-1] Basic delivery test. This message validates the full MCP pipeline: WASM send_message → Rust EventHandler → teams_mailbox → InboxPoller."

**Validation:** Check that `instruct` returned successfully (no error in the tool result). Log the delivery method if reported.

#### Step 1.2: Send second message (ordering)

Wait 3 seconds, then use `instruct` to send:

"[E2E-MSG-2] Second message — ordering test. This should arrive after MSG-1."

**Validation:** Check that `instruct` returned successfully.

#### Step 1.3: Send message with special characters

Wait 3 seconds, then use `instruct` to send:

"[E2E-MSG-3] Special chars: \"quotes\" & ampersands <brackets> newline→here émojis:🎯 unicode:λ∀∃"

**Validation:** Check that `instruct` returned successfully. This tests content fidelity through the WASM↔Rust↔JSON serialization pipeline.

---

### Phase 2: notify_parent delivery

#### Step 2.1: Send via notify_parent

Use `notify_parent` with:
- `status`: "success"
- `message`: "[E2E-MSG-4] notify_parent delivery test. This validates parent resolution + inbox routing."

**Validation:** Check that `notify_parent` returned successfully.

---

### Phase 3: Verify inbox state

#### Step 3.1: Check inbox files

After all messages sent, check the inbox state:
- `ls ~/.claude/teams/*/inboxes/` — inbox files should exist
- Count the number of inbox entries

This is observational — the primary validation is that all tool calls succeeded without errors.

---

### Step Final: Report

Call `notify_parent` with:
- `status`: "success" or "failure"
- `message`: Structured summary:

  **Message Delivery Results:**
  - MSG-1 (basic delivery): instruct succeeded? delivery method?
  - MSG-2 (ordering): instruct succeeded?
  - MSG-3 (special chars): instruct succeeded? content preserved?
  - MSG-4 (notify_parent): notify_parent succeeded?

  **Inbox State:**
  - Team directory found?
  - Inbox files present?
  - Total messages in inbox?

  **Overall:** N/4 messages delivered successfully. Pass/Fail.

Do NOT try to fix problems yourself. Observe and report only.
