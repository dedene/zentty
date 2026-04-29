#!/usr/bin/env python3
from __future__ import annotations

import argparse
import dataclasses
import fcntl
import json
import os
import pathlib
import plistlib
import pty
import re
import select
import shlex
import struct
import shutil
import socket
import subprocess
import sys
import termios
import tempfile
import threading
import time
import uuid
from typing import Any


SUPPORTED_AGENTS = ("claude", "codex", "copilot", "cursor", "droid", "gemini", "kimi", "opencode", "pi")
REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
BENCH_ROOT = pathlib.Path(__file__).resolve().parent
DEFAULT_RUNS_DIR = REPO_ROOT / ".agent-bench-runs"
ROUTING_ENV_KEYS = {
    "ZENTTY_WINDOW_ID",
    "ZENTTY_WORKLANE_ID",
    "ZENTTY_PANE_ID",
    "ZENTTY_INSTANCE_ID",
    "ZENTTY_AGENT_TOOL",
    "ZENTTY_CLAUDE_PID",
    "ZENTTY_CODEX_PID",
    "ZENTTY_COPILOT_PID",
    "ZENTTY_GEMINI_PID",
    "ZENTTY_CURSOR_PID",
    "ZENTTY_DROID_PID",
    "ZENTTY_KIMI_PID",
    "CODEX_HOME",
    "COPILOT_HOME",
    "KIMI_HOME",
    "GEMINI_CLI_SYSTEM_SETTINGS_PATH",
    "OPENCODE_CONFIG",
    "OPENCODE_CONFIG_DIR",
    "ZENTTY_OPENCODE_BASE_CONFIG_DIR",
    "HOME",
}
SECRET_ENV_PATTERNS = re.compile(r"(TOKEN|SECRET|PASSWORD|API_KEY|AUTH|KEY|CREDENTIAL|COOKIE)", re.I)
SENSITIVE_PAYLOAD_KEY_PATTERNS = re.compile(
    r"(TOKEN|SECRET|PASSWORD|API_KEY|AUTH|KEY|CREDENTIAL|COOKIE|EMAIL|USER_ID|USERID|ACCOUNT|TENANT|ORG_ID|ORGANIZATION_ID)",
    re.I,
)
EMAIL_PATTERN = re.compile(r"(?<![\w.+-])[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}(?![\w.-])")
USER_PATH_PATTERN = re.compile(r"/Users/[^/\\\s\"']+")
REFUSAL_PATTERNS = [
    r"\bI (?:can'?t|cannot|won'?t|am unable to)\b",
    r"\bI need (?:more|additional) (?:context|information)\b",
    r"\bwithout (?:more context|understanding|knowing)\b",
    r"\bplease (?:confirm|clarify)\b",
    r"\bcan you (?:confirm|clarify|tell me)\b",
]
OSC_TERMINAL_PATTERN = re.compile(r"\x1b\](?P<code>0|2|9);(?P<text>[^\x07\x1b]*)(?:\x07|\x1b\\)")


@dataclasses.dataclass
class ScenarioExpectation:
    name: str
    required_events: list[str]


@dataclasses.dataclass
class AgentProfile:
    name: str
    command: str
    real_binary_names: list[str]
    version_args: list[str]
    launch_args_by_scenario: dict[str, list[str]]
    expectations: dict[str, ScenarioExpectation]
    input_by_scenario: dict[str, list[dict[str, Any]]] = dataclasses.field(default_factory=dict)
    skip_patterns: list[str] = dataclasses.field(default_factory=list)


@dataclasses.dataclass
class HookEvent:
    adapter: str | None
    event_name: str | None


@dataclasses.dataclass
class TraceRecord:
    kind: str
    agent: str | None = None
    scenario: str | None = None
    event_name: str | None = None
    adapter: str | None = None
    subcommand: str | None = None
    arguments: list[str] | None = None
    standard_input: str | None = None
    environment: dict[str, str] | None = None
    timestamp: float = dataclasses.field(default_factory=time.time)
    extra: dict[str, Any] | None = None

    def as_json(self) -> dict[str, Any]:
        data = dataclasses.asdict(self)
        return {key: value for key, value in data.items() if value is not None}


@dataclasses.dataclass
class TerminalObservation:
    kind: str
    text: str
    offset: int
    timestamp: float | None = None


@dataclasses.dataclass
class ScenarioResult:
    agent: str
    scenario: str
    passed: bool
    missing_events: list[str]
    observed_events: list[str]
    status: str = "pass"
    detail: str = ""
    result_kind: str = "hook-pass"
    warnings: list[str] = dataclasses.field(default_factory=list)
    terminal_observations: list[dict[str, Any]] = dataclasses.field(default_factory=list)
    task_observations: list[dict[str, Any]] = dataclasses.field(default_factory=list)
    timeline: list[dict[str, Any]] = dataclasses.field(default_factory=list)
    rerun_command: str = ""


def compact_json(obj: Any) -> str:
    return json.dumps(obj, separators=(",", ":"))


def redacted_environment(environment: dict[str, str]) -> dict[str, str]:
    redacted: dict[str, str] = {}
    for key, value in environment.items():
        if key not in ROUTING_ENV_KEYS and not SECRET_ENV_PATTERNS.search(key):
            continue
        redacted[key] = "<redacted>" if SECRET_ENV_PATTERNS.search(key) else value
    return redacted


def redact_standard_input(raw: str | None) -> str | None:
    if raw is None:
        return None
    payload = parse_json_object(raw)
    if payload:
        return compact_json(redact_payload(payload))
    return redact_pii_text(raw)


def redact_payload(value: Any, key: str | None = None) -> Any:
    if key and SENSITIVE_PAYLOAD_KEY_PATTERNS.search(key):
        return "<redacted>"
    if isinstance(value, dict):
        return {str(child_key): redact_payload(child_value, str(child_key)) for child_key, child_value in value.items()}
    if isinstance(value, list):
        return [redact_payload(item) for item in value]
    if isinstance(value, str):
        return redact_pii_text(value)
    return value


def redact_pii_text(text: str) -> str:
    return USER_PATH_PATTERN.sub("/Users/<user>", EMAIL_PATTERN.sub("<redacted-email>", text))


def infer_hook_event(subcommand: str | None, arguments: list[str], standard_input: str | None) -> HookEvent:
    adapter: str | None = None
    positional: list[str] = []
    for argument in arguments:
        if argument.startswith("--adapter="):
            adapter = argument.split("=", 1)[1] or None
        else:
            positional.append(argument)
    if positional:
        return HookEvent(adapter=adapter, event_name=positional[0])

    payload = parse_json_object(standard_input)
    for key in (
        "hook_event_name",
        "hookEventName",
        "event",
        "eventName",
        "event_name",
        "type",
        "notification_type",
    ):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return HookEvent(adapter=adapter, event_name=value.strip())

    if subcommand == "agent-event":
        return HookEvent(adapter=adapter, event_name=None)
    return HookEvent(adapter=adapter, event_name=subcommand)


def parse_json_object(raw: str | None) -> dict[str, Any]:
    if not raw:
        return {}
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def validate_scenario(agent: str, expectation: ScenarioExpectation, records: list[TraceRecord]) -> ScenarioResult:
    observed = [record.event_name for record in records if record.agent == agent and record.scenario == expectation.name]
    observed_values = [event for event in observed if event]
    missing = [event for event in expectation.required_events if event not in observed_values]
    return ScenarioResult(
        agent=agent,
        scenario=expectation.name,
        passed=not missing,
        missing_events=missing,
        observed_events=observed_values,
        status="pass" if not missing else "fail",
        result_kind="hook-pass" if not missing else "missing-hook",
    )


def classify_completed_result(
    agent: str,
    scenario: str,
    expectation: ScenarioExpectation,
    records: list[TraceRecord],
    output: str,
    skip_patterns: list[str],
    exit_code: int,
    completed_by_predicate: bool,
    strict: bool,
) -> ScenarioResult:
    result = validate_scenario(agent, expectation, records)
    if not result.passed:
        if bench_marker_observed(output):
            result.passed = False
            result.status = "fail"
            result.detail = "bench command completed but required hooks were missing"
            result.result_kind = "missing-hook"
        elif matches_any(output, skip_patterns):
            result.passed = not strict
            result.status = "fail" if strict else "skip"
            result.detail = "auth or provider prerequisite not available"
            result.result_kind = "auth-skip"
        elif matches_any(output, REFUSAL_PATTERNS):
            result.passed = False
            result.status = "fail"
            result.detail = "agent refused or asked for clarification before reaching required hooks"
            result.result_kind = "agent-refusal"
        else:
            result.passed = False
            result.status = "fail"
            result.detail = "missing required hooks"
            result.result_kind = "missing-hook"
        return result
    if scenario_requires_task_observation(scenario) and not task_observations_for_records(agent, scenario, records):
        result.passed = False
        result.status = "fail"
        result.detail = "required lifecycle hooks observed but no TodoWrite task progress hook was captured"
        result.result_kind = "missing-task-hook"
        return result
    if exit_code != 0 and not completed_by_predicate:
        result.passed = False
        result.status = "fail"
        result.detail = f"process exited {exit_code}"
        result.result_kind = "missing-hook"
        return result
    if completed_by_predicate:
        result.detail = "required events observed"
    result.result_kind = "hook-pass"
    return result


def classify_timeout_result(
    agent: str,
    scenario: str,
    expectation: ScenarioExpectation,
    records: list[TraceRecord],
    output: str,
    skip_patterns: list[str],
    timeout: int,
    strict: bool,
) -> ScenarioResult:
    partial = validate_scenario(agent, expectation, records)
    if not partial.missing_events:
        if scenario_requires_task_observation(scenario) and not task_observations_for_records(agent, scenario, records):
            partial.passed = False
            partial.status = "fail"
            partial.detail = "required lifecycle hooks observed but no TodoWrite task progress hook was captured"
            partial.result_kind = "missing-task-hook"
        else:
            partial.passed = True
            partial.status = "pass"
            partial.detail = f"required events observed before {timeout}s timeout"
            partial.result_kind = "hook-pass"
            partial.warnings.append("process timed out after required hooks were observed")
    elif bench_marker_observed(output):
        partial.passed = False
        partial.status = "fail"
        partial.detail = "bench command completed but required hooks were missing"
        partial.result_kind = "missing-hook"
    elif matches_any(output, skip_patterns):
        partial.passed = not strict
        partial.status = "fail" if strict else "skip"
        partial.detail = "auth or provider prerequisite not available"
        partial.result_kind = "auth-skip"
    else:
        partial.passed = not strict
        partial.status = "fail" if strict else "skip"
        partial.detail = f"timed out after {timeout}s"
        partial.result_kind = "process-timeout"
    return partial


def extract_terminal_observations(output: str, timestamp: float | None = None) -> list[TerminalObservation]:
    observations: list[TerminalObservation] = []
    for match in OSC_TERMINAL_PATTERN.finditer(output):
        code = match.group("code")
        text = match.group("text").strip()
        if not text:
            continue
        kind = "osc9" if code == "9" else "title"
        observations.append(TerminalObservation(kind=kind, text=text, offset=match.start(), timestamp=timestamp))
        if kind == "title" and is_progress_text(text):
            observations.append(TerminalObservation(kind="progress", text=text, offset=match.start(), timestamp=timestamp))
    return observations


def is_progress_text(text: str) -> bool:
    return bool(re.search(r"\b(running|working|thinking|waiting|asking|question|approval|needs? input)\b|\d+\s*/\s*\d+", text, flags=re.I))


def build_timeline(
    agent: str,
    scenario: str,
    records: list[TraceRecord],
    observations: list[TerminalObservation],
) -> list[dict[str, Any]]:
    matching_records = [record for record in records if record.agent == agent and record.scenario == scenario]
    observation_timestamps = [observation.timestamp for observation in observations if observation.timestamp is not None]
    base = min(
        [record.timestamp for record in matching_records] + observation_timestamps,
        default=time.time(),
    )
    timeline: list[dict[str, Any]] = []
    for record in matching_records:
        source = "hook" if record.kind == "hook" else "process"
        event = record.event_name or record.kind
        entry: dict[str, Any] = {
            "time_ms": max(0, int(round((record.timestamp - base) * 1000))),
            "source": source,
            "event": event,
        }
        if record.adapter:
            entry["adapter"] = record.adapter
        if record.extra:
            entry["detail"] = record.extra
        timeline.append(entry)
    legacy_terminal_time_ms = max((entry["time_ms"] for entry in timeline), default=0)
    for observation in observations:
        terminal_time_ms = (
            max(0, int(round((observation.timestamp - base) * 1000)))
            if observation.timestamp is not None
            else legacy_terminal_time_ms
        )
        timeline.append(
            {
                "time_ms": terminal_time_ms,
                "source": "terminal",
                "event": observation.kind,
                "text": observation.text,
                "offset": observation.offset,
            }
        )
    return sorted(timeline, key=lambda entry: (entry["time_ms"], source_sort_key(str(entry["source"]))))


def source_sort_key(source: str) -> int:
    return {"process": 0, "hook": 1, "terminal": 2}.get(source, 3)


def scenario_requires_task_observation(scenario: str) -> bool:
    return scenario == "tasks"


def task_observations_for_records(agent: str, scenario: str, records: list[TraceRecord]) -> list[dict[str, Any]]:
    observations: list[dict[str, Any]] = []
    for record in records:
        if record.agent != agent or record.scenario != scenario or record.kind != "hook":
            continue
        payload = parse_json_object(record.standard_input)
        tool_name = first_string(payload, ["tool_name", "toolName", "tool"])
        if not tool_name or tool_name.lower() != "todowrite":
            continue
        tool_input = first_object(payload, ["tool_input", "toolInput", "input"])
        progress = todo_progress(tool_input)
        if not progress:
            continue
        observations.append(
            {
                "event": record.event_name or "",
                "tool": tool_name,
                "done": progress[0],
                "total": progress[1],
            }
        )
    return observations


def todo_progress(tool_input: dict[str, Any] | None) -> tuple[int, int] | None:
    if not tool_input:
        return None
    todos = tool_input.get("todos")
    if isinstance(todos, list):
        statuses: list[str] = []
        for todo in todos:
            if isinstance(todo, dict):
                status = first_string(todo, ["status", "state"])
                if status:
                    statuses.append(status)
        if statuses:
            return (sum(1 for status in statuses if todo_status_is_complete(status)), len(statuses))
        return None
    if isinstance(todos, str):
        return todo_progress_from_text(todos)
    return None


def todo_progress_from_text(text: str) -> tuple[int, int] | None:
    total = 0
    done = 0
    saw_line = False
    for raw_line in text.splitlines():
        line = raw_line.strip().lower()
        if not line:
            continue
        saw_line = True
        if "[completed]" in line or "[done]" in line or "[x]" in line:
            total += 1
            done += 1
        elif "[in_progress]" in line or "[in-progress]" in line or "[pending]" in line or "[ ]" in line:
            total += 1
    if total == 0 and saw_line:
        return None
    return (done, total) if total > 0 else None


def todo_status_is_complete(status: str) -> bool:
    return status.strip().lower() in {"completed", "complete", "done"}


def first_string(mapping: dict[str, Any], keys: list[str]) -> str | None:
    for key in keys:
        value = mapping.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def first_object(mapping: dict[str, Any], keys: list[str]) -> dict[str, Any] | None:
    for key in keys:
        value = mapping.get(key)
        if isinstance(value, dict):
            return value
    return None


class TraceRecorder:
    def __init__(self, run_dir: pathlib.Path) -> None:
        self.run_dir = run_dir
        self.run_dir.mkdir(parents=True, exist_ok=True)
        self.trace_path = self.run_dir / "trace.jsonl"
        self._records: list[TraceRecord] = []
        self._lock = threading.Lock()

    def append(self, record: TraceRecord) -> None:
        with self._lock:
            self._records.append(record)
            with self.trace_path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(record.as_json(), sort_keys=True) + "\n")

    def records(self) -> list[TraceRecord]:
        with self._lock:
            return list(self._records)

    def wait_for_count(self, count: int, timeout: float = 2.0) -> list[TraceRecord]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            records = self.records()
            if len(records) >= count:
                return records
            time.sleep(0.01)
        return self.records()


class CaptureServer:
    def __init__(
        self,
        socket_path: pathlib.Path,
        recorder: TraceRecorder,
        profiles: dict[str, AgentProfile],
        scenario: str,
        resources_dir: pathlib.Path | None = None,
        run_dir: pathlib.Path | None = None,
    ) -> None:
        self.socket_path = socket_path
        self.recorder = recorder
        self.profiles = profiles
        self.scenario = scenario
        self.resources_dir = resources_dir
        self.run_dir = run_dir or socket_path.parent
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._active = 0
        self._active_lock = threading.Lock()

    def start(self) -> None:
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self.socket_path.unlink()
        except FileNotFoundError:
            pass
        self._thread = threading.Thread(target=self._serve, name="agent-bench-capture", daemon=True)
        self._thread.start()
        for _ in range(100):
            if self.socket_path.exists() and self._can_connect():
                return
            time.sleep(0.01)
        raise RuntimeError(f"Capture server did not create socket at {self.socket_path}")

    def _can_connect(self) -> bool:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(0.05)
                client.connect(str(self.socket_path))
            return True
        except OSError:
            return False

    def stop(self) -> None:
        self._stop.set()
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(0.1)
                client.connect(str(self.socket_path))
        except OSError:
            pass
        if self._thread:
            self._thread.join(timeout=2)
        try:
            self.socket_path.unlink()
        except FileNotFoundError:
            pass

    def wait_for_idle(self, timeout: float = 2.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self._active_lock:
                if self._active == 0:
                    return
            time.sleep(0.01)

    def _serve(self) -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(str(self.socket_path))
            server.listen()
            server.settimeout(0.1)
            while not self._stop.is_set():
                try:
                    connection, _ = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                threading.Thread(target=self._handle_connection, args=(connection,), daemon=True).start()

    def _handle_connection(self, connection: socket.socket) -> None:
        with self._active_lock:
            self._active += 1
        try:
            with connection:
                data = self._read_frame(connection)
                if not data:
                    return
                request = json.loads(data.decode("utf-8"))
                response = self._handle_request(request)
                if request.get("expectsResponse"):
                    connection.sendall(json.dumps(response).encode("utf-8") + b"\n")
        finally:
            with self._active_lock:
                self._active -= 1

    def _read_frame(self, connection: socket.socket) -> bytes:
        chunks: list[bytes] = []
        while True:
            chunk = connection.recv(4096)
            if not chunk:
                break
            if b"\n" in chunk:
                before, _, _ = chunk.partition(b"\n")
                chunks.append(before)
                break
            chunks.append(chunk)
        return b"".join(chunks)

    def _handle_request(self, request: dict[str, Any]) -> dict[str, Any]:
        kind = request.get("kind")
        if kind == "bootstrap":
            return self._bootstrap_response(request)
        if kind == "ipc":
            self._record_ipc(request)
        return {"version": 1, "id": request.get("id", ""), "ok": True, "result": {}, "error": None}

    def _bootstrap_response(self, request: dict[str, Any]) -> dict[str, Any]:
        tool = request.get("tool")
        if not isinstance(tool, str) or tool not in self.profiles:
            return self._error_response(request, f"Unsupported bootstrap tool: {tool}")
        plan = LaunchPlanner(
            profile=self.profiles[tool],
            scenario=self.scenario,
            run_dir=self.run_dir,
            resources_dir=self.resources_dir,
        ).plan(request)
        self.recorder.append(TraceRecord(kind="bootstrap", agent=tool, scenario=self.scenario, extra={"plan": plan}))
        return {
            "version": 1,
            "id": request.get("id", ""),
            "ok": True,
            "result": {"launchPlan": plan},
            "error": None,
        }

    def _error_response(self, request: dict[str, Any], message: str) -> dict[str, Any]:
        return {
            "version": 1,
            "id": request.get("id", ""),
            "ok": False,
            "result": None,
            "error": {"code": "agent_bench_error", "message": message},
        }

    def _record_ipc(self, request: dict[str, Any]) -> None:
        args = request.get("arguments") if isinstance(request.get("arguments"), list) else []
        stdin_payload = request.get("standardInput")
        subcommand = request.get("subcommand")
        environment = request.get("environment") if isinstance(request.get("environment"), dict) else {}
        hook = infer_hook_event(subcommand, [str(arg) for arg in args], stdin_payload if isinstance(stdin_payload, str) else None)
        agent = agent_from_adapter(hook.adapter, environment, stdin_payload if isinstance(stdin_payload, str) else None)
        self.recorder.append(
            TraceRecord(
                kind="hook",
                agent=agent,
                scenario=self.scenario,
                event_name=hook.event_name,
                adapter=hook.adapter,
                subcommand=subcommand,
                arguments=[str(arg) for arg in args],
                standard_input=redact_standard_input(stdin_payload if isinstance(stdin_payload, str) else None),
                environment=redacted_environment({str(k): str(v) for k, v in environment.items()}),
            )
        )


class LaunchPlanner:
    def __init__(
        self,
        profile: AgentProfile,
        scenario: str,
        run_dir: pathlib.Path,
        resources_dir: pathlib.Path | None,
    ) -> None:
        self.profile = profile
        self.scenario = scenario
        self.run_dir = run_dir
        self.resources_dir = resources_dir

    def plan(self, request: dict[str, Any]) -> dict[str, Any]:
        environment = request.get("environment") if isinstance(request.get("environment"), dict) else {}
        executable = str(environment.get("ZENTTY_REAL_BINARY") or self.profile.command)
        arguments = [str(arg) for arg in request.get("arguments", [])]
        cli_path = str(environment.get("ZENTTY_CLI_BIN") or "")
        method = getattr(self, f"_plan_{self.profile.name}", self._direct_plan)
        return method(executable, arguments, environment, cli_path)

    def _direct_plan(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        return self._launch_plan(executable, arguments, {"ZENTTY_AGENT_TOOL": self.profile.name})

    def _plan_claude(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        hook_command = f'"{shell_escape_double_quoted(cli_path)}" ipc agent-event --adapter=claude'
        settings = {"hooks": {}}
        for event in ("Stop", "SessionEnd", "Notification", "PermissionRequest", "UserPromptSubmit", "TaskCreated", "TaskCompleted"):
            settings["hooks"][event] = [{"matcher": "", "hooks": [{"type": "command", "command": hook_command, "timeout": 10}]}]
        settings["hooks"]["SessionStart"] = [
            {"matcher": matcher, "hooks": [{"type": "command", "command": hook_command, "timeout": 10}]}
            for matcher in ("startup", "resume", "clear", "compact")
        ]
        settings["hooks"]["PreToolUse"] = [
            {"matcher": matcher, "hooks": [{"type": "command", "command": hook_command, "timeout": 5}]}
            for matcher in ("AskUserQuestion", "Bash|Write|Edit|MultiEdit|NotebookEdit")
        ]
        planned = ["--session-id", str(uuid.uuid4()).lower(), "--settings", compact_json(settings)] + arguments
        return self._launch_plan(executable, planned, {"ZENTTY_AGENT_TOOL": "claude"}, unset=["CLAUDECODE"])

    def _plan_codex(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        overlay = self._overlay_dir("codex") / "home"
        source = config_source_dir(environment, "CODEX_HOME", ".codex")
        symlink_directory_contents_skipping(source, overlay, {"hooks.json"})
        hooks = {
            "hooks": {
                event: [{"hooks": [{"type": "command", "command": f'"{shell_escape_double_quoted(cli_path)}" ipc agent-event --adapter=codex {arg} || echo \'{{}}\'', "timeout": 10}]}]
                for event, arg in {
                    "SessionStart": "session-start",
                    "PreToolUse": "pre-tool-use",
                    "PermissionRequest": "permission-request",
                    "PostToolUse": "post-tool-use",
                    "UserPromptSubmit": "prompt-submit",
                    "Stop": "stop",
                }.items()
            }
        }
        write_json(overlay / "hooks.json", hooks)
        planned = [
            "-c",
            f'notify={toml_string_array([cli_path, "codex-notify"])}',
            "-c",
            "features.codex_hooks=true",
            "-c",
            "tui.notification_method=osc9",
            "-c",
            'tui.terminal_title=["status","spinner","project","task-progress"]',
        ] + arguments
        return self._launch_plan(executable, planned, {"ZENTTY_AGENT_TOOL": "codex", "CODEX_HOME": str(overlay)})

    def _plan_copilot(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        overlay = self._overlay_dir("copilot") / "home"
        source = config_source_dir(environment, "COPILOT_HOME", ".copilot")
        symlink_directory_contents_skipping(source, overlay, {"config.json"})
        config = read_json_object(source / "config.json")
        config["version"] = 1
        hooks = config.get("hooks") if isinstance(config.get("hooks"), dict) else {}
        for event, arg, timeout in (
            ("sessionStart", "session-start", 10),
            ("sessionEnd", "session-end", 10),
            ("userPromptSubmitted", "user-prompt-submitted", 10),
            ("preToolUse", "pre-tool-use", 5),
            ("postToolUse", "post-tool-use", 5),
            ("errorOccurred", "error-occurred", 10),
        ):
            command = f'"{shell_escape_double_quoted(cli_path)}" ipc agent-event --adapter=copilot {arg} || true'
            entries = hooks.get(event) if isinstance(hooks.get(event), list) else []
            if not any(isinstance(entry, dict) and entry.get("type") == "command" and entry.get("bash") == command for entry in entries):
                entries.append({"type": "command", "bash": command, "timeoutSec": timeout})
            hooks[event] = entries
        config["hooks"] = hooks
        write_json(overlay / "config.json", config)
        return self._launch_plan(executable, arguments, {"ZENTTY_AGENT_TOOL": "copilot", "COPILOT_HOME": str(overlay)})

    def _plan_cursor(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        home = self._overlay_home("cursor", environment, {".cursor": {"hooks.json"}})
        config_dir = home / ".cursor"
        hooks = {"version": 1, "hooks": {}}
        command = f'"{shell_escape_double_quoted(cli_path)}" ipc agent-event --adapter=cursor'
        for event in ("sessionStart", "sessionEnd", "beforeSubmitPrompt", "stop", "beforeShellExecution", "afterShellExecution"):
            hooks["hooks"][event] = [{"command": command}]
        for event in ("preToolUse", "postToolUse"):
            hooks["hooks"][event] = [{"matcher": "TodoWrite", "command": command}]
        write_json(config_dir / "hooks.json", hooks)
        return self._launch_plan(executable, arguments, {"ZENTTY_AGENT_TOOL": "cursor", "CURSOR_CONFIG_DIR": str(config_dir)})

    def _plan_droid(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        home = self._overlay_home("droid", environment, {".factory": {"settings.local.json", "hooks"}})
        command = f'"{shell_escape_double_quoted(cli_path)}" ipc agent-event --adapter=droid'
        hooks = {
            event: [{"hooks": [{"type": "command", "command": command, "timeout": 10}]}]
            for event in ("SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SubagentStop")
        }
        write_json(home / ".factory" / "settings.local.json", {"hooks": hooks})
        write_json(home / ".factory" / "hooks" / "hooks.json", {"showHookOutput": False})
        return self._launch_plan(executable, arguments, {"ZENTTY_AGENT_TOOL": "droid", "HOME": str(home)})

    def _plan_gemini(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        overlay = self._overlay_dir("gemini") / "settings.json"
        command = f'"{shell_escape_double_quoted(cli_path)}" gemini-hook || echo \'{{}}\''
        hooks = {
            event: [{"matcher": "*", "hooks": [{"type": "command", "command": command, "timeout": timeout}]}]
            for event, timeout in (
                ("SessionStart", 10000),
                ("SessionEnd", 1000),
                ("BeforeAgent", 10000),
                ("AfterAgent", 10000),
                ("Notification", 10000),
                ("BeforeTool", 5000),
            )
        }
        write_json(overlay, {"general": {"enableNotifications": True}, "hooks": hooks})
        return self._launch_plan(executable, arguments, {"ZENTTY_AGENT_TOOL": "gemini", "GEMINI_CLI_SYSTEM_SETTINGS_PATH": str(overlay)})

    def _plan_kimi(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        overlay = self._overlay_dir("kimi") / "config.toml"
        command = toml_basic_string(f'"{shell_escape_double_quoted(cli_path)}" ipc agent-event --adapter=kimi')
        entries = "\n".join(f'[[hooks]]\nevent = "{event}"\ncommand = "{command}"\n' for event in ("SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "Notification", "PreToolUse", "PostToolUse"))
        source = config_source_dir(environment, "KIMI_HOME", ".kimi") / "config.toml"
        existing = remove_top_level_toml_key(source.read_text(encoding="utf-8"), "hooks") if source.exists() else ""
        overlay.parent.mkdir(parents=True, exist_ok=True)
        separator = "\n\n" if existing.strip() else ""
        overlay.write_text(existing.rstrip() + separator + entries, encoding="utf-8")
        return self._launch_plan(executable, ["--config-file", str(overlay)] + arguments, {"ZENTTY_AGENT_TOOL": "kimi"})

    def _plan_opencode(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        overlay = self._overlay_dir("opencode") / "config"
        source_path = str(environment.get("OPENCODE_CONFIG_DIR") or "").strip()
        source = pathlib.Path(source_path) if source_path else None
        if source:
            copy_directory_contents(source, overlay)
        plugin = self.resources_dir / "opencode" / "plugins" / "zentty-opencode-zentty.js" if self.resources_dir else None
        if plugin and plugin.exists():
            plugins = overlay / "plugins"
            plugins.mkdir(parents=True, exist_ok=True)
            shutil.copy2(plugin, plugins / plugin.name)
        config_file = overlay / "opencode.json"
        if self.scenario == "approval":
            config = read_json_object(config_file)
            permission = config.get("permission") if isinstance(config.get("permission"), dict) else {}
            permission["bash"] = "ask"
            config["permission"] = permission
            write_json(config_file, config)
        prelaunch = '{"version":1,"event":"session.start","agent":{"name":"OpenCode","pid":"__ZENTTY_SELF_PID__"}}'
        return self._launch_plan(
            executable,
            arguments,
            {
                "ZENTTY_AGENT_TOOL": "opencode",
                "OPENCODE_CONFIG": str(config_file),
                "OPENCODE_CONFIG_DIR": str(overlay),
                "ZENTTY_OPENCODE_BASE_CONFIG_DIR": str(source or ""),
            },
            prelaunch=[{"subcommand": "agent-event", "arguments": [], "standardInput": prelaunch}],
        )

    def _plan_pi(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        planned = list(arguments)
        extension = self.resources_dir / "pi" / "extensions" / "zentty-pi-zentty.js" if self.resources_dir else None
        if extension and extension.exists():
            planned = ["-e", str(extension)] + planned
        prelaunch = '{"version":1,"event":"session.start","agent":{"name":"Pi","pid":"__ZENTTY_SELF_PID__"}}'
        return self._launch_plan(
            executable,
            planned,
            {"ZENTTY_AGENT_TOOL": "pi"},
            prelaunch=[{"subcommand": "agent-event", "arguments": [], "standardInput": prelaunch}],
        )

    def _launch_plan(
        self,
        executable: str,
        arguments: list[str],
        set_env: dict[str, str],
        unset: list[str] | None = None,
        prelaunch: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        return {
            "executablePath": executable,
            "arguments": arguments,
            "setEnvironment": set_env,
            "unsetEnvironment": unset or [],
            "preLaunchActions": prelaunch or [],
        }

    def _overlay_dir(self, agent: str) -> pathlib.Path:
        path = self.run_dir / "overlays" / self.scenario / agent
        path.mkdir(parents=True, exist_ok=True)
        return path

    def _overlay_home(self, agent: str, environment: dict[str, Any], names: dict[str, set[str]]) -> pathlib.Path:
        home = self._overlay_dir(agent) / "home"
        home.mkdir(parents=True, exist_ok=True)
        source_home = pathlib.Path(str(environment.get("HOME") or pathlib.Path.home()))
        for name, skipping in names.items():
            symlink_directory_contents_skipping(source_home / name, home / name, skipping)
        return home


def agent_from_adapter(adapter: str | None, environment: dict[str, Any], standard_input: str | None = None) -> str | None:
    if adapter == "codex-notify":
        return "codex"
    if adapter in SUPPORTED_AGENTS:
        return adapter
    tool = environment.get("ZENTTY_AGENT_TOOL")
    if tool:
        return str(tool)
    agent_name = parse_json_object(standard_input).get("agent")
    if isinstance(agent_name, dict):
        normalized = str(agent_name.get("name") or "").strip().lower().replace(" ", "")
        if normalized == "claudecode":
            return "claude"
        if normalized == "opencode":
            return "opencode"
        if normalized in SUPPORTED_AGENTS:
            return normalized
    return adapter


def load_profiles(path: pathlib.Path) -> dict[str, AgentProfile]:
    profiles: dict[str, AgentProfile] = {}
    for profile_path in sorted(path.glob("*.json")):
        raw = json.loads(profile_path.read_text(encoding="utf-8"))
        expectations = {
            name: ScenarioExpectation(name=name, required_events=list(value.get("required_events", [])))
            for name, value in raw.get("expectations", {}).items()
        }
        profile = AgentProfile(
            name=raw["name"],
            command=raw["command"],
            real_binary_names=list(raw.get("real_binary_names", [raw["command"]])),
            version_args=list(raw.get("version_args", ["--version"])),
            launch_args_by_scenario={name: list(args) for name, args in raw.get("launch_args_by_scenario", {}).items()},
            expectations=expectations,
            input_by_scenario={name: list(values) for name, values in raw.get("input_by_scenario", {}).items()},
            skip_patterns=list(raw.get("skip_patterns", [])),
        )
        profiles[profile.name] = profile
    return profiles


class BenchRunner:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.profiles = load_profiles(BENCH_ROOT / "profiles")
        self.run_dir = pathlib.Path(args.run_dir) if args.run_dir else DEFAULT_RUNS_DIR / time.strftime("%Y%m%d-%H%M%S")
        self.run_dir.mkdir(parents=True, exist_ok=True)
        self.socket_dir = pathlib.Path(tempfile.mkdtemp(prefix="zentty-agent-bench-sock-"))
        self.recorder = TraceRecorder(self.run_dir)

    def run(self) -> int:
        try:
            agents = self._selected_agents()
            app_path = pathlib.Path(self.args.app_path).expanduser() if self.args.app_path else self._resolve_app_path()
            self._resolved_app_path = app_path
            resources_dir = app_path / "Contents" / "Resources"
            env = self._base_environment(resources_dir)
            results: list[ScenarioResult] = []
            for scenario in self.args.scenarios.split(","):
                scenario = scenario.strip()
                if not scenario:
                    continue
                server = CaptureServer(
                    self.socket_dir / f"{scenario}.sock",
                    recorder=self.recorder,
                    profiles=self.profiles,
                    scenario=scenario,
                    resources_dir=resources_dir,
                    run_dir=self.run_dir,
                )
                server.start()
                try:
                    scenario_env = dict(env)
                    scenario_env["ZENTTY_INSTANCE_SOCKET"] = str(server.socket_path)
                    for agent in agents:
                        results.append(self._run_agent_scenario(agent, scenario, scenario_env))
                finally:
                    server.stop()
            self._write_report(results)
            return 1 if any(result.status == "fail" for result in results) else 0
        finally:
            self._cleanup_socket_dir()

    def self_test(self) -> int:
        try:
            app_path = pathlib.Path(self.args.app_path).expanduser() if self.args.app_path else self._resolve_app_path()
            self._resolved_app_path = app_path
            resources_dir = app_path / "Contents" / "Resources"
            zentty = resources_dir / "bin" / "shared" / "zentty"
            profile = self.profiles["codex"]
            server = CaptureServer(
                self.socket_dir / "self-test.sock",
                recorder=self.recorder,
                profiles={"codex": profile},
                scenario="smoke",
                resources_dir=resources_dir,
                run_dir=self.run_dir,
            )
            server.start()
            try:
                env = self._base_environment(resources_dir)
                env["ZENTTY_INSTANCE_SOCKET"] = str(server.socket_path)
                env["ZENTTY_REAL_BINARY"] = "/usr/bin/true"
                request = {
                    "version": 1,
                    "id": "self-test-bootstrap",
                    "kind": "bootstrap",
                    "arguments": ["exec", "hello"],
                    "standardInput": None,
                    "environment": {
                        "ZENTTY_CLI_BIN": str(zentty),
                        "ZENTTY_REAL_BINARY": "/usr/bin/true",
                        "HOME": env["HOME"],
                    },
                    "expectsResponse": True,
                    "subcommand": None,
                    "tool": "codex",
                }
                send_ipc(server.socket_path, request)
                hook = {
                    "version": 1,
                    "id": "self-test-hook",
                    "kind": "ipc",
                    "arguments": ["--adapter=codex", "pre-tool-use"],
                    "standardInput": "{}",
                    "environment": {"ZENTTY_PANE_ID": "pane-self-test"},
                    "expectsResponse": False,
                    "subcommand": "agent-event",
                    "tool": None,
                }
                send_ipc(server.socket_path, hook)
                server.wait_for_idle()
            finally:
                server.stop()
            records = self.recorder.records()
            if not any(record.kind == "bootstrap" for record in records):
                print("self-test failed: bootstrap was not recorded", file=sys.stderr)
                return 1
            if not any(record.event_name == "pre-tool-use" for record in records):
                print("self-test failed: hook was not recorded", file=sys.stderr)
                return 1
            self._write_report([self._finalize_result(ScenarioResult("codex", "self-test", True, [], ["pre-tool-use"]), [], [])])
            print(f"self-test passed: {self.run_dir}")
            return 0
        finally:
            self._cleanup_socket_dir()

    def _cleanup_socket_dir(self) -> None:
        try:
            self.socket_dir.rmdir()
        except OSError:
            pass

    def _run_agent_scenario(self, agent: str, scenario: str, env: dict[str, str]) -> ScenarioResult:
        profile = self.profiles[agent]
        if scenario not in profile.expectations:
            return self._finalize_result(
                ScenarioResult(agent, scenario, True, [], [], status="skip", detail="scenario not defined", result_kind="scenario-skip"),
                [],
                [],
            )
        command = shutil.which(profile.command, path=env["PATH"])
        if not command:
            return self._finalize_result(self._skip_or_fail(agent, scenario, f"{profile.command} not found", "binary-skip"), [], [])
        version = run_version(command, profile.version_args, env)
        self.recorder.append(TraceRecord(kind="version", agent=agent, scenario=scenario, extra={"version": version}))
        argv = [command] + profile.launch_args_by_scenario.get(scenario, [])
        transcript_path = self.run_dir / f"{agent}-{scenario}.terminal.log"
        expectation = profile.expectations[scenario]
        completed = run_pty(
            argv,
            env=env,
            cwd=self._make_repo(agent, scenario),
            inputs=profile.input_by_scenario.get(scenario, []),
            timeout=self.args.timeout,
            transcript_path=transcript_path,
            completion_predicate=lambda: not validate_scenario(agent, expectation, self.recorder.records()).missing_events,
        )
        observations = completed.terminal_observations
        if completed.timed_out:
            result = classify_timeout_result(
                agent=agent,
                scenario=scenario,
                expectation=expectation,
                records=self.recorder.records(),
                output=completed.output,
                skip_patterns=profile.skip_patterns,
                timeout=self.args.timeout,
                strict=self.args.strict,
            )
            return self._finalize_result(result, self.recorder.records(), observations)
        result = classify_completed_result(
            agent=agent,
            scenario=scenario,
            expectation=expectation,
            records=self.recorder.records(),
            output=completed.output,
            skip_patterns=profile.skip_patterns,
            exit_code=completed.exit_code,
            completed_by_predicate=completed.completed_by_predicate,
            strict=self.args.strict,
        )
        return self._finalize_result(result, self.recorder.records(), observations)

    def _skip_or_fail(self, agent: str, scenario: str, detail: str, result_kind: str = "scenario-skip") -> ScenarioResult:
        return ScenarioResult(
            agent,
            scenario,
            not self.args.strict,
            [],
            [],
            status="fail" if self.args.strict else "skip",
            detail=detail,
            result_kind=result_kind,
        )

    def _finalize_result(
        self,
        result: ScenarioResult,
        records: list[TraceRecord],
        observations: list[TerminalObservation],
    ) -> ScenarioResult:
        result.terminal_observations = [dataclasses.asdict(observation) for observation in observations]
        result.task_observations = task_observations_for_records(result.agent, result.scenario, records)
        result.timeline = build_timeline(result.agent, result.scenario, records, observations)
        result.rerun_command = self._rerun_command(result.agent, result.scenario)
        if observations and not any(warning.startswith("terminal observations") for warning in result.warnings):
            result.warnings.append(f"terminal observations captured: {len(observations)}")
        if result.task_observations and not any(warning.startswith("task observations") for warning in result.warnings):
            result.warnings.append(f"task observations captured: {len(result.task_observations)}")
        return result

    def _rerun_command(self, agent: str, scenario: str) -> str:
        app_path = getattr(self, "_resolved_app_path", None) or self.args.app_path
        if scenario == "self-test":
            parts = [
                "python3",
                "scripts/agent-bench/agent_bench.py",
                "self-test",
                "--timeout",
                str(self.args.timeout),
                "--no-build",
            ]
            if app_path:
                parts.extend(["--app-path", str(app_path)])
            return " ".join(shlex.quote(part) for part in parts)
        parts = [
            "python3",
            "scripts/agent-bench/agent_bench.py",
            "run",
            "--agents",
            agent,
            "--scenarios",
            scenario,
            "--timeout",
            str(self.args.timeout),
            "--no-build",
        ]
        if app_path:
            parts.extend(["--app-path", str(app_path)])
        if self.args.strict:
            parts.append("--strict")
        return " ".join(shlex.quote(part) for part in parts)

    def _make_repo(self, agent: str, scenario: str) -> pathlib.Path:
        repo = self.run_dir / "repos" / f"{agent}-{scenario}"
        repo.mkdir(parents=True, exist_ok=True)
        (repo / "README.md").write_text("Zentty agent bench temporary repository.\n", encoding="utf-8")
        subprocess.run(["git", "init"], cwd=repo, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return repo

    def _selected_agents(self) -> list[str]:
        raw = self.args.agents.strip()
        if raw == "all":
            return list(SUPPORTED_AGENTS)
        selected = [item.strip() for item in raw.split(",") if item.strip()]
        unknown = [agent for agent in selected if agent not in self.profiles]
        if unknown:
            raise SystemExit(f"Unknown agent(s): {', '.join(unknown)}")
        return selected

    def _resolve_app_path(self) -> pathlib.Path:
        if self.args.no_build:
            candidate = REPO_ROOT / "build" / "Debug" / "Zentty.app"
            if candidate.exists():
                return candidate
            raise SystemExit("--no-build requires --app-path when build/Debug/Zentty.app is absent")
        subprocess.run(["xcodebuild", "-project", "Zentty.xcodeproj", "-scheme", "Zentty", "-destination", "platform=macOS", "build"], cwd=REPO_ROOT, check=True)
        settings = subprocess.run(
            ["xcodebuild", "-project", "Zentty.xcodeproj", "-scheme", "Zentty", "-showBuildSettings"],
            cwd=REPO_ROOT,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        ).stdout
        values = parse_build_settings(settings)
        return pathlib.Path(values["BUILT_PRODUCTS_DIR"]) / values.get("FULL_PRODUCT_NAME", "Zentty.app")

    def _base_environment(self, resources_dir: pathlib.Path) -> dict[str, str]:
        env = os.environ.copy()
        wrapper_dirs = [resources_dir / "bin" / agent for agent in SUPPORTED_AGENTS]
        wrapper_dirs = [path for path in wrapper_dirs if path.exists()]
        shared = resources_dir / "bin" / "shared"
        inherited_path = filtered_inherited_path(env.get("PATH", ""))
        env["PATH"] = os.pathsep.join([*(str(path) for path in wrapper_dirs), str(shared), inherited_path])
        env["ZENTTY_CLI_BIN"] = str(shared / "zentty")
        env["ZENTTY_ALL_WRAPPER_BIN_DIRS"] = os.pathsep.join(str(path) for path in wrapper_dirs)
        env["ZENTTY_WRAPPER_BIN_DIRS"] = env["ZENTTY_ALL_WRAPPER_BIN_DIRS"]
        env["ZENTTY_WINDOW_ID"] = "bench-window"
        env["ZENTTY_WORKLANE_ID"] = "bench-worklane"
        env["ZENTTY_PANE_ID"] = "bench-pane"
        env["ZENTTY_PANE_TOKEN"] = "bench-pane-token"
        env["ZENTTY_INSTANCE_ID"] = "agent-bench"
        return env

    def _write_report(self, results: list[ScenarioResult]) -> None:
        summary = [dataclasses.asdict(result) for result in results]
        write_json(self.run_dir / "summary.json", summary)
        timeline = [
            {"agent": result.agent, "scenario": result.scenario, **entry}
            for result in results
            for entry in result.timeline
        ]
        write_json(self.run_dir / "timeline.json", timeline)
        lines = ["# Agent Bench Report", ""]
        for result in results:
            marker = {"pass": "PASS", "fail": "FAIL", "skip": "SKIP"}[result.status]
            detail = f" - {result.detail}" if result.detail else ""
            lines.append(f"- {marker} {result.agent}/{result.scenario}{detail}")
            lines.append(f"  Result kind: {result.result_kind}")
            if result.missing_events:
                lines.append(f"  Missing: {', '.join(result.missing_events)}")
            if result.observed_events:
                lines.append(f"  Observed: {', '.join(result.observed_events)}")
            if result.warnings:
                lines.append(f"  Warnings: {'; '.join(result.warnings)}")
            if result.terminal_observations:
                observations = ", ".join(f"{item['kind']}={item['text']}" for item in result.terminal_observations[:3])
                suffix = "..." if len(result.terminal_observations) > 3 else ""
                lines.append(f"  Terminal: {observations}{suffix}")
            if result.task_observations:
                tasks = ", ".join(
                    f"{item['event']}:{item['done']}/{item['total']}"
                    for item in result.task_observations[:3]
                )
                suffix = "..." if len(result.task_observations) > 3 else ""
                lines.append(f"  Tasks: {tasks}{suffix}")
            if result.rerun_command:
                lines.append(f"  Rerun: {result.rerun_command}")
        (self.run_dir / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"report: {self.run_dir / 'report.md'}")


@dataclasses.dataclass
class PtyResult:
    exit_code: int
    timed_out: bool
    output: str
    completed_by_predicate: bool = False
    terminal_observations: list[TerminalObservation] = dataclasses.field(default_factory=list)


def run_pty(
    argv: list[str],
    env: dict[str, str],
    cwd: pathlib.Path,
    inputs: list[dict[str, Any]],
    timeout: int,
    transcript_path: pathlib.Path,
    completion_predicate: Any | None = None,
) -> PtyResult:
    master, slave = pty.openpty()
    set_pty_window_size(slave, rows=40, columns=120)
    env = dict(env)
    env.setdefault("TERM", "xterm-256color")
    env.setdefault("LINES", "40")
    env.setdefault("COLUMNS", "120")
    process = subprocess.Popen(argv, cwd=cwd, env=env, stdin=slave, stdout=slave, stderr=slave, close_fds=True)
    os.close(slave)
    start = time.monotonic()
    sent = [False] * len(inputs)
    output = bytearray()
    terminal_observations: list[TerminalObservation] = []
    seen_terminal_offsets: set[tuple[int, str]] = set()
    scanned_length = 0

    def collect_terminal_observations() -> str:
        nonlocal scanned_length
        text = output.decode("utf-8", errors="replace")
        search_from = max(0, scanned_length - 512)
        timestamp = time.time()
        for observation in extract_terminal_observations(text[search_from:], timestamp=timestamp):
            absolute_observation = dataclasses.replace(observation, offset=observation.offset + search_from)
            key = (absolute_observation.offset, absolute_observation.kind)
            if key in seen_terminal_offsets:
                continue
            seen_terminal_offsets.add(key)
            terminal_observations.append(absolute_observation)
        scanned_length = len(text)
        return text

    try:
        while True:
            now = time.monotonic()
            for index, item in enumerate(inputs):
                if sent[index]:
                    continue
                match = item.get("match")
                if isinstance(match, str) and match:
                    text_so_far = output.decode("utf-8", errors="replace")
                    if not re.search(match, text_so_far, flags=re.I | re.S):
                        continue
                if now - start >= float(item.get("after", 0)):
                    os.write(master, str(item.get("text", "")).encode("utf-8"))
                    sent[index] = True
            ready, _, _ = select.select([master], [], [], 0.05)
            if ready:
                try:
                    output.extend(os.read(master, 4096))
                    collect_terminal_observations()
                except OSError:
                    pass
            if process.poll() is not None:
                break
            if completion_predicate is not None and completion_predicate():
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                text = collect_terminal_observations()
                transcript_path.write_text(text, encoding="utf-8")
                return PtyResult(
                    process.returncode or -1,
                    False,
                    text,
                    completed_by_predicate=True,
                    terminal_observations=terminal_observations,
                )
                break
            if now - start > timeout:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                text = collect_terminal_observations()
                transcript_path.write_text(text, encoding="utf-8")
                return PtyResult(
                    process.returncode or -1,
                    True,
                    text,
                    terminal_observations=terminal_observations,
                )
        exit_code = process.wait()
        text = collect_terminal_observations()
        transcript_path.write_text(text, encoding="utf-8")
        return PtyResult(exit_code, False, text, terminal_observations=terminal_observations)
    finally:
        os.close(master)


def set_pty_window_size(fd: int, rows: int, columns: int) -> None:
    winsize = struct.pack("HHHH", rows, columns, 0, 0)
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)
    except OSError:
        pass


def send_ipc(socket_path: pathlib.Path, request: dict[str, Any]) -> dict[str, Any] | None:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(str(socket_path))
        client.sendall(json.dumps(request).encode("utf-8") + b"\n")
        if not request.get("expectsResponse"):
            return None
        data = bytearray()
        while b"\n" not in data:
            chunk = client.recv(4096)
            if not chunk:
                break
            data.extend(chunk)
    return json.loads(data.decode("utf-8")) if data else None


def run_version(command: str, args: list[str], env: dict[str, str]) -> str:
    try:
        result = subprocess.run([command] + args, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
        return result.stdout.splitlines()[0] if result.stdout else f"exit {result.returncode}"
    except Exception as error:
        return f"unavailable: {error}"


def parse_build_settings(output: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in output.splitlines():
        stripped = line.strip()
        if " = " not in stripped:
            continue
        key, value = stripped.split(" = ", 1)
        if not key:
            continue
        values[key] = value
    return values


def matches_any(text: str, patterns: list[str]) -> bool:
    return any(re.search(pattern, text, flags=re.I) for pattern in patterns)


def bench_marker_observed(text: str) -> bool:
    return (
        "ZENTTY_AGENT_BENCH_OK" in text
        or "ZENTTY_AGENT_BENCH_APPROVAL_OK" in text
        or "ZENTTY_AGENT_BENCH_TASKS_OK" in text
    )


def filtered_inherited_path(path_value: str) -> str:
    entries: list[str] = []
    for entry in path_value.split(os.pathsep):
        if not entry:
            continue
        if is_zentty_resource_bin_path(entry):
            continue
        entries.append(entry)
    return os.pathsep.join(entries)


def is_zentty_resource_bin_path(entry: str) -> bool:
    parts = pathlib.PurePath(entry).parts
    if len(parts) < 5:
        return False
    for index in range(len(parts) - 3):
        if parts[index].endswith(".app") and parts[index + 1 : index + 4] == ("Contents", "Resources", "bin"):
            return True
    return False


def config_source_dir(environment: dict[str, Any], env_key: str, default_name: str) -> pathlib.Path:
    home = pathlib.Path(str(environment.get("HOME") or pathlib.Path.home())).expanduser()
    configured = str(environment.get(env_key) or "").strip()
    if configured and not is_zentty_launch_cache_path(configured):
        return pathlib.Path(configured).expanduser()
    return home / default_name


def is_zentty_launch_cache_path(entry: str) -> bool:
    parts = pathlib.PurePath(entry).parts
    for index in range(len(parts) - 2):
        if parts[index : index + 3] == ("Library", "Caches", "Zentty"):
            return True
    return False


def write_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def read_json_object(path: pathlib.Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def remove_top_level_toml_key(text: str, key: str) -> str:
    lines: list[str] = []
    in_table = False
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=")
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("["):
            in_table = True
        if not in_table and pattern.match(line):
            continue
        lines.append(line)
    return "\n".join(lines)


def symlink_directory_contents_skipping(source: pathlib.Path, destination: pathlib.Path, skipping: set[str]) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    if not source.exists():
        return
    for child in source.iterdir():
        if child.name in skipping:
            continue
        target = destination / child.name
        if target.exists() or target.is_symlink():
            continue
        try:
            target.symlink_to(child)
        except OSError:
            if child.is_dir():
                shutil.copytree(child, target, dirs_exist_ok=True)
            else:
                shutil.copy2(child, target)


def copy_directory_contents(source: pathlib.Path, destination: pathlib.Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    if not source.exists():
        return
    for child in source.iterdir():
        target = destination / child.name
        if child.is_dir():
            shutil.copytree(child, target, dirs_exist_ok=True)
        else:
            shutil.copy2(child, target)


def shell_escape_double_quoted(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")


def toml_basic_string(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def toml_string_array(values: list[str]) -> str:
    return "[" + ",".join(f'"{toml_basic_string(value)}"' for value in values) + "]"


def list_agents() -> int:
    profiles = load_profiles(BENCH_ROOT / "profiles")
    for agent in SUPPORTED_AGENTS:
        profile = profiles[agent]
        scenarios = ",".join(sorted(profile.expectations))
        print(f"{agent}\t{profile.command}\t{scenarios}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run Zentty live agent hook bench scenarios.")
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="Run live agent scenarios.")
    run.add_argument("--agents", default="all", help="Comma-separated agent names or all.")
    run.add_argument("--scenarios", default="smoke", help="Comma-separated scenario names.")
    run.add_argument("--timeout", type=int, default=180)
    run.add_argument("--strict", action="store_true", help="Treat skips as failures.")
    run.add_argument("--no-build", action="store_true", help="Do not build Zentty first.")
    run.add_argument("--app-path", help="Path to Zentty.app to use.")
    run.add_argument("--run-dir", help="Directory for traces and reports.")

    self_test = sub.add_parser("self-test", help="Exercise the capture server without model calls.")
    self_test.add_argument("--no-build", action="store_true")
    self_test.add_argument("--app-path")
    self_test.add_argument("--run-dir")
    self_test.add_argument("--agents", default="codex")
    self_test.add_argument("--scenarios", default="smoke")
    self_test.add_argument("--timeout", type=int, default=30)
    self_test.add_argument("--strict", action="store_true")

    sub.add_parser("list-agents", help="List supported bench profiles.")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "list-agents":
        return list_agents()
    runner = BenchRunner(args)
    if args.command == "self-test":
        return runner.self_test()
    if args.command == "run":
        return runner.run()
    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
