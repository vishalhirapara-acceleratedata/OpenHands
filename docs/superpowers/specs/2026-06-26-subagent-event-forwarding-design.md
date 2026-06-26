# Live Sub-agent Event Forwarding (agent-server → app-server → frontend)

**Date:** 2026-06-26
**Status:** Design — approved, pending implementation plan
**Author:** Vishal Hirapara (with Claude Code)

## 1. Problem

When the main agent delegates work via the `task` tool (`TaskToolSet`), the
sub-agent runs in its **own** SDK `LocalConversation` with its own event store
(`<workspace>/conversations/<id>/subagents/<sub_id>/events/`). Only two events
ever reach the parent conversation — and therefore the app-server and the chat
UI:

- `TaskAction` — the main agent invoking the `task` tool.
- `TaskObservation` — the sub-agent's final result + status, summarized by the
  tool executor (`openhands/tools/task/impl.py`).

The sub-agent's **inner** events (its `glob` / `read` / `terminal` / `finish`
tool calls) are produced and persisted locally inside the agent-server but are
**never forwarded**: the sub-agent conversation is created without a forwarding
callback (`openhands/tools/task/manager.py`), so its events only hit the default
persist-to-disk callback. The webhook (`WebhookSubscriber`) that pushes events to
the app-server is attached **only** to the main conversation.

**Goal:** stream the sub-agent's inner events live, through the existing pipeline
(agent-server → app-server → frontend), and display them nested under the parent
"Sub-agent task" card in the chat UI — without polluting the main agent's LLM
context.

## 2. Prior art

Both major agent SDKs use a **single flat event stream with a parent
correlation id**, not a separate sub-stream:

- **Anthropic Claude Agent SDK:** every message / stream event carries
  `parent_tool_use_id: str | None`. `None` ⇒ main agent; non-null ⇒ a sub-agent
  event, where the value is the `id` of the `ToolUseBlock` (the Task tool call)
  that spawned it.
- **OpenAI Agents SDK:** sub-agent `RunItemStreamEvent`s are surfaced recursively
  in the same stream, annotated with the originating agent so the UI can
  attribute them.

This design follows the Anthropic model directly.

## 3. Key insight: observability stream vs. agent context

The flat "merged" stream is for **observability/output** — it is not the
sub-agent's or the main agent's LLM context. In OpenHands:

- The **agent's context** = each conversation's own `state.events` (separate per
  `LocalConversation`, lives in the agent-server / sandbox). This MUST stay
  isolated — the whole point of delegation.
- The **observability stream** = what is pushed to the app-server via the
  webhook and rendered by the UI. Sub-agent events may join this stream as long
  as they are never appended to the parent conversation's `state.events`.

There is already a precedent for "reach subscribers but do not persist to
`state.events`": `StreamingDeltaEvent` is published directly to the
conversation's `_pub_sub` (see `openhands/agent_server/event_service.py:754`).
This design reuses that exact mechanism.

## 4. Architecture

```
sub-agent LocalConversation  (forked openhands/tools/task/manager.py)
  └─ forwarding callback (the `callbacks=` slot currently left empty):
        stamp event.parent_tool_use_id = <TaskAction tool_call_id>
        forward via a "sub-event sink" supplied by the agent-server
          └─ sink: publish to the PARENT EventService._pub_sub directly
                   (NOT appended to parent state.events)   [publish-not-persist]
                └─ existing WebhookSubscriber → POST {base_url}/events/{parent_id}
                      └─ app-server on_event → save_event   (event carries parent_tool_use_id)
                            └─ existing /events/search + live WebSocket
                                  └─ frontend nests events under the Sub-agent
                                     task card whose tool_call_id matches
```

Correlation key: the **`tool_call_id` of the `TaskAction`** (stable, already
present on the action and its paired observation), mirroring Anthropic's
`parent_tool_use_id`.

## 5. Components & changes

All changes are in local forks of the pinned SDK packages
(`openhands-sdk`, `openhands-tools`, `openhands-agent-server`, currently
`==1.29.0`) plus the in-repo app-server and frontend. The local runtime
(`RUNTIME=local`, runs `python -m openhands.agent_server` from the venv) makes
editable forks take effect with no Docker image rebuild.

### 5.1 SDK fork — `openhands/sdk/event/base.py`
Add an optional field to the base `Event`:

```python
parent_tool_use_id: str | None = None
```

`None` for main-agent events; set to the spawning Task tool-call id for
sub-agent events. It serializes automatically via `model_dump(mode="json")`, so
it flows through the webhook payload, the app-server store, and into the
frontend types with no further wiring on the transport.

### 5.2 SDK fork — `openhands/tools/task` (`manager.py`, `impl.py`, `definition.py`)
- The `task` tool / `TaskManager` accept a new **optional** `sub_event_sink`
  callable: `Callable[[Event], None]`.
- When creating the sub-agent `LocalConversation`, attach a callback (into the
  `callbacks=` argument that is currently omitted) that:
  1. sets `event.parent_tool_use_id = <parent TaskAction tool_call_id>`, then
  2. calls `sub_event_sink(event)`.
- The parent `tool_call_id` must be threaded into the executor. `TaskExecutor`
  receives the `TaskAction`; the implementation plan must confirm the cleanest
  way to obtain the wrapping `ActionEvent.tool_call_id` (e.g. pass it through the
  tool-execution context).

### 5.3 agent-server fork — `openhands/agent_server/event_service.py`
- Build the `sub_event_sink` as a closure over the parent conversation's
  `_pub_sub`, publishing the (already-stamped) event directly — the same
  publish-not-persist path as `_publish_stream_delta`.
- Pass the sink when constructing sub-agent-enabled tools
  (`get_default_tools(enable_sub_agents=True)` / tool registration), so it is
  available to the `TaskManager`.

### 5.4 app-server (in repo) — `openhands/app_server`
- No structural change: `event_callback/webhook_router.py:on_event` already
  persists whatever events arrive; they now simply carry `parent_tool_use_id`.
- Guard: skip sub-agent events (those with a non-null `parent_tool_use_id`) in
  analytics paths that scan events — stats processing and terminal-state
  detection in `on_event` — so sub-agent activity does not skew conversation
  metrics.

### 5.5 frontend (in repo) — `frontend/src`
- Add `parent_tool_use_id?: string | null` to the V1 event base type
  (`types/v1/core/base/...`).
- In the chat event list, **do not** render events with a non-null
  `parent_tool_use_id` at the top level. Instead, group them by
  `parent_tool_use_id` and render them as a live, nested timeline inside the
  existing `SubagentObservationContent` / "Sub-agent task" card whose
  `tool_call_id` matches.
- Live behavior: as sub-agent events arrive over the WebSocket, append them into
  the matching open card.

## 6. Context-isolation invariant

Sub-agent events are **never** appended to the parent conversation's
`state.events`. They are published to the parent `_pub_sub` only. Therefore the
main agent's prompt is byte-for-byte unchanged from today's behavior. This is the
single most important correctness property and is enforced at the SDK forwarding
callback (publish-only, no `state.events.append`).

## 7. Error handling & safety

- **Best-effort forwarding:** a failure to publish/forward sub-agent events never
  blocks the sub-agent run and never changes the `TaskObservation` returned to
  the main agent. Delivery reuses the webhook's existing retry (`num_retries`)
  and bounded-queue drop-oldest backpressure (`max_queue_size`).
- **Feature flag:** gate the forwarding behind configuration (default off for the
  upstream PR), naturally associated with `enable_sub_agents`, so it can be
  disabled without code changes.
- **No storage migration:** the on-disk `subagents/<id>/events/` store is
  unchanged; this design adds a forward, it does not relocate persistence.

## 8. Testing

- **SDK unit:** the forwarding callback stamps `parent_tool_use_id`, invokes the
  sink, and does NOT mutate the parent conversation's `state.events`.
- **app-server unit:** `on_event` persists events carrying `parent_tool_use_id`;
  `/events/search` returns them; analytics paths ignore them.
- **frontend unit:** events are grouped/nested by matching `parent_tool_use_id`
  to a `TaskAction.tool_call_id`; live append into the open card works.
- **E2E (local runtime):** start a conversation, trigger a sub-agent, and verify
  the inner steps appear nested and live under the Sub-agent task card at
  `http://localhost:3001`, while the parent stream still shows only
  `TaskAction` + `TaskObservation`.

## 9. Out of scope

- Resuming/replaying historical sub-agent events from the on-disk store (this
  design covers live forwarding only; lazy historical read could be a follow-up).
- Any change to how the `TaskObservation` summary is computed.
- Nesting depth beyond one level (sub-agents spawning sub-agents) — the
  `parent_tool_use_id` model supports it, but the UI work is deferred.

## 10. References

- Anthropic Claude Agent SDK — Subagents: https://platform.claude.com/docs/en/agent-sdk/subagents
- Anthropic Claude Agent SDK — Streaming output: https://platform.claude.com/docs/en/agent-sdk/streaming-output
- OpenAI Agents SDK — Streaming: https://openai.github.io/openai-agents-python/streaming/
- OpenAI Agents SDK — Streaming events: https://openai.github.io/openai-agents-python/ref/stream_events/
- In-repo precedent (publish-not-persist): `openhands/agent_server/event_service.py:754` (`StreamingDeltaEvent`)
