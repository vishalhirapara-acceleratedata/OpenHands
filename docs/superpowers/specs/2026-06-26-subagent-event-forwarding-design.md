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
                └─ WebhookSubscriber → POST to app-server
                      └─ app-server on_event: events with parent_tool_use_id set
                         are persisted into a SEPARATE sub-directory keyed by the
                         sub-conversation id (NOT the parent's flat events dir)
                            └─ live WebSocket (tagged) + read endpoint over the sub-dir
                                  └─ frontend nests events under the Sub-agent
                                     task card whose tool_call_id matches
```

Correlation key: the **`tool_call_id` of the `TaskAction`** (stable, already
present on the action and its paired observation), mirroring Anthropic's
`parent_tool_use_id`. The correlation tag is for transport + frontend nesting
only — it does **not** imply flat on-disk co-location (see §5.6 / §7).

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
- **Directory structure is NOT changed** (hard constraint, see §5.6 / §7).
  Sub-agent events must continue to live under their **own separate directory**,
  exactly as today — they must **not** be flattened into the parent
  conversation's flat events directory.
- `event_callback/webhook_router.py:on_event` routes by the event's
  `parent_tool_use_id`:
  - `None` → persist into the parent conversation's existing events store
    (unchanged).
  - non-null → persist into a **separate sub-directory keyed by the
    sub-conversation id**, mirroring the agent-server layout
    (`v1_conversations/<parent_id>/subagents/<sub_conversation_id>/events/`).
    This requires the forwarded event to carry its own (sub) `conversation_id`
    alongside `parent_tool_use_id`.
- Expose the sub-stream via a read endpoint over that separate directory, e.g.
  `GET /conversation/{parent_id}/subagents/{tool_call_id}/events` (history);
  live events still flow over the existing WebSocket, tagged.
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
  the matching open card. Historical loads read from the sub-stream endpoint
  (§5.4).

### 5.6 Directory-structure constraint (hard requirement)
The on-disk directory layout must remain **unchanged** at every layer; sub-agent
events stay in their **own separate directory**, as they are today:
- **Agent-server (origin):** `conversations/<parent_id>/subagents/<sub_id>/events/`
  — untouched.
- **App-server (sink):** forwarded sub-agent events are persisted into a matching
  **separate** sub-directory keyed by the sub-conversation id — never merged into
  the parent conversation's flat events directory.

`parent_tool_use_id` is purely a **logical correlation tag** for transport and
frontend nesting. It does **not** change where events are physically stored. The
"single stream" the frontend renders is reconstructed by correlation, not by
flat co-location on disk.

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
- **No storage migration / directory structure unchanged (hard constraint):**
  the on-disk `subagents/<id>/events/` store is unchanged, and sub-agent events
  continue to fall under their **own separate directory** at both the
  agent-server and the app-server (see §5.6). This design adds a forward + a
  correlation tag; it does **not** relocate persistence or flatten sub-agent
  events into the parent's events directory.

## 8. Testing

### 8.1 SDK unit (forked `openhands-sdk` / `openhands-tools`)
- `Event.parent_tool_use_id` defaults to `None` and round-trips through
  `model_dump(mode="json")` / `model_validate_json`.
- The forwarding callback stamps `parent_tool_use_id` with the parent
  `TaskAction.tool_call_id`, invokes the `sub_event_sink`, and does **NOT**
  append to the parent conversation's `state.events` (context-isolation
  invariant, §6).
- With no `sub_event_sink` supplied (flag off), behavior is identical to today:
  no forwarding, sub-agent events persist only to `subagents/<id>/events/`.
- Sink raising an exception does not abort the sub-agent run nor alter the
  returned `TaskObservation` (best-effort, §7).

### 8.2 agent-server unit (forked `openhands-agent-server`)
- The sink publishes to the parent `EventService._pub_sub` and the event reaches
  the subscribed `WebhookSubscriber` queue, but the parent `state.events` count
  is unchanged.

### 8.3 App-server API tests (in repo — `tests/unit/app_server`)
Contract-level tests against the FastAPI app (httpx `AsyncClient`):
- **Inbound webhook routing:** posting a batch containing events whose
  `parent_tool_use_id` is set → returns `200`, and each is persisted into the
  **separate sub-conversation directory** (§5.6), **not** the parent's flat
  events store.
- **Parent stream purity:** `GET /api/v1/conversation/{parent_id}/events/search`
  returns **only** the parent's own events — exactly one `TaskAction` + one
  `TaskObservation` for the delegation, and **no** sub-agent inner events.
- **Sub-stream query:** the sub-stream read endpoint
  (`GET /conversation/{parent_id}/subagents/{tool_call_id}/events`) returns the
  sub-agent events, each carrying `parent_tool_use_id`.
- **Directory assertion:** sub-agent events are written under
  `…/<parent_id>/subagents/<sub_id>/events/` and the parent events directory is
  unchanged.
- **Analytics guard:** a batch of sub-agent events does NOT change conversation
  stats or trigger terminal-state detection in `on_event`.

### 8.4 Frontend unit (`frontend/__tests__`)
- The V1 event type carries `parent_tool_use_id`; the type guard accepts events
  with and without it.
- Grouping logic: events with `parent_tool_use_id === <TaskAction.tool_call_id>`
  are rendered nested inside that Sub-agent task card and are **excluded** from
  the top-level chat list.
- Live append: a sub-agent event arriving over the WebSocket after the card is
  rendered is appended into the open card.

### 8.5 E2E (local runtime, `RUNTIME=local`)
Scenario — *"sub-agent inner steps stream live and nested":*
1. Start the stack via `./run-local.sh`; open `http://localhost:3001`.
2. Start a conversation in a workspace containing files; send a prompt that
   forces delegation (e.g. "Use the `code-explorer` sub-agent to list the repo
   files and summarize each top-level folder").
3. **Assert (live):** while the sub-agent runs, its `terminal`/`read`/etc.
   action+observation events appear **nested and incrementally** under the
   "Sub-agent task" card.
4. **Assert (final):** the card resolves to the `TaskObservation` summary +
   status, with the inner timeline retained.
5. **Assert (isolation + dir):** the parent stream
   (`GET /api/v1/conversation/{id}/events/search`) shows only `TaskAction` +
   `TaskObservation`; the sub-agent events are served from the separate
   sub-stream endpoint and stored under `…/<id>/subagents/<sub_id>/events/`
   (separate directory preserved, §5.6).
6. **Assert (flag off):** with the feature flag disabled, no sub-agent events
   reach the app-server and the UI behaves exactly as it does today.

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
