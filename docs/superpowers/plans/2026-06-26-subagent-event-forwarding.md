# Live Sub-agent Event Forwarding — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stream a sub-agent's inner events live from the agent-server → app-server → frontend so the chat UI nests them under the parent "Sub-agent task" card, while keeping the main agent's LLM context untouched and sub-agent events in their own separate directory.

**Architecture:** Add a `parent_tool_use_id` tag to the SDK `Event` (Anthropic model). The forked `TaskManager` attaches a forwarding callback to the sub-agent conversation that stamps the tag and publishes the event to the parent conversation's pub/sub *without* persisting it to the parent's `state.events` (the existing `StreamingDeltaEvent` "publish-not-persist" path). The events ride the existing webhook to the app-server, which routes any event carrying `parent_tool_use_id` into a **separate** sub-directory and serves it via a dedicated sub-stream endpoint. The frontend nests them by matching `parent_tool_use_id` to a `TaskAction`'s `tool_call_id`.

**Tech Stack:** Python 3.13, FastAPI, Pydantic v2, pytest, httpx; React + TypeScript + Vitest; poetry (OpenHands) + the `software-agent-sdk` monorepo (openhands-sdk / openhands-tools / openhands-agent-server).

## Global Constraints

- **Directory structure must NOT change.** Sub-agent events stay in their own separate directory at every layer; never flatten them into the parent conversation's events directory. (spec §5.6, §7)
- **Context-isolation invariant.** Sub-agent events are NEVER appended to the parent conversation's `state.events`; publish-to-pub/sub only. (spec §6)
- **Correlation key** = the `tool_call_id` of the `TaskAction`, surfaced as `Event.parent_tool_use_id` (mirrors Anthropic `parent_tool_use_id`). (spec §4)
- **Feature-flagged, default OFF.** Forwarding is gated by a config flag; with it off, behavior is byte-for-byte identical to today. (spec §7)
- **Best-effort.** Forwarding failures never block the sub-agent run nor change the returned `TaskObservation`. (spec §7)
- **SDK pins:** OpenHands currently pins `openhands-sdk==1.29.0`, `openhands-tools==1.29.0`, `openhands-agent-server==1.29.0`. The local forks must be checked out at the matching `1.29.0` tag before editing.
- **Local runtime:** test with `RUNTIME=local` so the agent-server runs `python -m openhands.agent_server` from the venv and editable forks take effect with no Docker rebuild.

> **Design refinement noted for review:** the app-server keys the separate sub-directory by `tool_call_id` (`subagents/<tool_call_id>/events/`) rather than the internal sub-conversation id. Rationale: `tool_call_id` is the value already on the wire (`parent_tool_use_id`) and the UI correlation key, so no second event field is needed. This still satisfies "separate directory, one per sub-agent task" (spec §5.6). If you require the internal sub-conversation id instead, Task 8 changes to also carry a `sub_conversation_id` field.

---

## File Structure

**Fork A — `software-agent-sdk` (local clone, editable):**
- `openhands/sdk/event/base.py` — add `parent_tool_use_id` field on `Event`.
- `openhands/tools/task/definition.py` — accept/thread an optional `sub_event_sink`.
- `openhands/tools/task/manager.py` — attach forwarding callback to the sub-agent conversation.
- `openhands/tools/task/impl.py` — pass the parent `tool_call_id` into the manager.
- `openhands/agent_server/config.py` — add `forward_subagent_events` flag.
- `openhands/agent_server/event_service.py` — build the sink (publish-not-persist) and wire it into tool construction.

**In-repo — OpenHands:**
- `openhands/app_server/event/event_service_base.py` — `save_subagent_event` / `search_subagent_events` / `get_subagent_conversation_path`.
- `openhands/app_server/event/event_router.py` — sub-stream read endpoint.
- `openhands/app_server/event_callback/webhook_router.py` — route by `parent_tool_use_id`; analytics guard.
- `frontend/src/types/v1/core/base/event.ts` (and type guards) — add `parent_tool_use_id`.
- `frontend/src/components/v1/chat/messages.tsx` — exclude nested events from top level.
- `frontend/src/components/v1/chat/subagent/subagent-observation-content.tsx` — render nested timeline.

---

## Task 0: Set up local SDK forks (editable installs)

**Files:**
- Modify: `pyproject.toml` (OpenHands) — point the three SDK deps at local paths
- Create: `../software-agent-sdk/` (local clone, sibling of the OpenHands repo)

**Interfaces:**
- Produces: an editable install of the forked SDK such that `python -c "import openhands.tools.task; print(...path...)"` resolves into the local clone, and `RUNTIME=local make start-backend` runs the forked agent-server.

- [ ] **Step 1: Clone the SDK at the pinned version**

```bash
cd /Users/vishalh
git clone https://github.com/OpenHands/software-agent-sdk.git
cd software-agent-sdk
git fetch --tags
git checkout -b feature/subagent-event-forwarding v1.29.0   # match the pin
```

- [ ] **Step 2: Point OpenHands at the local editable forks**

In `/Users/vishalh/OpenHands`, override the three deps to the local path. With poetry:

```bash
cd /Users/vishalh/OpenHands
poetry add --editable ../software-agent-sdk/openhands/sdk
poetry add --editable ../software-agent-sdk/openhands/tools
poetry add --editable ../software-agent-sdk/openhands/agent-server
```

(If the SDK monorepo uses a single distribution rather than three sub-packages, install that one editable package instead; confirm the package layout in the clone's `pyproject.toml` files.)

- [ ] **Step 3: Verify the fork is active**

Run:
```bash
poetry run python -c "import openhands.tools.task, openhands.agent_server; print(openhands.tools.task.__file__); print(openhands.agent_server.__file__)"
```
Expected: both paths point under `/Users/vishalh/software-agent-sdk/...`, NOT under the pypoetry virtualenvs `site-packages`.

- [ ] **Step 4: Smoke-test the local runtime still boots**

Run:
```bash
RUNTIME=local poetry run uvicorn openhands.server.listen:app --host 127.0.0.1 --port 3000 &
sleep 8 && curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/api/v1/settings/agent-schema
kill %1
```
Expected: `200`.

- [ ] **Step 5: Commit (OpenHands repo)**

```bash
cd /Users/vishalh/OpenHands
git add pyproject.toml poetry.lock
git commit -m "build: use local editable software-agent-sdk forks for subagent event work"
```

---

## Task 1: Add `parent_tool_use_id` to the SDK `Event` base

**Files:**
- Modify: `<sdk>/openhands/sdk/event/base.py`
- Test: `<sdk>/tests/sdk/event/test_event_parent_tool_use_id.py`

**Interfaces:**
- Produces: `Event.parent_tool_use_id: str | None = None` — serialized by `model_dump(mode="json")` and accepted by `model_validate_json`.

- [ ] **Step 1: Write the failing test**

```python
# <sdk>/tests/sdk/event/test_event_parent_tool_use_id.py
from openhands.sdk.event.conversation_state import ConversationStateUpdateEvent

def test_parent_tool_use_id_defaults_none_and_roundtrips():
    e = ConversationStateUpdateEvent(key="x", value=1, source="environment")
    assert e.parent_tool_use_id is None
    dumped = e.model_dump(mode="json")
    assert "parent_tool_use_id" in dumped and dumped["parent_tool_use_id"] is None

    e2 = ConversationStateUpdateEvent(
        key="x", value=1, source="environment", parent_tool_use_id="toolu_123"
    )
    restored = type(e2).model_validate_json(e2.model_dump_json())
    assert restored.parent_tool_use_id == "toolu_123"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/vishalh/software-agent-sdk && pytest tests/sdk/event/test_event_parent_tool_use_id.py -v`
Expected: FAIL — `parent_tool_use_id` not a valid field / AttributeError.

- [ ] **Step 3: Add the field**

In `<sdk>/openhands/sdk/event/base.py`, in the base `Event` model (next to `source: SourceType`):

```python
parent_tool_use_id: str | None = Field(
    default=None,
    description=(
        "If set, this event was produced inside a sub-agent; the value is the "
        "tool_call_id of the parent TaskAction that spawned it. None for "
        "main-agent events. Mirrors Anthropic's parent_tool_use_id."
    ),
)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/sdk/event/test_event_parent_tool_use_id.py -v`
Expected: PASS.

- [ ] **Step 5: Commit (SDK repo)**

```bash
cd /Users/vishalh/software-agent-sdk
git add openhands/sdk/event/base.py tests/sdk/event/test_event_parent_tool_use_id.py
git commit -m "feat(sdk): add Event.parent_tool_use_id for sub-agent correlation"
```

---

## Task 2: Thread an optional `sub_event_sink` through the task tool

**Files:**
- Modify: `<sdk>/openhands/tools/task/definition.py`
- Modify: `<sdk>/openhands/tools/task/manager.py`
- Modify: `<sdk>/openhands/tools/task/impl.py`
- Test: `<sdk>/tests/tools/task/test_sub_event_sink_wiring.py`

**Interfaces:**
- Consumes: `Event.parent_tool_use_id` (Task 1).
- Produces:
  - `TaskManager(..., sub_event_sink: Callable[[Event], None] | None = None)`
  - `TaskExecutor.__call__(action, conversation, *, parent_tool_use_id: str | None = None)` — passes `parent_tool_use_id` to `start_task`.
  - `start_task(..., parent_tool_use_id: str | None = None)` — forwards it to `_run_task`.

- [ ] **Step 1: Write the failing test**

```python
# <sdk>/tests/tools/task/test_sub_event_sink_wiring.py
import inspect
from openhands.tools.task.manager import TaskManager

def test_taskmanager_accepts_sub_event_sink():
    sig = inspect.signature(TaskManager.__init__)
    assert "sub_event_sink" in sig.parameters

def test_start_task_accepts_parent_tool_use_id():
    sig = inspect.signature(TaskManager.start_task)
    assert "parent_tool_use_id" in sig.parameters
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/tools/task/test_sub_event_sink_wiring.py -v`
Expected: FAIL — parameters absent.

- [ ] **Step 3: Add the parameters (no behavior yet)**

In `manager.py` `TaskManager.__init__`, add and store:

```python
def __init__(self, ..., sub_event_sink: "Callable[[Event], None] | None" = None):
    ...
    self._sub_event_sink = sub_event_sink
```
Add `from collections.abc import Callable` and `from openhands.sdk.event import Event` imports if missing.

In `start_task` and `_run_task`, add `parent_tool_use_id: str | None = None` to the signatures and thread it through (store it on the per-task state for use in Task 3).

In `impl.py` `TaskExecutor.__call__`, accept `parent_tool_use_id` and pass it on:
```python
def __call__(self, action, conversation=None, *, parent_tool_use_id=None):
    task = self._manager.start_task(
        prompt=action.prompt, subagent_type=action.subagent_type,
        description=action.description, resume=action.resume,
        conversation=conversation, parent_tool_use_id=parent_tool_use_id,
    )
    ...
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/tools/task/test_sub_event_sink_wiring.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/vishalh/software-agent-sdk
git add openhands/tools/task/ tests/tools/task/test_sub_event_sink_wiring.py
git commit -m "feat(tools): thread sub_event_sink + parent_tool_use_id through task tool"
```

---

## Task 3: Attach the forwarding callback to the sub-agent conversation

**Files:**
- Modify: `<sdk>/openhands/tools/task/manager.py`
- Test: `<sdk>/tests/tools/task/test_forwarding_callback.py`

**Interfaces:**
- Consumes: `self._sub_event_sink`, `parent_tool_use_id` (Task 2); `Event.parent_tool_use_id` (Task 1).
- Produces: sub-agent `LocalConversation` is created with `callbacks=[forwarding_cb]` when a sink is present; `forwarding_cb` stamps `parent_tool_use_id` and calls the sink. It does NOT append to any parent state.

- [ ] **Step 1: Write the failing test**

```python
# <sdk>/tests/tools/task/test_forwarding_callback.py
from openhands.tools.task.manager import TaskManager

def test_forwarding_callback_stamps_and_forwards(monkeypatch):
    captured = []
    mgr = TaskManager(sub_event_sink=lambda e: captured.append(e))
    cb = mgr._make_forwarding_callback(parent_tool_use_id="toolu_abc")  # helper added in Step 3

    class FakeEvent:
        parent_tool_use_id = None
    ev = FakeEvent()
    cb(ev)

    assert ev.parent_tool_use_id == "toolu_abc"
    assert captured == [ev]

def test_no_sink_means_no_callback():
    mgr = TaskManager(sub_event_sink=None)
    assert mgr._make_forwarding_callback(parent_tool_use_id="x") is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/tools/task/test_forwarding_callback.py -v`
Expected: FAIL — `_make_forwarding_callback` undefined.

- [ ] **Step 3: Implement the helper and wire it into conversation creation**

In `manager.py`:
```python
def _make_forwarding_callback(self, parent_tool_use_id: str | None):
    sink = self._sub_event_sink
    if sink is None:
        return None
    def _forward(event):
        try:
            event.parent_tool_use_id = parent_tool_use_id
            sink(event)
        except Exception:
            logger.warning("sub-agent event forwarding failed", exc_info=True)
    return _forward
```

In both `LocalConversation(...)` construction sites (the run path ~line 305 and resume path ~line 213), pass the callback:
```python
_fwd = self._make_forwarding_callback(parent_tool_use_id)
conversation = LocalConversation(
    agent=worker_agent,
    workspace=parent.state.workspace.working_dir,
    persistence_dir=self._persistence_dir,
    conversation_id=conversation_id,
    callbacks=[_fwd] if _fwd else [],   # <-- the previously-empty slot
    ... # existing args unchanged
)
```
`parent_tool_use_id` is the value threaded in via Task 2.

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/tools/task/test_forwarding_callback.py -v`
Expected: PASS.

- [ ] **Step 5: Add the isolation regression test**

```python
def test_forwarding_does_not_touch_parent_state():
    # The callback only stamps + forwards; it must not reference parent state.
    import inspect
    from openhands.tools.task.manager import TaskManager
    src = inspect.getsource(TaskManager._make_forwarding_callback)
    assert "state.events" not in src and "append" not in src
```
Run: `pytest tests/tools/task/test_forwarding_callback.py -v` → PASS.

- [ ] **Step 6: Commit**

```bash
git add openhands/tools/task/manager.py tests/tools/task/test_forwarding_callback.py
git commit -m "feat(tools): forward sub-agent events via stamping callback (publish-only)"
```

---

## Task 4: Build the sink in the agent-server (publish-not-persist) + flag

**Files:**
- Modify: `<sdk>/openhands/agent_server/config.py`
- Modify: `<sdk>/openhands/agent_server/event_service.py`
- Test: `<sdk>/tests/agent_server/test_subagent_event_sink.py`

**Interfaces:**
- Consumes: `TaskManager(sub_event_sink=...)` (Task 2); the parent `EventService._pub_sub`.
- Produces:
  - `Config.forward_subagent_events: bool = False` (env `OH_FORWARD_SUBAGENT_EVENTS`).
  - `EventService._make_subagent_event_sink() -> Callable[[Event], None]` that publishes directly to `self._pub_sub` (NOT persisted), mirroring `_publish_stream_delta`.
  - When `forward_subagent_events` is true, the sink is passed into the `TaskToolSet`/`TaskManager` used by this conversation.

- [ ] **Step 1: Write the failing test**

```python
# <sdk>/tests/agent_server/test_subagent_event_sink.py
def test_flag_defaults_off():
    from openhands.agent_server.config import Config
    assert Config().forward_subagent_events is False

def test_sink_publishes_without_persisting(make_event_service):
    svc = make_event_service()           # fixture builds a started EventService
    sink = svc._make_subagent_event_sink()
    before = len(svc.stored_state.events)  # parent state count
    published = []
    svc._pub_sub.subscribe_sync(lambda e: published.append(e))  # test hook
    fake = make_event(parent_tool_use_id="toolu_1")
    sink(fake)
    assert published and published[-1] is fake          # reached subscribers
    assert len(svc.stored_state.events) == before        # NOT persisted to parent
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/agent_server/test_subagent_event_sink.py -v`
Expected: FAIL — `forward_subagent_events` / `_make_subagent_event_sink` missing.

- [ ] **Step 3: Add the flag**

In `config.py` `Config`:
```python
forward_subagent_events: bool = Field(
    default=False,
    description="Forward sub-agent inner events to the webhook (tagged with "
    "parent_tool_use_id). Default off.",
)
```
Confirm the env loader maps `OH_FORWARD_SUBAGENT_EVENTS` (the agent-server uses `OH`-prefixed env parsing).

- [ ] **Step 4: Implement the sink**

In `event_service.py`, add a method that mirrors the direct-publish path used by `_publish_stream_delta` (the one documented at the line that says "Published directly to _pub_sub ... but are NOT persisted"):
```python
def _make_subagent_event_sink(self):
    def _sink(event):
        if not self._main_loop or not self._main_loop.is_running():
            return
        # Direct publish: reaches subscribers (incl. WebhookSubscriber),
        # NOT appended to ConversationState.events.
        asyncio.run_coroutine_threadsafe(
            self._pub_sub.publish(event), self._main_loop
        )
    return _sink
```

- [ ] **Step 5: Wire the sink into tool construction (gated by flag)**

Where the conversation's tools are built (`get_default_tools(enable_sub_agents=...)` / `TaskToolSet` creation in `start()`), pass the sink only when both `enable_sub_agents` and `forward_subagent_events` are true:
```python
sink = self._make_subagent_event_sink() if self.config.forward_subagent_events else None
# pass `sink` into TaskToolSet/TaskManager construction
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `pytest tests/agent_server/test_subagent_event_sink.py -v`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add openhands/agent_server/config.py openhands/agent_server/event_service.py tests/agent_server/test_subagent_event_sink.py
git commit -m "feat(agent-server): publish-not-persist sub-agent event sink behind flag"
```

---

## Task 5: Pass the parent `tool_call_id` into the executor

**Files:**
- Modify: `<sdk>/openhands/tools/task/definition.py` (or wherever `TaskExecutor` is invoked with the tool-call context)
- Test: `<sdk>/tests/tools/task/test_parent_tool_call_id_plumbing.py`

**Interfaces:**
- Consumes: `TaskExecutor.__call__(..., parent_tool_use_id=...)` (Task 2).
- Produces: the executor is invoked with the wrapping `ActionEvent.tool_call_id` as `parent_tool_use_id` so the forwarding callback stamps the correct value.

- [ ] **Step 1: Find where the tool executor is called with the action**

Run:
```bash
cd /Users/vishalh/software-agent-sdk
grep -rn "tool_call_id\|executor(\|\.executor\|ToolExecutor" openhands/sdk/agent openhands/sdk/tool | grep -i "call\|execute" | head
```
Document the call site that turns an `ActionEvent` into a tool execution. The `ActionEvent` carries `tool_call_id`.

- [ ] **Step 2: Write the failing test**

```python
# <sdk>/tests/tools/task/test_parent_tool_call_id_plumbing.py
from openhands.tools.task.impl import TaskExecutor

def test_executor_forwards_parent_tool_use_id(monkeypatch):
    seen = {}
    class FakeMgr:
        def start_task(self, **kw):
            seen.update(kw)
            class T:  # minimal completed task
                status = __import__("openhands.tools.task.manager", fromlist=["TaskStatus"]).TaskStatus.COMPLETED
                id = "task_1"; result = "ok"
            return T()
        def close(self): ...
    ex = TaskExecutor(FakeMgr())
    from openhands.tools.task.definition import TaskAction
    ex(TaskAction(prompt="p", subagent_type="code-explorer", description=None, resume=None),
       conversation=None, parent_tool_use_id="toolu_xyz")
    assert seen["parent_tool_use_id"] == "toolu_xyz"
```

- [ ] **Step 3: Run test to verify it fails**

Run: `pytest tests/tools/task/test_parent_tool_call_id_plumbing.py -v`
Expected: FAIL if the executor signature/call site doesn't yet forward it (it should pass after Task 2; if the call site in the agent loop doesn't supply it, this is where you fix it).

- [ ] **Step 4: Supply `tool_call_id` at the call site**

At the executor invocation found in Step 1, pass the action event's `tool_call_id`:
```python
observation = executor(action, conversation=conversation, parent_tool_use_id=action_event.tool_call_id)
```
If `TaskExecutor` is invoked generically (all tools share one call path), gate this on the executor accepting the kwarg (e.g. check `inspect.signature`) so other tools are unaffected.

- [ ] **Step 5: Run test to verify it passes**

Run: `pytest tests/tools/task/test_parent_tool_call_id_plumbing.py -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add openhands/ tests/tools/task/test_parent_tool_call_id_plumbing.py
git commit -m "feat(tools): supply parent TaskAction tool_call_id to sub-agent forwarding"
```

---

## Task 6: App-server — separate sub-agent event store paths

**Files:**
- Modify: `openhands/app_server/event/event_service_base.py`
- Test: `tests/unit/app_server/test_subagent_event_store.py`

**Interfaces:**
- Consumes: existing `get_conversation_path`, `_store_event`, `_search_paths`.
- Produces:
  - `get_subagent_conversation_path(parent_id: UUID, tool_call_id: str) -> Path` → `<parent path>/subagents/<tool_call_id>/events`
  - `save_subagent_event(parent_id: UUID, tool_call_id: str, event: Event)`
  - `search_subagent_events(parent_id: UUID, tool_call_id: str) -> list[Event]`

- [ ] **Step 1: Write the failing test**

```python
# tests/unit/app_server/test_subagent_event_store.py
import uuid, pytest
from openhands.app_server.event.filesystem_event_service import FilesystemEventService

@pytest.mark.asyncio
async def test_subagent_events_go_to_separate_dir(tmp_path, make_event):
    svc = FilesystemEventService(prefix=tmp_path, user_id="u1",
                                 app_conversation_info_service=None,
                                 app_conversation_info_load_tasks={})
    parent = uuid.uuid4()
    ev = make_event(id=uuid.uuid4(), parent_tool_use_id="toolu_1")
    await svc.save_subagent_event(parent, "toolu_1", ev)

    sub_dir = await svc.get_subagent_conversation_path(parent, "toolu_1")
    parent_dir = await svc.get_conversation_path(parent)
    assert sub_dir.exists() and list(sub_dir.glob("*.json"))
    assert "subagents" in str(sub_dir) and "toolu_1" in str(sub_dir)
    # parent flat events dir must NOT contain the sub-agent event
    assert not (parent_dir / f"{ev.id.hex}.json").exists()

    found = await svc.search_subagent_events(parent, "toolu_1")
    assert [e.parent_tool_use_id for e in found] == ["toolu_1"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `poetry run pytest tests/unit/app_server/test_subagent_event_store.py -v`
Expected: FAIL — methods undefined.

- [ ] **Step 3: Implement the methods**

In `event_service_base.py`:
```python
async def get_subagent_conversation_path(self, conversation_id: UUID, tool_call_id: str) -> Path:
    base = await self.get_conversation_path(conversation_id)
    return base / "subagents" / tool_call_id / "events"

async def save_subagent_event(self, conversation_id: UUID, tool_call_id: str, event: Event):
    id_hex = event.id.replace('-', '') if isinstance(event.id, str) else event.id.hex
    path = (await self.get_subagent_conversation_path(conversation_id, tool_call_id)) / f'{id_hex}.json'
    loop = asyncio.get_running_loop()
    await loop.run_in_executor(None, self._store_event, path, event)

async def search_subagent_events(self, conversation_id: UUID, tool_call_id: str) -> list[Event]:
    base = await self.get_subagent_conversation_path(conversation_id, tool_call_id)
    loop = asyncio.get_running_loop()
    paths = await loop.run_in_executor(None, self._search_paths, base)
    events = [self._load_event(p) for p in sorted(paths)]
    return [e for e in events if e is not None]
```
(`_store_event` already `mkdir -p`s the parent; `_search_paths` already globs `prefix/*`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `poetry run pytest tests/unit/app_server/test_subagent_event_store.py -v`
Expected: PASS.

- [ ] **Step 5: Commit (OpenHands repo)**

```bash
cd /Users/vishalh/OpenHands
git add openhands/app_server/event/event_service_base.py tests/unit/app_server/test_subagent_event_store.py
git commit -m "feat(app-server): separate on-disk store for sub-agent events"
```

---

## Task 7: App-server — route inbound webhook + analytics guard

**Files:**
- Modify: `openhands/app_server/event_callback/webhook_router.py`
- Test: `tests/unit/app_server/test_on_event_subagent_routing.py`

**Interfaces:**
- Consumes: `save_subagent_event` (Task 6); `Event.parent_tool_use_id` (Task 1).
- Produces: `on_event` persists events with non-null `parent_tool_use_id` via `save_subagent_event(conversation_id, event.parent_tool_use_id, event)` and skips them in stats/terminal-state scans; events with `parent_tool_use_id is None` keep the current path unchanged.

- [ ] **Step 1: Write the failing test**

```python
# tests/unit/app_server/test_on_event_subagent_routing.py
import uuid, pytest
from unittest.mock import AsyncMock
from openhands.app_server.event_callback.webhook_router import on_event

@pytest.mark.asyncio
async def test_subagent_event_routed_to_subagent_store(make_event):
    svc = AsyncMock()
    cid = uuid.uuid4()
    main = make_event(id=uuid.uuid4(), parent_tool_use_id=None)
    sub  = make_event(id=uuid.uuid4(), parent_tool_use_id="toolu_1")
    await on_event(events=[main, sub], conversation_id=cid,
                   app_conversation_info=AsyncMock(), app_conversation_info_service=AsyncMock(),
                   event_service=svc)
    svc.save_event.assert_awaited_once_with(cid, main)
    svc.save_subagent_event.assert_awaited_once_with(cid, "toolu_1", sub)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `poetry run pytest tests/unit/app_server/test_on_event_subagent_routing.py -v`
Expected: FAIL — `on_event` saves both via `save_event`.

- [ ] **Step 3: Implement routing + analytics guard**

In `webhook_router.py` `on_event`, replace the unconditional save loop:
```python
await asyncio.gather(*[
    (event_service.save_subagent_event(conversation_id, event.parent_tool_use_id, event)
     if getattr(event, "parent_tool_use_id", None)
     else event_service.save_event(conversation_id, event))
    for event in events
])
```
Then, in each subsequent scan in this handler (stats `for event in events`, terminal-state detection, switched-model detection), skip sub-agent events:
```python
for event in events:
    if getattr(event, "parent_tool_use_id", None):
        continue
    ...
```

- [ ] **Step 4: Run test to verify it passes**

Run: `poetry run pytest tests/unit/app_server/test_on_event_subagent_routing.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add openhands/app_server/event_callback/webhook_router.py tests/unit/app_server/test_on_event_subagent_routing.py
git commit -m "feat(app-server): route sub-agent events to separate store; guard analytics"
```

---

## Task 8: App-server — sub-stream read endpoint

**Files:**
- Modify: `openhands/app_server/event/event_router.py`
- Test: `tests/unit/app_server/test_subagent_events_endpoint.py`

**Interfaces:**
- Consumes: `search_subagent_events` (Task 6).
- Produces: `GET /api/v1/conversation/{conversation_id}/subagents/{tool_call_id}/events` → JSON list of sub-agent events (each with `parent_tool_use_id`).

- [ ] **Step 1: Write the failing test**

```python
# tests/unit/app_server/test_subagent_events_endpoint.py
import pytest
@pytest.mark.asyncio
async def test_subagent_events_endpoint(app_client, seed_subagent_events):
    cid, tool_call_id = seed_subagent_events  # fixture writes 2 sub events
    r = await app_client.get(f"/api/v1/conversation/{cid}/subagents/{tool_call_id}/events")
    assert r.status_code == 200
    body = r.json()
    assert len(body) == 2
    assert all(e["parent_tool_use_id"] == tool_call_id for e in body)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `poetry run pytest tests/unit/app_server/test_subagent_events_endpoint.py -v`
Expected: FAIL — 404 (route missing).

- [ ] **Step 3: Add the endpoint**

In `event_router.py` (prefix is `/conversation/{conversation_id}/events`; add a sibling route under the same router or a new path):
```python
@router.get('/../subagents/{tool_call_id}/events')  # see note
async def search_subagent_events(
    conversation_id: str,
    tool_call_id: str,
    event_service: EventService = event_service_dependency,
) -> list[Event]:
    return await event_service.search_subagent_events(UUID(conversation_id), tool_call_id)
```
Note: the existing router prefix is `/conversation/{conversation_id}/events`. Define this route on a router whose prefix is `/conversation/{conversation_id}` (register a small dedicated `APIRouter(prefix='/conversation/{conversation_id}')` in `v1_router.py`, or add the full path on the existing events router as `'/subagents/{tool_call_id}'` if the prefix already ends in `/events` — verify and pick the form that yields exactly `/api/v1/conversation/{id}/subagents/{tool_call_id}/events`).

- [ ] **Step 4: Run test to verify it passes**

Run: `poetry run pytest tests/unit/app_server/test_subagent_events_endpoint.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add openhands/app_server/event/event_router.py openhands/app_server/v1_router.py tests/unit/app_server/test_subagent_events_endpoint.py
git commit -m "feat(app-server): add sub-agent sub-stream read endpoint"
```

---

## Task 9: Frontend — type + type guard for `parent_tool_use_id`

**Files:**
- Modify: `frontend/src/types/v1/core/base/event.ts` (the base event type)
- Modify: `frontend/src/types/v1/type-guards.ts`
- Test: `frontend/__tests__/types/v1/parent-tool-use-id.test.ts`

**Interfaces:**
- Produces: `BaseEvent.parent_tool_use_id?: string | null` accepted by `isV1Event`/`isBaseEvent`.

- [ ] **Step 1: Write the failing test**

```ts
// frontend/__tests__/types/v1/parent-tool-use-id.test.ts
import { isV1Event } from "#/types/v1/type-guards";

test("v1 event accepts optional parent_tool_use_id", () => {
  const e = { id: "1", timestamp: "t", source: "agent", parent_tool_use_id: "toolu_1" };
  expect(isV1Event(e)).toBe(true);
});
```

- [ ] **Step 2: Run test to verify it fails (or passes loosely)**

Run: `cd frontend && npx vitest run __tests__/types/v1/parent-tool-use-id.test.ts`
Expected: FAIL to typecheck (field not on type) when `tsc` runs, or compile error in the test.

- [ ] **Step 3: Add the field to the base type**

In `frontend/src/types/v1/core/base/event.ts`, on the base event interface:
```ts
parent_tool_use_id?: string | null;
```
No change needed to `isBaseEvent` runtime checks (optional field), but confirm it does not reject the extra key.

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run __tests__/types/v1/parent-tool-use-id.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/vishalh/OpenHands
git add frontend/src/types/v1/ frontend/__tests__/types/v1/parent-tool-use-id.test.ts
git commit -m "feat(frontend): add parent_tool_use_id to v1 event type"
```

---

## Task 10: Frontend — exclude nested events from the top-level list

**Files:**
- Modify: `frontend/src/components/v1/chat/messages.tsx`
- Test: `frontend/__tests__/components/v1/chat/messages-nesting.test.tsx`

**Interfaces:**
- Consumes: `event.parent_tool_use_id` (Task 9).
- Produces: top-level message list renders only events with `parent_tool_use_id == null`; events with a value are grouped into a `Map<tool_call_id, Event[]>` passed down to the matching card.

- [ ] **Step 1: Write the failing test**

```tsx
// frontend/__tests__/components/v1/chat/messages-nesting.test.tsx
import { groupEventsByParent } from "#/components/v1/chat/messages";

test("splits top-level vs nested by parent_tool_use_id", () => {
  const events = [
    { id: "a", parent_tool_use_id: null },
    { id: "b", parent_tool_use_id: "toolu_1" },
    { id: "c", parent_tool_use_id: "toolu_1" },
  ] as any;
  const { topLevel, nestedByToolCallId } = groupEventsByParent(events);
  expect(topLevel.map(e => e.id)).toEqual(["a"]);
  expect(nestedByToolCallId.get("toolu_1")?.map(e => e.id)).toEqual(["b", "c"]);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && npx vitest run __tests__/components/v1/chat/messages-nesting.test.tsx`
Expected: FAIL — `groupEventsByParent` not exported.

- [ ] **Step 3: Implement the grouping helper and use it**

In `messages.tsx`, add and export:
```ts
export function groupEventsByParent(events: BaseEvent[]) {
  const topLevel: BaseEvent[] = [];
  const nestedByToolCallId = new Map<string, BaseEvent[]>();
  for (const e of events) {
    const pid = e.parent_tool_use_id;
    if (pid) {
      const arr = nestedByToolCallId.get(pid) ?? [];
      arr.push(e);
      nestedByToolCallId.set(pid, arr);
    } else {
      topLevel.push(e);
    }
  }
  return { topLevel, nestedByToolCallId };
}
```
Render `topLevel` in the existing map; pass `nestedByToolCallId` down so each Sub-agent task card can look up its own `tool_call_id`.

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run __tests__/components/v1/chat/messages-nesting.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/components/v1/chat/messages.tsx frontend/__tests__/components/v1/chat/messages-nesting.test.tsx
git commit -m "feat(frontend): split nested sub-agent events out of top-level chat list"
```

---

## Task 11: Frontend — render the nested timeline in the Sub-agent task card

**Files:**
- Modify: `frontend/src/components/v1/chat/subagent/subagent-observation-content.tsx`
- Test: `frontend/__tests__/components/v1/chat/subagent-nested-timeline.test.tsx`

**Interfaces:**
- Consumes: `nestedByToolCallId` (Task 10); the card already knows its `tool_call_id` (from the paired `TaskAction`/observation).
- Produces: the card renders its nested events (by `tool_call_id`) as a timeline; updates as new events arrive.

- [ ] **Step 1: Write the failing test**

```tsx
// frontend/__tests__/components/v1/chat/subagent-nested-timeline.test.tsx
import { render, screen } from "@testing-library/react";
import { SubagentObservationContent } from "#/components/v1/chat/subagent/subagent-observation-content";

test("renders nested sub-agent events under the card", () => {
  const nested = [
    { id: "b", parent_tool_use_id: "toolu_1", action: { kind: "TerminalAction", command: "ls" }, source: "agent" },
  ] as any;
  render(<SubagentObservationContent
            event={{ observation: { kind: "TaskObservation", task_id: "t", subagent: "code-explorer", status: "completed", content: [] } } as any}
            correspondingAction={{ tool_call_id: "toolu_1", action: { kind: "TaskAction", prompt: "p" } } as any}
            nestedEvents={nested} />);
  expect(screen.getByText(/ls/)).toBeInTheDocument();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && npx vitest run __tests__/components/v1/chat/subagent-nested-timeline.test.tsx`
Expected: FAIL — component ignores `nestedEvents`.

- [ ] **Step 3: Implement the nested timeline**

Add a `nestedEvents?: BaseEvent[]` prop to `SubagentObservationContent`. Below the existing Query/Result sections, render the nested events with the same per-event renderer the chat uses (reuse `getEventContent` / `GenericEventMessage`), in timestamp order. Wire `messages.tsx` to pass `nestedByToolCallId.get(correspondingAction.tool_call_id)` into this prop.

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run __tests__/components/v1/chat/subagent-nested-timeline.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/components/v1/chat/subagent/subagent-observation-content.tsx frontend/__tests__/components/v1/chat/subagent-nested-timeline.test.tsx
git commit -m "feat(frontend): nested live timeline of sub-agent events in task card"
```

---

## Task 12: End-to-end verification (local runtime)

**Files:**
- Test: manual / scripted E2E (no new unit file)

**Interfaces:**
- Consumes: all prior tasks; `OH_FORWARD_SUBAGENT_EVENTS=true`.

- [ ] **Step 1: Launch with the flag on**

```bash
cd /Users/vishalh/OpenHands
RUNTIME=local OH_FORWARD_SUBAGENT_EVENTS=true ./run-local.sh
```
Open `http://localhost:3001`; ensure LLM key is set and `enable_sub_agents` is on.

- [ ] **Step 2: Trigger a sub-agent**

Send: *"Use the `code-explorer` sub-agent to list the repo files and summarize each top-level folder."*

- [ ] **Step 3: Assert live nesting**

While the sub-agent runs, its inner `terminal`/`read` action+observation events appear **incrementally nested** under the "Sub-agent task" card. The card resolves to the `TaskObservation` summary + status, keeping the inner timeline.

- [ ] **Step 4: Assert isolation + separate directory**

```bash
CID=<parent_conversation_id>
# parent stream: only TaskAction + TaskObservation
curl -s "http://localhost:3000/api/v1/conversation/$CID/events/search?limit=100" \
 | python3 -c "import sys,json;d=json.load(sys.stdin);items=d.get('items',d);print(sorted({ (e.get('action') or e.get('observation') or {}).get('kind') for e in items}))"
# sub-stream endpoint returns the inner events
curl -s "http://localhost:3000/api/v1/conversation/$CID/subagents/<tool_call_id>/events" | python3 -m json.tool | head
# separate directory exists on disk
find ~/.openhands /var/folders -path "*$CID*/subagents/*/events/*.json" 2>/dev/null | head
```
Expected: parent stream shows only `TaskAction`/`TaskObservation`; sub-stream endpoint returns inner events; a separate `subagents/<tool_call_id>/events/` dir exists.

- [ ] **Step 5: Assert flag-off parity**

Restart without the flag (`./run-local.sh`), run the same prompt, confirm no sub-agent events are forwarded and the UI behaves exactly as before this feature.

- [ ] **Step 6: Run the full test suites**

```bash
cd /Users/vishalh/software-agent-sdk && pytest tests/sdk tests/tools tests/agent_server -q
cd /Users/vishalh/OpenHands && poetry run pytest tests/unit/app_server -q && (cd frontend && npx vitest run)
```
Expected: all green.

- [ ] **Step 7: Commit (if any fixups)**

```bash
git commit -am "test: e2e fixups for sub-agent event forwarding" || true
```

---

## Notes for the implementer

- **Two repos, two commit streams.** SDK changes commit in `/Users/vishalh/software-agent-sdk` (branch `feature/subagent-event-forwarding`); app-server/frontend changes commit in `/Users/vishalh/OpenHands` (branch `feature/subagent-event-forwarding`). Keep them in lockstep.
- **Signatures to verify on the real fork** before relying on them: `LocalConversation.__init__` `callbacks` parameter name (confirmed `callbacks`), `EventService._pub_sub.publish` coroutine signature, and the exact `_publish_stream_delta` direct-publish pattern (mirror it).
- **Upstream PR:** once green locally, the SDK branch becomes the upstream PR to `software-agent-sdk`; bump the OpenHands pins to the released version and drop the editable overrides from Task 0.
