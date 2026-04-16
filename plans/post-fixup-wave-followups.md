# Post-Fixup-Wave Followups

Four items surfaced by or left over from the 2026-04-16 fixup wave. Not urgent enough to have blocked the wave, but each is small and high-signal. Spec them as one parallel Gemini wave once the server is restarted with the wave's fixes live.

## 1. Poller treats Copilot `COMMENTED` reviews as no-review

### Problem

Every PR in the wave hit `[REVIEW TIMEOUT]` even though Copilot reviewed 12 of 13 of them. Reason: Copilot leaves `state=COMMENTED` (summary body + inline comments) rather than `APPROVED` or `CHANGES_REQUESTED`. The GitHub poller's state machine in `rust/exomonad-core/src/services/github_poller.rs` only handles the approve/changes branches, so `COMMENTED` falls into the "no review yet" bucket. Result: 20+ actionable inline comments silently discarded across the wave, timeout forces a `force-merge`, feedback gone.

### Scope

Teach the poller that `COMMENTED` + non-empty inline-comment list means "review received, changes requested by implication." Fire the existing `PRReview::ReviewReceived` → `InjectMessage` path so the comments land in the leaf's pane. The leaf already knows how to handle that input.

### Change sites

- `rust/exomonad-core/src/services/github_poller.rs` — `compute_pr_actions` / wherever it currently branches on `review_state`. Add a `COMMENTED` case that maps to `ReviewState::ChangesRequested` when inline comments exist. If no inline comments and the summary is purely informational, keep mapping to `None` (preserves the timeout fallback for empty reviews).
- `rust/exomonad-core/src/services/copilot_review.rs` — same mapping if duplicated there.
- Tests: one unit test per mapping branch (`COMMENTED` + inline comments → `ReviewReceived`; `COMMENTED` + no inline comments → `None`; `APPROVED` and `CHANGES_REQUESTED` unchanged). Live fixture lives in `tests/fixtures/copilot-reviews/` if helpful.

### Anti-patterns

- DO NOT treat every `COMMENTED` review as `CHANGES_REQUESTED` — Copilot sometimes leaves purely-informational summaries. The inline-comment count is the actionable signal.
- DO NOT rework the `PRReview` event taxonomy. Just reuse `ReviewReceived`.

### Verify

```
cargo test -p exomonad-core --lib services::github_poller
cargo test -p exomonad-core --lib services::copilot_review
cargo clippy -p exomonad-core -- -D warnings
```

## 2. Post-hoc recovery of Copilot feedback on wave PRs

### Problem

The 13 PRs merged in the wave (see [Wave PRs](#wave-prs) below) silently dropped ~20 actionable Copilot comments. The changes are already in `main` but the feedback may point to real gaps.

### Scope

Pull all `COMMENTED` reviews + inline comments for the wave's PRs into one consolidated report at `docs/post-wave-copilot-audit-2026-04-16.md`. One section per PR: summary excerpt + each inline comment (file:line + text). Triage each as `action-needed` / `informational` / `already-addressed-by-other-PR`.

This is a research task, not a fix — deliverable is the audit doc. Any actionable findings become separate follow-up PRs or go into the relevant sub-TL's backlog.

### Data source

```
gh api repos/tidepool-heavy-industries/exomonad/pulls/{num}/reviews
gh api repos/tidepool-heavy-industries/exomonad/pulls/{num}/comments
```

### Wave PRs

`854, 855, 856, 857, 858, 860, 861, 862, 863, 864, 865, 866, 867, 868, 869`

### Verify

Doc exists, covers every PR, each comment has a triage verdict. No code changes expected.

## 3. `fork_wave` / `merge_pr` upstream tracking

### Problem

Fresh branches from `fork_wave` don't have `origin/<branch>` tracking set. Post-merge `git pull` inside `merge_pr` fails with "no tracking information for the current branch." `registries-tl` had to `git branch --set-upstream-to` manually twice during its wave. The registries-tl TL's honest-reporting fix from #849 is what caught this — previously it silently failed.

### Scope

Set upstream tracking at spawn time. Cleanest: `fork_wave` pushes the new branch and runs `git branch --set-upstream-to=origin/<branch>` in the worktree. Alternative: `merge_pr` does it lazily before pulling. Both are ~one line but the first is better — every branch gets tracking from birth, not just ones that end up merging.

### Change sites

- `rust/exomonad-core/src/services/agent_control/spawn.rs` or wherever `fork_wave` creates the worktree and initial push. After `git push -u origin HEAD` (which already sets upstream), verify it happened; if using `git push` without `-u`, add the flag.
- Add a regression test: spawn a child in a temp repo, assert `git rev-parse --abbrev-ref --symbolic-full-name @{upstream}` returns a non-error.

### Anti-patterns

- DO NOT do both fork_wave-side and merge_pr-side — pick one and own it. Double-handling causes the "works locally, mysteriously broken elsewhere" class of bug.

### Verify

```
cargo test -p exomonad-core --lib services::agent_control
# Spot-check: spawn a test child, confirm upstream is set
```

## 4. Remaining `"model": "gemini"` hardcode in reconcile path

### Problem

`rust/claude-teams-bridge/src/registry.rs:284` still hardcodes `"model": "gemini"` and `"agentType": "exomonad-agent"` when it reconciles in-memory state into config.json (bonus finding from the registries-tl audit). Fires when an in-memory `register_team` call adds a member before `synthetic_members.rs` has written the honest type — rare race.

messaging-tl explicitly deferred this because the proper fix requires extending `TeamInfo` to carry agent_type/model and threading it through the `register_team` effect proto. Non-trivial vs the other reconcile-path fixes.

### Scope

Extend `TeamInfo` (in `rust/claude-teams-bridge/src/registry.rs`) to carry `agent_type: AgentType` and `model: String` fields. Thread through:

- `proto/effects/session.proto` — `RegisterTeamRequest` gains `agent_type: AgentType` (enum, matching the Rust AgentType) and `model: String`.
- Haskell guest (`haskell/wasm-guest/src/ExoMonad/Guest/Effects/Session.hs`) — callers of `registerTeam` pass their role's type.
- `rust/exomonad-core/src/handlers/session.rs::register_team` — accepts the new fields, stores them in `TeamInfo`.
- `rust/claude-teams-bridge/src/registry.rs:284` — uses the stored values instead of the hardcoded strings.

### Anti-patterns

- DO NOT add a second `register_team_with_type` variant. Either the one call carries the fields or it doesn't.
- Remember to regen Rust proto (`cargo build -p exomonad-proto`) AND Haskell proto (`just proto-gen-haskell`). Gemini historically forgets the Haskell side.

### Verify

```
just proto-gen-haskell
cargo build -p exomonad-proto
cargo test --workspace --lib
# WASM rebuild
just wasm-all
```

## Execution

All four are independent — spawn as a single Gemini wave after server restart:

| Leaf | Item | Effort |
|------|------|--------|
| `poller-commented-state-gemini` | #1 | small (~30 lines + tests) |
| `copilot-feedback-audit-worker` | #2 | medium (research, no code) — use `spawn_worker` (ephemeral), not `spawn_gemini` |
| `fork-wave-upstream-gemini` | #3 | small |
| `register-team-honest-type-gemini` | #4 | medium (proto changes) |

Item #1 is the highest ROI — it stops every future wave from bleeding Copilot feedback. Prioritize if doing them sequentially.
