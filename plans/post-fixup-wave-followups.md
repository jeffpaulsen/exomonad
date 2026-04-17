# Capability-Driven Honest-Typed Delivery Pipeline

## Context

Today's investigation traced a class of silent message-delivery failures back to two complementary structural flaws in `rust/exomonad-core/src/services/delivery.rs`:

1. **Recipient-agnostic priority chain.** `deliver_to_agent` tries Teams → ACP → UDS → tmux in a hardcoded order regardless of who the recipient is. For Gemini agents (which don't poll Claude Teams inboxes), the Teams write succeeds, the function returns immediately, and the message is never read. The async 30s verifier's tmux fallback only fires for Tier 1 (in-memory registered) recipients — Gemini leaves are Tier 2 (config.json scan), so the fallback is suppressed by the existing CC-native heuristic.

2. **Dishonest result type.** `DeliveryResult::Teams` is returned the moment the JSON file is written to disk — not when the recipient has read it. Callers (and humans reading their `success: true` response) think delivery happened. Today, every `send_message` from root to a Gemini leaf returned `success: true` but landed in a dead-letter file. The only reason iteration cycles "worked" earlier in the day is that the GitHub poller's event handler injects Copilot review comments via a separate tmux path — my redundant `send_message` summaries were silently dropped, but the leaves had the comments anyway.

PR #873 (just merged) added `agent_type` to `TeamInfo`. That data is the missing input both flaws need. This plan unifies fixes for both via a capability-driven plan + honest-typed result.

## Design

Two refactors landed together. They share an integration point (`execute_plan`), so doing them in one wave is less churn than sequencing.

### New types

```rust
enum DeliveryChannel { Teams, Acp, Uds, Tmux }

enum ChannelOutcome {
    Confirmed,                              // synchronous proof of receipt
    Queued(oneshot::Receiver<VerifyOutcome>), // async verification (Teams only)
    Failed(String),
}

enum DeliveryResult {
    Confirmed(DeliveryChannel),
    QueuedUnverified(DeliveryChannel, oneshot::Receiver<VerifyOutcome>),
    Failed(FailureReason),
}

struct RecipientMeta {
    agent_type: AgentType,    // Claude / Gemini / Shoal / Process
    backend_type: BackendType, // Exomonad / CcNative
}
```

### Pure policy: `delivery_plan`

```rust
fn delivery_plan(recipient: &RecipientMeta) -> Vec<DeliveryChannel> {
    match (recipient.agent_type, recipient.backend_type) {
        (Claude,  Exomonad) => vec![Teams, Tmux],   // CC reads Teams; tmux fallback
        (Claude,  CcNative) => vec![Teams],          // CC-native: no exomonad worktree, no tmux
        (Gemini,  Exomonad) => vec![Acp, Tmux],     // Gemini: no Teams (no poller); ACP if connected else tmux
        (Gemini,  CcNative) => vec![],               // unreachable in practice; explicit Undeliverable
        (Shoal,   Exomonad) => vec![Uds, Tmux],     // Shoal: HTTP-over-UDS primary
        (Shoal,   CcNative) => vec![],
        (Process, _)        => vec![],               // processes don't receive messages
    }
}
```

This is the **single source of truth** for "who can receive on what." Adding a new agent type = adding rows. Compiler enforces exhaustiveness via match.

### Mechanism: `execute_plan`

```rust
async fn execute_plan(
    plan: Vec<DeliveryChannel>,
    ctx: &(impl Has*),
    /* other args */,
) -> DeliveryResult {
    for channel in plan {
        match try_channel(channel, ctx, ...).await {
            Ok(ChannelOutcome::Confirmed)   => return DeliveryResult::Confirmed(channel),
            Ok(ChannelOutcome::Queued(rx))  => return DeliveryResult::QueuedUnverified(channel, rx),
            Err(_)                          => continue,
        }
    }
    DeliveryResult::Failed(FailureReason::AllChannelsExhausted)
}
```

`try_channel` dispatches to per-channel helpers (`try_teams_channel`, `try_acp_channel`, `try_uds_channel`, `try_tmux_channel`). Each returns honest outcome:
- `try_teams_channel`: writes to inbox, returns `Queued(rx)` carrying the verifier's oneshot
- `try_acp_channel`: prompts via ACP, returns `Confirmed` on ack
- `try_uds_channel`: POSTs over UDS, returns `Confirmed` on 2xx
- `try_tmux_channel`: injects via tmux, returns `Confirmed` on successful inject

### Caller contract

`deliver_to_agent` is renamed `route_to_recipient` (or kept as a thin wrapper for migration ease) and returns the new `DeliveryResult`. Callers pattern-match:
- `notify_parent_delivery`: fire-and-forget — log all three variants, treat `Confirmed` and `QueuedUnverified` as success-paths, `Failed` as failure
- `send_message` MCP handler: same — but the response to the calling agent now distinguishes "Confirmed via X" vs "Queued (delivery unverified)" so callers don't get a false-positive

## Wave Plan (Sub-TL: `delivery-refactor`)

Spawned as a Claude sub-TL via `fork_wave` (depth-2 makes sense given the cross-cutting scope). Sub-TL runs scaffold-fork-converge.

### Scaffold commit (sub-TL writes)

Adds new type definitions to `rust/exomonad-core/src/services/delivery.rs` ALONGSIDE existing types (don't break anything yet):

```rust
// New, unused yet:
enum DeliveryChannel { ... }
enum ChannelOutcome { ... }
enum NewDeliveryResult { ... }  // temporarily named
enum FailureReason { ... }
struct RecipientMeta { ... }
fn delivery_plan(...) -> Vec<DeliveryChannel> { todo!() }  // stub
```

Commit + push. Children fork from here — they all see the agreed-upon shapes.

### Wave 1 (parallel Gemini leaves, zero deps)

**Leaf 1: `delivery-plan-pure`**
- Implement `delivery_plan` pure function (the match table above)
- Add a separate `fn channels_recipient_can_receive(meta: &RecipientMeta) -> BTreeSet<DeliveryChannel>` (the inverse view — what channels the recipient CAN read on, derived from agent_type + backend_type)
- Property test: for every `(AgentType, BackendType)` pair, `delivery_plan(meta) ⊆ channels_recipient_can_receive(meta)`. This is the regression-killer — silent dead-letter routing becomes structurally impossible.
- Property test: plan is non-empty for every (agent_type, backend_type) where receivable channels is non-empty.
- Touched: `delivery.rs` only.

**Leaf 2: `execute-plan-channels`**
- Refactor existing per-channel logic in `deliver_to_agent` into 4 functions:
  - `async fn try_teams_channel(ctx, ...) -> Result<ChannelOutcome>` — moves existing Teams write + verifier-spawn into here, returns `Queued(rx)` carrying the verifier's oneshot
  - `async fn try_acp_channel(...) -> Result<ChannelOutcome>` — existing ACP code, returns `Confirmed` on ack
  - `async fn try_uds_channel(...) -> Result<ChannelOutcome>` — existing UDS code
  - `async fn try_tmux_channel(...) -> Result<ChannelOutcome>` — existing tmux code, returns `Confirmed` on inject success
- Implement `execute_plan` (the for-loop above). Calls `try_channel` which dispatches to the 4 helpers via a match on `DeliveryChannel`.
- Unit tests: each `try_channel` helper tested in isolation against IsolatedTmux / mock registries. `execute_plan` tested with synthetic plans that should fall through (e.g., `[Acp, Tmux]` where ACP fails → tmux succeeds).
- Touched: `delivery.rs` only.

### Integration commit (sub-TL writes after Wave 1 merges)

Wires the new pieces together by:
1. Renaming `deliver_to_agent` to a thin compat wrapper that calls `delivery_plan` then `execute_plan`, mapping the new `DeliveryResult` to the old enum variants for transitional caller compatibility.
2. Verifies build green.

### Wave 2 (single Gemini leaf)

**Leaf 3: `caller-migration`**
- Update all callers of `deliver_to_agent` / `notify_parent_delivery` / `route_message` to pattern-match the new `DeliveryResult` directly (no compat wrapper).
- Caller sites (per the audit done in this plan):
  - `rust/exomonad-core/src/handlers/events.rs` — `send_message` and `notify_parent` tool handlers
  - `rust/exomonad-core/src/services/delivery.rs` — `notify_parent_delivery` itself
  - `rust/exomonad-core/src/services/github_poller.rs` — event handler `InjectMessage` and `NotifyParentAction` paths
- Remove the compat wrapper from the integration commit.
- The MCP tool response for `send_message` should now expose `confirmed` / `queued` / `failed` outcomes honestly (Haskell-side may need an enum wrapping, or just a `delivery_method` + `confirmed: bool` pair).
- Touched: `handlers/events.rs`, `services/delivery.rs`, `services/github_poller.rs`. Possibly `haskell/wasm-guest/src/ExoMonad/Guest/Tools/Events.hs` for the response shape.

### Sub-TL files PR to main after Wave 2 merges + integration verified.

## Critical Files

| File | Change |
|------|--------|
| `rust/exomonad-core/src/services/delivery.rs` | All new types + `delivery_plan` + `execute_plan` + per-channel helpers; `deliver_to_agent` rewritten |
| `rust/exomonad-core/src/handlers/events.rs` | Caller migration to new `DeliveryResult` |
| `rust/exomonad-core/src/services/github_poller.rs` | Caller migration |
| `haskell/wasm-guest/src/ExoMonad/Guest/Tools/Events.hs` | Possibly: surface honest delivery status in `send_message` response |

## Anti-Patterns (Spawn Spec Front-Matter)

- **DO NOT** preserve the old `DeliveryResult` enum after caller migration — full removal forces every caller to be updated.
- **DO NOT** add a "if recipient is Gemini, skip Teams" `if` branch anywhere outside `delivery_plan`. The plan function is the single source of truth.
- **DO NOT** make Teams a synchronous-blocking write. The 30s verifier stays async; `try_teams_channel` returns `Queued(rx)` not `Confirmed`.
- **DO NOT** duplicate the receivable-channels table — derive `channels_recipient_can_receive` from `(agent_type, backend_type)` ONCE.
- **DO NOT** widen `RecipientMeta` beyond `agent_type` + `backend_type` without strong justification.

## Verification

```bash
cargo build --workspace
cargo test --workspace --lib
cargo clippy --workspace -- -D warnings

# Per-leaf:
# Leaf 1
cargo test -p exomonad-core --lib services::delivery::plan
# Leaf 2
cargo test -p exomonad-core --lib services::delivery::execute
# Leaf 3 + integration
cargo test -p exomonad-core --lib services::delivery
cargo test -p exomonad-core --lib handlers::events
```

### Live smoke test (run after restart)

1. Spawn a Gemini leaf via `spawn_gemini`.
2. From root: `send_message(recipient=<the-leaf>, content="ping")`.
3. Expect response: `{delivery_method: "tmux", confirmed: true}` (NOT `teams_inbox`).
4. Expect: the leaf actually receives the message in its pane within 1s (NOT 30s+ via verifier fallback).
5. Confirm in `.exo/logs/sidecar.log` that NO Teams inbox write occurred for this message — only a tmux injection.

This smoke test is the user-facing proof the bug is fixed. If it passes, the silent dead-letter class of bug is gone.

## Why This Shape

- **Sub-TL** (not a single leaf) because it's cross-cutting — types + plan + executor + per-channel + callers — and benefits from scaffold-fork-converge with intermediate integration.
- **Two waves** because Wave 1 leaves are independent (different functions), but Wave 2 depends on Wave 1's API being stable.
- **Property tests as the regression safety net.** Plan ⊆ receivable invariant means future agent-type additions can't introduce silent dead-letters without `cargo test` failing.
- **Honest types** make the bug structurally unrepresentable. `Confirmed(channel)` requires a synchronous proof; `QueuedUnverified` carries the verification handle so callers who need certainty can await it.
