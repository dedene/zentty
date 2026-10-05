#!/usr/bin/env python3
from __future__ import annotations

import argparse
import dataclasses
import fcntl
import hashlib
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
import signal
import socket
import subprocess
import sys
import termios
import tempfile
import threading
import time
import uuid
from collections import Counter
from typing import Any


SUPPORTED_AGENTS = ("agy", "amp", "claude", "codex", "copilot", "cursor", "devin", "droid", "gemini", "generic-canonical", "grok", "hermes", "kilo", "kimi", "kimi-code", "omp", "opencode", "pi", "small-harness", "vibe")
REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
BENCH_ROOT = pathlib.Path(__file__).resolve().parent
DEFAULT_RUNS_DIR = REPO_ROOT / ".agent-bench-runs"
AMP_PLUGIN_FILE_NAME = "zentty-amp-zentty.ts"
AMP_PLUGIN_OWNERSHIP_MARKER = "zentty-amp-plugin-v1"
ROUTING_ENV_KEYS = {
    "ZENTTY_INSTANCE_SOCKET",
    "ZENTTY_WINDOW_ID",
    "ZENTTY_WORKLANE_ID",
    "ZENTTY_PANE_ID",
    "ZENTTY_INSTANCE_ID",
    "ZENTTY_AGENT_TOOL",
    "ZENTTY_AMP_PID",
    "ZENTTY_AMP_RESUME_ARGUMENTS_JSON",
    "PLUGINS",
    "ZENTTY_CLAUDE_PID",
    "ZENTTY_CODEX_PID",
    "ZENTTY_COPILOT_PID",
    "ZENTTY_GEMINI_PID",
    "ZENTTY_CURSOR_PID",
    "ZENTTY_DROID_PID",
    "ZENTTY_HERMES_PID",
    "ZENTTY_KIMI_PID",
    "ZENTTY_GROK_PID",
    "ZENTTY_AGY_PID",
    "ZENTTY_DEVIN_PID",
    "ZENTTY_SMALL_HARNESS_PID",
    "CODEX_HOME",
    "COPILOT_HOME",
    "KIMI_CODE_HOME",
    "KIMI_SHARE_DIR",
    "KIMI_HOME",
    "GEMINI_CLI_SYSTEM_SETTINGS_PATH",
    "SMALL_HARNESS_MANAGED_HOOKS_FILE",
    "SMALL_HARNESS_MANAGED_HOOKS_JSON",
    "OPENCODE_CONFIG",
    "OPENCODE_CONFIG_DIR",
    "ZENTTY_OPENCODE_BASE_CONFIG_DIR",
    "KILO_CONFIG",
    "KILO_CONFIG_DIR",
    "KILO_TUI_CONFIG",
    "ZENTTY_KILO_BASE_CONFIG_DIR",
    "ZENTTY_AGENT_CANONICAL_NAME",
    "ZENTTY_AGENT_MANIFEST_DIRS",
    "BENCH_AGENT_EVENT_COMMAND",
    "HOME",
}
SMALL_HARNESS_HOOK_ENV_VARS = [
    "ZENTTY_INSTANCE_SOCKET",
    "ZENTTY_WINDOW_ID",
    "ZENTTY_WORKLANE_ID",
    "ZENTTY_PANE_ID",
    "ZENTTY_PANE_TOKEN",
    "ZENTTY_INSTANCE_ID",
    "ZENTTY_SMALL_HARNESS_PID",
]
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
ANSI_ESCAPE_PATTERN = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
KIMI_VARIANT_PROBE_CACHE: dict[str, str] = {}


@dataclasses.dataclass
class SessionIdentityExpectation:
    session_id_pattern: str
    tracked_pid: bool = True


@dataclasses.dataclass
class ScenarioExpectation:
    name: str
    required_events: list[str]
    required_terminal_phases: list[str] = dataclasses.field(default_factory=list)
    required_bootstrap_arguments: list[list[str]] = dataclasses.field(default_factory=list)
    forbidden_events: list[str] = dataclasses.field(default_factory=list)
    forbidden_terminal_phases: list[str] = dataclasses.field(default_factory=list)
    expected_task_progress: dict[str, int] | None = None
    expected_task_items: list[dict[str, str]] | None = None
    session_identity: SessionIdentityExpectation | None = None
    synthetic: bool = False
    fixture: str | None = None
    post_stop_notification_required: bool = False
    # The scenario must capture a SubagentStart/SubagentStop pair whose payload
    # names the agent type and whose transcript sidecar yields the model —
    # the two facts the sidebar badge and its expanded list are built from.
    subagent_payload_required: bool = False
    # Whether that payload check also demands a resolvable model. Grok exposes
    # no per-subagent transcript, so its profile only proves count and type.
    subagent_model_required: bool = True
    # Ordered event pairs, e.g. [["Stop", "SubagentStop"]]: some occurrence of
    # the first event must be observed before the last occurrence of the
    # second. Pins the async Agent contract (Claude 2.1.261+): the parent's
    # Stop fires while its subagent is still alive, so Stop must not clear
    # the sidebar badge.
    event_order: list[list[str]] = dataclasses.field(default_factory=list)
    # The scenario must capture at least two SubagentStart/SubagentStop pairs
    # with distinct agent ids, every stop matching a start — a subagent that
    # itself spawned a subagent.
    subagent_nested_required: bool = False
    # A true end-to-end resume round-trip (modern kimi-code only): phase 1
    # creates a real session through the wrapper bootstrap against a bench-owned
    # home, phase 2 simulates a restart and resumes it by id, asserting the
    # session is found. This is the regression guard for the overlay bug class.
    resume_roundtrip: bool = False
    # Claude only: start the shared background daemon under a different pane's
    # identity, then launch `claude --bg` through the wrapper and require every
    # captured hook to carry the launching pane (dedene/zentty#121). Starts and
    # stops the per-user Claude daemon, so it skips when one is already running.
    daemon_pane_routing: bool = False


@dataclasses.dataclass
class AgentProfile:
    name: str
    command: str
    real_binary_names: list[str]
    version_args: list[str]
    launch_args_by_scenario: dict[str, list[str]]
    expectations: dict[str, ScenarioExpectation]
    input_by_scenario: dict[str, list[dict[str, Any]]] = dataclasses.field(default_factory=dict)
    environment_by_scenario: dict[str, dict[str, str]] = dataclasses.field(default_factory=dict)
    repeat_by_scenario: dict[str, int] = dataclasses.field(default_factory=dict)
    skip_patterns: list[str] = dataclasses.field(default_factory=list)
    tool: str = ""
    kimi_variant: str | None = None

    def __post_init__(self) -> None:
        if not self.tool:
            self.tool = self.name


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
    terminal_final_phase: str | None = None
    terminal_post_scripted_input_phase: str | None = None
    terminal_phase_sequence: list[str] = dataclasses.field(default_factory=list)
    terminal_observations: list[dict[str, Any]] = dataclasses.field(default_factory=list)
    task_observations: list[dict[str, Any]] = dataclasses.field(default_factory=list)
    task_item_observations: list[dict[str, Any]] = dataclasses.field(default_factory=list)
    subagent_observations: list[dict[str, Any]] = dataclasses.field(default_factory=list)
    session_identity_observations: list[dict[str, Any]] = dataclasses.field(default_factory=list)
    timeline: list[dict[str, Any]] = dataclasses.field(default_factory=list)
    rerun_command: str = ""


def compact_json(obj: Any) -> str:
    return json.dumps(obj, separators=(",", ":"))


def redacted_environment(environment: dict[str, str]) -> dict[str, str]:
    redacted: dict[str, str] = {}
    for key, value in environment.items():
        if key not in ROUTING_ENV_KEYS and not SECRET_ENV_PATTERNS.search(key):
            continue
        redacted[key] = "<redacted>" if SECRET_ENV_PATTERNS.search(key) else redact_pii_text(value)
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


def _trace_contains_post_stop_notification(records: list[TraceRecord]) -> bool:
    # Returns True if the trace contains a Notification hook arriving after a
    # Stop hook within the same agent/scenario stream — the ingredient list
    # for the "Claude finished but pane still says Needs input" race.
    seen_stop = False
    for record in records:
        if record.kind != "hook":
            continue
        if record.event_name == "Stop":
            seen_stop = True
            continue
        if record.event_name == "Notification" and seen_stop:
            return True
    return False


def validate_scenario(
    agent: str,
    expectation: ScenarioExpectation,
    records: list[TraceRecord],
    agent_tool: str | None = None,
) -> ScenarioResult:
    observed = [
        name
        for record in records
        if record.agent == agent and record.scenario == expectation.name
        for name in hook_record_event_names(record)
    ]
    observed_values = [event for event in observed if event]
    observed_counts = Counter(observed_values)
    forbidden = [event for event in expectation.forbidden_events if observed_counts[event] > 0]
    if forbidden:
        return ScenarioResult(
            agent=agent,
            scenario=expectation.name,
            passed=False,
            missing_events=[f"forbidden:{event}" for event in forbidden],
            observed_events=observed_values,
            status="fail",
            result_kind="forbidden-hook",
        )

    missing: list[str] = []
    for event in expectation.required_events:
        satisfied = next(
            (name for name in required_event_alternatives(event) if observed_counts[name] > 0),
            None,
        )
        if satisfied is not None:
            observed_counts[satisfied] -= 1
        else:
            missing.append(event)
    observed_bootstrap_arguments = [
        bootstrap_arguments(record)
        for record in records
        if record.kind == "bootstrap" and record.agent == agent and record.scenario == expectation.name
    ]
    for required_arguments in expectation.required_bootstrap_arguments:
        if required_arguments in observed_bootstrap_arguments:
            continue
        missing.append("bootstrap:" + " ".join(required_arguments))
    session_missing, session_observations = validate_session_identity(agent, expectation, records, agent_tool=agent_tool)
    missing.extend(session_missing)
    if missing:
        result_kind = "missing-bootstrap" if any(item.startswith("bootstrap:") for item in missing) else "missing-hook"
        if not any(item.startswith("bootstrap:") for item in missing) and session_missing and len(missing) == len(session_missing):
            result_kind = "missing-session-identity"
    else:
        result_kind = (
            "bootstrap-pass"
            if expectation.required_bootstrap_arguments and not expectation.required_events
            else "hook-pass"
        )
    return ScenarioResult(
        agent=agent,
        scenario=expectation.name,
        passed=not missing,
        missing_events=missing,
        observed_events=observed_values,
        status="pass" if not missing else "fail",
        result_kind=result_kind,
        session_identity_observations=session_observations,
    )


def required_event_alternatives(event: str) -> list[str]:
    """A required event may name alternatives joined by `|` — either in the
    tool suffix or as whole names (`PreToolUse:run_subagent|PreToolUse:sidekick`)
    — and is satisfied when any single alternative was observed."""
    return [alternative.strip() for alternative in event.split("|")]


def hook_record_event_names(record: TraceRecord) -> list[str | None]:
    """Event names a hook record satisfies. Besides the raw event name, tool
    events also satisfy the tool-qualified form `EventName:tool_name` — used by
    agents like Devin that express subagent lifecycle through the
    `run_subagent`/`sidekick` tools rather than dedicated Subagent* hooks."""
    if not record.event_name:
        return [None]
    names = [record.event_name]
    payload = parse_json_object(record.standard_input)
    tool_name = first_string(payload, ["tool_name", "toolName"])
    if tool_name:
        names.append(f"{record.event_name}:{tool_name}")
    return names


def bootstrap_arguments(record: TraceRecord) -> list[str]:
    extra = record.extra if isinstance(record.extra, dict) else {}
    arguments = extra.get("arguments")
    if not isinstance(arguments, list):
        return []
    return [str(argument) for argument in arguments]


def validate_session_identity(
    agent: str,
    expectation: ScenarioExpectation,
    records: list[TraceRecord],
    agent_tool: str | None = None,
) -> tuple[list[str], list[dict[str, Any]]]:
    if expectation.session_identity is None:
        return ([], [])

    observations = session_identity_observations_for_records(
        agent,
        expectation.name,
        records,
        expectation.session_identity.session_id_pattern,
        agent_tool=agent_tool,
    )
    missing: list[str] = []
    if not any(observation.get("session_id_valid") is True for observation in observations):
        missing.append(f"session-id:{expectation.session_identity.session_id_pattern}")
    if expectation.session_identity.tracked_pid and not any(observation.get("tracked_pid") for observation in observations):
        missing.append("tracked-pid")
    return (missing, observations)


def session_identity_observations_for_records(
    agent: str,
    scenario: str,
    records: list[TraceRecord],
    session_id_pattern: str,
    agent_tool: str | None = None,
) -> list[dict[str, Any]]:
    observations: list[dict[str, Any]] = []
    for record in records:
        if record.agent != agent or record.scenario != scenario or record.kind != "hook":
            continue

        payload = parse_json_object(record.standard_input)
        session_id, session_source = extract_session_id(agent, payload)
        tracked_pid, pid_source = extract_tracked_pid(agent, payload, record.environment or {}, agent_tool=agent_tool)
        if session_id is None and tracked_pid is None:
            continue

        observation: dict[str, Any] = {"event": record.event_name or ""}
        if session_id is not None:
            observation["session_id"] = session_id
            observation["session_id_pattern"] = session_id_pattern
            observation["session_id_valid"] = session_id_matches_pattern(session_id, session_id_pattern)
            observation["session_id_source"] = session_source
        if tracked_pid is not None:
            observation["tracked_pid"] = tracked_pid
            observation["tracked_pid_source"] = pid_source
        observations.append(observation)
    return observations


def extract_session_id(agent: str, payload: dict[str, Any]) -> tuple[str | None, str | None]:
    keys = ["session_id", "sessionId"]
    # cursor and agy carry the session id under conversation_id/conversationId.
    if agent in ("cursor", "agy"):
        keys.extend(["conversation_id", "conversationId"])

    for key in keys:
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return (value.strip(), key)
    session = payload.get("session")
    if isinstance(session, dict):
        value = session.get("id")
        if isinstance(value, str) and value.strip():
            return (value.strip(), "session.id")
    return (None, None)


def extract_tracked_pid(
    agent: str,
    payload: dict[str, Any],
    environment: dict[str, str],
    agent_tool: str | None = None,
) -> tuple[int | None, str | None]:
    expected_key = agent_pid_env_key(agent, agent_tool=agent_tool)
    pid = parse_positive_int(environment.get(expected_key))
    if pid is not None:
        return (pid, expected_key)
    payload_agent = payload.get("agent")
    if isinstance(payload_agent, dict):
        pid = parse_positive_int(payload_agent.get("pid"))
        if pid is not None:
            return (pid, "agent.pid")
    return (None, None)


def agent_pid_env_key(agent: str, agent_tool: str | None = None) -> str:
    pid_agent = agent_tool or agent
    return f"ZENTTY_{pid_agent.upper().replace('-', '_')}_PID"


def parse_positive_int(value: Any) -> int | None:
    if isinstance(value, int) and value > 0:
        return value
    if isinstance(value, str):
        stripped = value.strip()
        if stripped.isdigit():
            parsed = int(stripped)
            return parsed if parsed > 0 else None
    return None


def session_id_matches_pattern(session_id: str, pattern: str) -> bool:
    if pattern == "non-empty":
        return bool(session_id.strip())
    if pattern == "uuid":
        return re.fullmatch(
            r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
            session_id,
        ) is not None
    if pattern == "kimi-code":
        return re.fullmatch(
            r"(?:session_)?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
            session_id,
        ) is not None
    if pattern == "codex":
        return session_id_matches_pattern(session_id, "uuid") or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", session_id) is not None
    if pattern == "droid":
        return re.fullmatch(r"[A-Za-z0-9_.:-]+", session_id) is not None
    if pattern == "amp":
        return re.fullmatch(r"T-[A-Za-z0-9_-]+", session_id) is not None
    if pattern == "opencode":
        return re.fullmatch(r"ses_[A-Za-z0-9]+", session_id) is not None
    if pattern == "devin":
        # Devin session ids are human-readable word slugs (`thorn-angora`).
        return re.fullmatch(r"[a-z0-9][a-z0-9-]*", session_id) is not None
    if pattern.startswith("regex:"):
        # Manifest agents declare their own session id shape, e.g.
        # "regex:^ses_[A-Za-z0-9]+$" for kilo.
        return re.fullmatch(pattern[len("regex:"):], session_id) is not None
    return False


def missing_required_terminal_phases(
    expectation: ScenarioExpectation,
    observations: list[TerminalObservation],
) -> list[str]:
    observed_phases = terminal_phase_sequence(observations)
    missing: list[str] = []
    observed_index = 0
    for phase in expectation.required_terminal_phases:
        while observed_index < len(observed_phases) and observed_phases[observed_index] != phase:
            observed_index += 1
        if observed_index >= len(observed_phases):
            missing.append(phase)
            continue
        observed_index += 1
    return missing


def forbidden_terminal_phases(
    expectation: ScenarioExpectation,
    observations: list[TerminalObservation],
) -> list[str]:
    observed_phases = {
        phase
        for observation in observations
        if (phase := terminal_observation_phase(observation))
    }
    return [phase for phase in expectation.forbidden_terminal_phases if phase in observed_phases]


def classify_completed_result(
    agent: str,
    scenario: str,
    expectation: ScenarioExpectation,
    records: list[TraceRecord],
    terminal_observations: list[TerminalObservation],
    output: str,
    skip_patterns: list[str],
    exit_code: int,
    completed_by_predicate: bool,
    strict: bool,
    agent_tool: str | None = None,
) -> ScenarioResult:
    result = validate_scenario(agent, expectation, records, agent_tool=agent_tool)
    if not result.passed:
        if result.result_kind == "forbidden-hook":
            result.status = "fail"
            result.detail = "forbidden hook event observed"
        elif result.result_kind == "missing-bootstrap":
            result.status = "fail"
            result.detail = "restore launch command did not reach bootstrap with required arguments"
        elif result.result_kind == "missing-session-identity":
            result.status = "fail"
            result.detail = "required hooks observed but resumable session identity was missing"
        elif bench_marker_observed(output):
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
    forbidden_phases = forbidden_terminal_phases(expectation, terminal_observations)
    if forbidden_phases:
        result.passed = False
        result.status = "fail"
        result.missing_events = [f"forbidden:{phase}" for phase in forbidden_phases]
        result.detail = "forbidden terminal phase observed"
        result.result_kind = "forbidden-terminal-phase"
        return result
    missing_terminal_phases = missing_required_terminal_phases(expectation, terminal_observations)
    if missing_terminal_phases:
        result.passed = False
        result.status = "fail"
        result.missing_events = missing_terminal_phases
        result.detail = "missing required terminal phases"
        result.result_kind = "missing-terminal-phase"
        return result
    if scenario_requires_task_observation(agent, scenario) and not task_observations_for_records(agent, scenario, records):
        result.passed = False
        result.status = "fail"
        result.detail = "required lifecycle hooks observed but no TodoWrite task progress hook was captured"
        result.result_kind = "missing-task-hook"
        return result
    task_observations = task_observations_for_records(agent, scenario, records)
    if expectation.expected_task_progress and not expected_task_progress_observed(expectation, task_observations):
        result.passed = False
        result.status = "fail"
        result.detail = "required TodoWrite task progress was not captured"
        result.result_kind = "missing-task-progress"
        return result
    if expectation.expected_task_items and not expected_task_items_observed(expectation, task_observations):
        result.passed = False
        result.status = "fail"
        result.detail = "required task items were not captured"
        result.result_kind = "missing-task-items"
        return result
    subagent_failure = subagent_contract_failure(agent, scenario, expectation, records)
    if subagent_failure:
        result.passed = False
        result.status = "fail"
        result.result_kind, result.detail = subagent_failure
        return result
    if scenario_requires_terminal_needs_input(scenario) and not terminal_needs_input_observed(terminal_observations):
        result.passed = False
        result.status = "fail"
        result.detail = "required lifecycle hooks observed but no terminal needs-input title was captured"
        result.result_kind = "missing-terminal-needs-input"
        return result
    if scenario_requires_scripted_input(agent, scenario) and not scripted_input_observed(agent, scenario, terminal_observations):
        result.passed = False
        result.status = "fail"
        result.detail = "required lifecycle hooks observed but scripted input was not captured"
        result.result_kind = "missing-scripted-input"
        return result
    if terminal_needs_input_persisted_after_scripted_input(agent, scenario, terminal_observations):
        result.passed = False
        result.status = "fail"
        result.detail = "terminal still reported needs-input after scripted input"
        result.result_kind = "stale-terminal-needs-input"
        return result
    if exit_code != 0 and not completed_by_predicate:
        result.passed = False
        result.status = "fail"
        result.detail = f"process exited {exit_code}"
        result.result_kind = "missing-hook"
        return result
    if completed_by_predicate:
        result.detail = (
            "required terminal phases observed"
            if expectation.required_terminal_phases and not expectation.required_events
            else "required events observed"
        )
    if result.result_kind != "bootstrap-pass":
        result.result_kind = (
            "terminal-pass"
            if expectation.required_terminal_phases and not expectation.required_events
            else "hook-pass"
        )
    return result


def classify_timeout_result(
    agent: str,
    scenario: str,
    expectation: ScenarioExpectation,
    records: list[TraceRecord],
    terminal_observations: list[TerminalObservation],
    output: str,
    skip_patterns: list[str],
    timeout: int,
    strict: bool,
    agent_tool: str | None = None,
) -> ScenarioResult:
    partial = validate_scenario(agent, expectation, records, agent_tool=agent_tool)
    if not partial.missing_events:
        forbidden_phases = forbidden_terminal_phases(expectation, terminal_observations)
        if forbidden_phases:
            partial.passed = False
            partial.status = "fail"
            partial.missing_events = [f"forbidden:{phase}" for phase in forbidden_phases]
            partial.detail = "forbidden terminal phase observed"
            partial.result_kind = "forbidden-terminal-phase"
            return partial
        else:
            missing_terminal_phases = missing_required_terminal_phases(expectation, terminal_observations)
        if missing_terminal_phases:
            partial.passed = False
            partial.status = "fail"
            partial.missing_events = missing_terminal_phases
            partial.detail = "missing required terminal phases"
            partial.result_kind = "missing-terminal-phase"
        elif scenario_requires_task_observation(agent, scenario) and not task_observations_for_records(agent, scenario, records):
            partial.passed = False
            partial.status = "fail"
            partial.detail = "required lifecycle hooks observed but no TodoWrite task progress hook was captured"
            partial.result_kind = "missing-task-hook"
        elif expectation.expected_task_progress and not expected_task_progress_observed(
            expectation,
            task_observations_for_records(agent, scenario, records),
        ):
            partial.passed = False
            partial.status = "fail"
            partial.detail = "required TodoWrite task progress was not captured"
            partial.result_kind = "missing-task-progress"
        elif expectation.expected_task_items and not expected_task_items_observed(
            expectation,
            task_observations_for_records(agent, scenario, records),
        ):
            partial.passed = False
            partial.status = "fail"
            partial.detail = "required task items were not captured"
            partial.result_kind = "missing-task-items"
        elif subagent_failure := subagent_contract_failure(agent, scenario, expectation, records):
            partial.passed = False
            partial.status = "fail"
            partial.result_kind, partial.detail = subagent_failure
        elif scenario_requires_terminal_needs_input(scenario) and not terminal_needs_input_observed(terminal_observations):
            partial.passed = False
            partial.status = "fail"
            partial.detail = "required lifecycle hooks observed but no terminal needs-input title was captured"
            partial.result_kind = "missing-terminal-needs-input"
        elif scenario_requires_scripted_input(agent, scenario) and not scripted_input_observed(agent, scenario, terminal_observations):
            partial.passed = False
            partial.status = "fail"
            partial.detail = "required lifecycle hooks observed but scripted input was not captured"
            partial.result_kind = "missing-scripted-input"
        elif terminal_needs_input_persisted_after_scripted_input(agent, scenario, terminal_observations):
            partial.passed = False
            partial.status = "fail"
            partial.detail = "terminal still reported needs-input after scripted input"
            partial.result_kind = "stale-terminal-needs-input"
        else:
            partial.passed = True
            partial.status = "pass"
            partial.detail = (
                f"required terminal phases observed before {timeout}s timeout"
                if expectation.required_terminal_phases and not expectation.required_events
                else f"required events observed before {timeout}s timeout"
            )
            if partial.result_kind != "bootstrap-pass":
                partial.result_kind = (
                    "terminal-pass"
                    if expectation.required_terminal_phases and not expectation.required_events
                    else "hook-pass"
                )
            partial.warnings.append("process timed out after required hooks were observed")
    elif partial.result_kind == "forbidden-hook":
        partial.passed = False
        partial.status = "fail"
        partial.detail = "forbidden hook event observed"
    elif partial.result_kind == "missing-bootstrap":
        partial.passed = False
        partial.status = "fail"
        partial.detail = "restore launch command did not reach bootstrap with required arguments"
    elif partial.result_kind == "missing-session-identity":
        partial.passed = False
        partial.status = "fail"
        partial.detail = "required hooks observed but resumable session identity was missing"
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



CLAUDE_CONFIG_PATH = pathlib.Path.home() / ".claude.json"
BENCH_REPO_MARKER = "/repos/claude-"


def ensure_claude_workspace_trust(repo: pathlib.Path, config_path: pathlib.Path = CLAUDE_CONFIG_PATH) -> bool:
    """Mark the bench's temporary repo as a trusted Claude Code workspace.

    Interactive Claude Code (2.1.261+) skips *all* hook execution while the
    workspace trust dialog has not been accepted, and it does not show that
    dialog in the bench's pty. Without this every interactive Claude scenario
    reports ``missing-hook`` even though the wrapper injected the hooks.

    Only ``hasTrustDialogAccepted`` is written. Stale bench entries (repos
    that no longer exist on disk) are pruned so ``~/.claude.json`` does not
    accumulate one project per run. Returns True when the file changed.
    """
    try:
        config = json.loads(config_path.read_text(encoding="utf-8")) if config_path.exists() else {}
    except (OSError, json.JSONDecodeError):
        return False
    if not isinstance(config, dict):
        return False
    projects = config.setdefault("projects", {})
    if not isinstance(projects, dict):
        return False

    changed = False
    for key in list(projects):
        if BENCH_REPO_MARKER in key and not pathlib.Path(key).exists():
            del projects[key]
            changed = True

    for candidate in {str(repo), str(repo.resolve())}:
        entry = projects.get(candidate)
        if not isinstance(entry, dict):
            entry = {}
            projects[candidate] = entry
        if entry.get("hasTrustDialogAccepted") is not True:
            entry["hasTrustDialogAccepted"] = True
            changed = True

    if not changed:
        return False
    temporary = config_path.with_name(config_path.name + ".agent-bench.tmp")
    temporary.write_text(json.dumps(config, indent=2), encoding="utf-8")
    os.replace(temporary, config_path)
    return True


def scenario_requires_task_observation(agent: str, scenario: str) -> bool:
    return scenario == "tasks"


def scenario_requires_terminal_needs_input(scenario: str) -> bool:
    return scenario in {"question", "question_interrupt"}


def scenario_requires_scripted_input(agent: str, scenario: str) -> bool:
    return scenario == "question_interrupt" or (agent == "codex" and scenario == "approval")


def required_scripted_input_label(agent: str, scenario: str) -> str | None:
    if agent == "codex" and scenario == "approval":
        return "approve-command"
    if scenario == "question_interrupt":
        return "ctrl-c"
    return None


def terminal_needs_input_observed(observations: list[TerminalObservation]) -> bool:
    return any(terminal_observation_indicates_needs_input(observation) for observation in observations)


def scripted_input_observed(agent: str, scenario: str, observations: list[TerminalObservation]) -> bool:
    required_label = required_scripted_input_label(agent, scenario)
    if required_label:
        return any(
            observation.kind == "input" and observation.text == required_label
            for observation in observations
        )
    return any(observation.kind == "input" for observation in observations)


def terminal_observation_indicates_needs_input(observation: TerminalObservation) -> bool:
    return observation.kind in {"title", "progress"} and "action required" in observation.text.lower()


def terminal_observation_phase(observation: TerminalObservation) -> str | None:
    if observation.kind not in {"title", "progress"}:
        return None
    text = observation.text.lower()
    if "action required" in text or "needs input" in text or "requires approval" in text or "needs approval" in text:
        return "needs-input"
    if "starting" in text:
        return "starting"
    if "working" in text or "running" in text:
        return "running"
    if "ready" in text or "idle" in text:
        return "idle"
    return None


def terminal_final_phase(observations: list[TerminalObservation]) -> str | None:
    for observation in sorted(observations, key=lambda item: item.offset, reverse=True):
        phase = terminal_observation_phase(observation)
        if phase:
            return phase
    return None


def terminal_phase_sequence(observations: list[TerminalObservation]) -> list[str]:
    phases: list[str] = []
    for observation in sorted(observations, key=lambda item: ((item.timestamp is None, item.timestamp or 0), item.offset)):
        phase = terminal_observation_phase(observation)
        if phase and (not phases or phases[-1] != phase):
            phases.append(phase)
    return phases


def terminal_needs_input_persisted_after_scripted_input(
    agent: str,
    scenario: str,
    observations: list[TerminalObservation],
) -> bool:
    return terminal_phase_after_scripted_input(agent, scenario, observations) == "needs-input"


def terminal_phase_after_scripted_input(
    agent: str,
    scenario: str,
    observations: list[TerminalObservation],
) -> str | None:
    required_label = required_scripted_input_label(agent, scenario)
    if not required_label:
        return None

    input_offsets = [
        observation.offset
        for observation in observations
        if observation.kind == "input" and observation.text == required_label
    ]
    if not input_offsets:
        return None

    last_input_offset = max(input_offsets)
    later_terminal_observations = [
        observation
        for observation in observations
        if observation.kind in {"title", "progress"} and observation.offset > last_input_offset
    ]
    return terminal_final_phase(later_terminal_observations)


def expected_task_progress_observed(
    expectation: ScenarioExpectation,
    observations: list[dict[str, Any]],
) -> bool:
    expected = expectation.expected_task_progress
    if not expected:
        return True
    expected_done = expected.get("done")
    expected_total = expected.get("total")
    return any(
        observation.get("done") == expected_done and observation.get("total") == expected_total
        for observation in observations
    )


TASK_TITLE_KEYS = ["content", "title", "subject", "text", "description", "step"]
TASK_STATUS_KEYS = ["status", "state"]
TASK_LIST_KEYS = ["todos", "plan", "items", "tasks"]
TASK_LIFECYCLE_EVENTS = {"taskcreated", "taskcompleted", "taskupdated"}


def normalize_task_status(status: str | None) -> str:
    text = (status or "").strip().lower()
    if text in {"completed", "complete", "done", "finished"}:
        return "done"
    if text in {"in_progress", "in-progress", "inprogress", "active", "doing", "running"}:
        return "in_progress"
    return "pending"


def is_task_tool_name(tool_name: str) -> bool:
    lowered = tool_name.strip().lower()
    if not lowered:
        return False
    if "todo" in lowered or "writetodos" in lowered:
        return True
    squashed = re.sub(r"[^a-z]", "", lowered)
    return squashed in {
        "plan",
        "updateplan",
        "task",
        "taskadd",
        "taskcreate",
        "taskupdate",
        "taskcomplete",
        "taskcompleted",
        "tasklist",
    }


def task_items_from_entries(entries: Any) -> list[dict[str, str]] | None:
    if not isinstance(entries, list):
        return None
    items: list[dict[str, str]] = []
    for entry in entries:
        if isinstance(entry, dict):
            title = first_string(entry, TASK_TITLE_KEYS)
            if not title:
                continue
            items.append({"title": title, "status": first_string(entry, TASK_STATUS_KEYS) or "pending"})
        elif isinstance(entry, str) and entry.strip():
            items.append({"title": entry.strip(), "status": "pending"})
    return items or None


def task_items_done_total(items: list[dict[str, str]]) -> tuple[int, int]:
    return (sum(1 for item in items if normalize_task_status(item.get("status")) == "done"), len(items))


def task_item_from_mapping(mapping: dict[str, Any]) -> dict[str, str] | None:
    """Single-item tool_input shapes (Claude TaskCreate/TaskUpdate style):
    {"subject": ..., "status": ...}."""
    title = first_string(mapping, TASK_TITLE_KEYS)
    if not title:
        return None
    return {"title": title, "status": first_string(mapping, TASK_STATUS_KEYS) or "pending"}


def task_items_from_tool_input(tool_input: dict[str, Any] | None) -> list[dict[str, str]] | None:
    if not isinstance(tool_input, dict):
        return None
    for key in TASK_LIST_KEYS:
        items = task_items_from_entries(tool_input.get(key))
        if items:
            return items
    todos = tool_input.get("todos")
    if isinstance(todos, str):
        return todo_items_from_text(todos)
    return None


def todo_items_from_text(text: str) -> list[dict[str, str]] | None:
    items: list[dict[str, str]] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        match = re.match(r"^(?:[-*•]\s*)?(?:\d+[.)]\s*)?\[(?P<mark>[^\]]*)\]\s*(?P<title>.+)$", line)
        if not match:
            continue
        mark = match.group("mark").strip().lower()
        status = "done" if mark in {"x", "completed", "complete", "done"} else ("in_progress" if mark in {"in_progress", "in-progress"} else "pending")
        items.append({"title": match.group("title").strip(), "status": status})
    return items or None


def expected_task_items_observed(
    expectation: ScenarioExpectation,
    observations: list[dict[str, Any]],
) -> bool:
    """Every expected item must have been observed with its expected status.
    Titles match case-insensitively by substring containment (agents
    paraphrase slightly); latest observation wins per title."""
    expected = expectation.expected_task_items
    if not expected:
        return True
    latest_status_by_title: list[tuple[str, str]] = []
    for observation in observations:
        for item in observation.get("items") or []:
            if not isinstance(item, dict):
                continue
            title = str(item.get("title") or "")
            if not title:
                continue
            latest_status_by_title.append((title, normalize_task_status(str(item.get("status") or ""))))
    for wanted in expected:
        needle = wanted["title"].lower()
        wanted_status = normalize_task_status(wanted["status"])
        latest: str | None = None
        for title, status in latest_status_by_title:
            if needle in title.lower():
                latest = status
        if latest != wanted_status:
            return False
    return True


def task_observations_for_records(agent: str, scenario: str, records: list[TraceRecord]) -> list[dict[str, Any]]:
    observations: list[dict[str, Any]] = []
    cursor_updates_by_session: dict[str, list[dict[str, Any]]] = {}
    # Single-item task hooks (Claude TaskCreated/TaskCompleted events,
    # TaskCreate/TaskUpdate tool calls) are aggregated per session so an
    # item-level assertion sees the whole list: latest status per task id
    # wins, insertion order is preserved.
    task_items_by_session: dict[str, dict[str, dict[str, str]]] = {}

    def aggregate_task_item(session_id: str, task_key: str, item: dict[str, str]) -> list[dict[str, str]]:
        bucket = task_items_by_session.setdefault(session_id, {})
        # Join items that name the same task under different keys — e.g. a
        # TaskCreated hook keys by task_id while the TaskCreate tool call only
        # carries the subject.
        title = (item.get("title") or "").lower()
        if title:
            for existing_key, existing in bucket.items():
                if existing_key != task_key and (existing.get("title") or "").lower() == title:
                    task_key = existing_key
                    break
        bucket[task_key] = item
        return [dict(entry) for entry in bucket.values()]

    for record in records:
        if record.agent != agent or record.scenario != scenario or record.kind != "hook":
            continue
        if isinstance(record.extra, dict):
            progress = record.extra.get("task_progress")
            if isinstance(progress, dict):
                done = progress.get("done")
                total = progress.get("total")
                tool = progress.get("tool")
                source = progress.get("source")
                items = task_items_from_entries(progress.get("items"))
                if items and not (isinstance(done, int) and isinstance(total, int) and total > 0):
                    done, total = task_items_done_total(items)
                if (isinstance(done, int) and isinstance(total, int) and total > 0) or items:
                    observation: dict[str, Any] = {
                        "event": record.event_name or "",
                        "tool": tool if isinstance(tool, str) and tool else "TodoWrite",
                        "raw_tool_name": tool if isinstance(tool, str) and tool else "TodoWrite",
                        "source": source if isinstance(source, str) and source else "trace_extra",
                    }
                    if isinstance(done, int) and isinstance(total, int):
                        observation["done"] = done
                        observation["total"] = total
                    if items:
                        observation["items"] = items
                    observations.append(observation)
                    continue
        payload = parse_json_object(record.standard_input)
        session_id = first_string(payload, ["session_id", "sessionId", "conversation_id", "conversationId"]) or "__default__"

        # Case 0: single-item task lifecycle hooks (Claude TaskCreated /
        # TaskCompleted carry task_subject + task_id, no tool_input list).
        hook_event = re.sub(
            r"[^a-z]",
            "",
            str(record.event_name or first_string(payload, ["hook_event_name", "hookEventName"]) or "").lower(),
        )
        if hook_event in TASK_LIFECYCLE_EVENTS:
            title = first_string(payload, ["task_subject", "taskSubject", "subject", "title", "content", "text", "description"])
            if hook_event == "taskcompleted":
                status = "done"
            elif hook_event == "taskupdated":
                status = first_string(payload, ["status", "state"]) or "pending"
            else:
                status = "pending"
            task_key = (
                first_string(payload, ["task_id", "taskId", "id"])
                or title
                or f"task-{len(task_items_by_session.get(session_id, {}))}"
            )
            items = aggregate_task_item(session_id, task_key, {"title": title or task_key, "status": status})
            raw_tool_name = first_string(payload, ["tool_name", "toolName", "tool"]) or record.event_name or "TaskHook"
            done, total = task_items_done_total(items)
            observations.append(
                {
                    "event": record.event_name or "",
                    "tool": raw_tool_name,
                    "raw_tool_name": raw_tool_name,
                    "done": done,
                    "total": total,
                    "items": items,
                    "source": "task_hook",
                }
            )
            continue

        # Case 1: Raw PreToolUse / tool call with a task tool (TodoWrite,
        # update_plan, write_todos, TaskCreate/TaskUpdate, ...). Supports
        # top-level and nested payloads (tool_use.name / tool_use.input ...).
        tool_name = first_string(payload, ["tool_name", "toolName", "tool"])
        if not tool_name:
            for nest_key in ("tool_use", "toolUse", "tool_use_input", "input"):
                nested = payload.get(nest_key)
                if isinstance(nested, dict):
                    tool_name = first_string(nested, ["name", "tool_name", "toolName", "tool"])
                    if tool_name:
                        break
        if tool_name and is_task_tool_name(tool_name):
            tool_input = first_object(payload, ["tool_input", "toolInput", "input"])
            if not tool_input:
                for nest_key in ("tool_use", "toolUse", "tool_use_input"):
                    nested = payload.get(nest_key)
                    if isinstance(nested, dict):
                        tool_input = first_object(nested, ["input", "tool_input", "toolInput"]) or nested
                        if tool_input:
                            break
            items = task_items_from_tool_input(tool_input)
            progress = None
            if agent == "cursor" and isinstance(tool_input, dict) and isinstance(tool_input.get("todos"), list):
                cursor_updates_by_session.setdefault(session_id, []).append(
                    {
                        "merge": bool(tool_input.get("merge", False)),
                        "todos": tool_input.get("todos", []),
                        "tool_input": tool_input,
                    }
                )
                progress = cursor_progress_from_updates(cursor_updates_by_session[session_id])
                items = cursor_items_from_updates(cursor_updates_by_session[session_id]) or items
            if items is None and isinstance(tool_input, dict):
                single = task_item_from_mapping(tool_input)
                task_key = first_string(tool_input, ["task_id", "taskId", "id"])
                if single is None and task_key:
                    # TaskUpdate-style call that only flips a status on an
                    # already-known task id.
                    existing = task_items_by_session.get(session_id, {}).get(task_key)
                    new_status = first_string(tool_input, TASK_STATUS_KEYS)
                    if existing and new_status:
                        single = {"title": existing["title"], "status": new_status}
                if single is not None:
                    items = aggregate_task_item(session_id, task_key or single["title"], single)
            if progress is None:
                progress = todo_progress(tool_input)
            if items is None or progress is None:
                # Some harnesses (Vibe) report the todo list in the tool
                # *output* rather than the input.
                tool_output = first_object(
                    payload,
                    ["tool_output", "toolOutput", "tool_response", "toolResponse", "output", "result"],
                )
                if isinstance(tool_output, dict):
                    items = items or task_items_from_tool_input(tool_output)
                    if items is None:
                        # Claude PostToolUse(TaskCreate/TaskUpdate) responses
                        # carry the mutated task object itself, nested under
                        # "task" or at top level.
                        task_object = tool_output.get("task")
                        if not isinstance(task_object, dict):
                            task_object = tool_output
                        single_output = task_item_from_mapping(task_object)
                        if single_output is not None:
                            out_key = (
                                first_string(task_object, ["task_id", "taskId", "id"])
                                or first_string(tool_input if isinstance(tool_input, dict) else {}, ["task_id", "taskId", "id"])
                                or single_output["title"]
                            )
                            items = aggregate_task_item(session_id, out_key, single_output)
                    if progress is None:
                        progress = todo_progress(tool_output)
            if progress is None and items:
                progress = task_items_done_total(items)
            if progress or items:
                observation = {
                    "event": record.event_name or "",
                    "tool": tool_name,
                    "raw_tool_name": tool_name,
                    "source": "raw_tool_call",
                }
                if progress:
                    observation["done"] = progress[0]
                    observation["total"] = progress[1]
                if items:
                    observation["items"] = items
                observations.append(observation)
            continue

        # Case 2: Canonical task.progress emitted by smart hook scripts
        # (Grok, future agents), or any hook payload carrying a `progress`
        # object — e.g. small-harness `PlanUpdated` reports
        # {"progress": {"done": n, "total": m, "items": [...]}}.
        progress_value = payload.get("progress")
        if record.event_name == "task.progress" or payload.get("event") == "task.progress" or isinstance(progress_value, dict):
            progress = progress_value if isinstance(progress_value, dict) else payload
            done = progress.get("done")
            total = progress.get("total")
            items = task_items_from_entries(progress.get("items")) or task_items_from_tool_input(progress) or task_items_from_tool_input(payload)
            if items and not (isinstance(done, int) and isinstance(total, int) and total > 0):
                done, total = task_items_done_total(items)
            if (isinstance(done, int) and isinstance(total, int) and total > 0) or items:
                event_label = record.event_name or str(payload.get("event") or payload.get("hook_event_name") or "task.progress")
                raw_tool_name = (
                    first_string(payload, ["tool_name", "toolName", "tool"])
                    or first_string(progress, ["tool"])
                    or ("TodoWrite" if event_label == "task.progress" else event_label)
                )
                observation = {
                    "event": event_label,
                    "tool": raw_tool_name,
                    "raw_tool_name": raw_tool_name,
                    "source": "canonical",
                }
                if isinstance(done, int) and isinstance(total, int):
                    observation["done"] = done
                    observation["total"] = total
                if items:
                    observation["items"] = items
                observations.append(observation)
    return observations


SUBAGENT_START_EVENTS = {"subagentstart", "subagent_start", "subagent-start"}
SUBAGENT_STOP_EVENTS = {"subagentstop", "subagent_stop", "subagent-stop", "subagentend", "subagent_end"}


def subagent_trace_extra(agent: str | None, event_name: str | None, stdin_payload: str | None) -> dict[str, Any] | None:
    """Capture, at record time, the facts Zentty's adapters derive from a
    SubagentStart/SubagentStop hook: the agent type from the payload and the
    model from the transcript sidecar next to it. Runs before redaction so the
    real transcript path can still be read; only derived values are stored."""
    lowered = (event_name or "").lower()
    payload = parse_json_object(stdin_payload)
    if lowered not in SUBAGENT_START_EVENTS | SUBAGENT_STOP_EVENTS:
        payload_event = str(first_string(payload, ["hook_event_name", "hookEventName"]) or "").lower()
        if payload_event in SUBAGENT_START_EVENTS | SUBAGENT_STOP_EVENTS:
            lowered = payload_event
        elif agent == "devin" and payload_event in ("pretooluse", "posttooluse") and payload.get("tool_name") in ("run_subagent", "sidekick"):
            # Devin has no Subagent* lifecycle events; the run_subagent /
            # sidekick tool call IS the contract. PreToolUse starts the
            # subagent (input carries title/profile/is_background, or
            # message/block for sidekick); PostToolUse ends a foreground run
            # or hands a background run off with `agent_id=<id>` embedded in
            # the output text.
            lowered = "subagentstart" if payload_event == "pretooluse" else "subagentstop"
        else:
            return None
    transcript_path = first_string(payload, ["agent_transcript_path", "agentTranscriptPath"])
    resolved = resolve_subagent_model(agent, transcript_path, payload)
    tool_input = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    agent_id = first_string(payload, ["agent_id", "agentId", "turn_id", "turnId"])
    run_agent_id: str | None = None
    if agent == "devin":
        # tool_use_id (`run_subagent_N`) is the stable key across the
        # PreToolUse/PostToolUse pair; the runtime `agent_id` only exists in
        # the PostToolUse output text.
        agent_id = agent_id or first_string(payload, ["tool_use_id", "toolUseId"])
        response = payload.get("tool_response") if isinstance(payload.get("tool_response"), dict) else {}
        match = re.search(r"agent_id=([A-Za-z0-9_-]+)", str(response.get("output") or ""))
        run_agent_id = match.group(1) if match else None
    agent_type = first_string(payload, ["agent_type", "agentType", "subagent_type", "subagentType", "agent_role", "agentRole"]) or first_string(
        tool_input, ["profile", "agent_type", "agentType"]
    )
    nickname = resolved.get("nickname") or first_string(tool_input, ["title"])
    if agent == "devin" and payload.get("tool_name") == "sidekick":
        # sidekick carries no profile/title — exactly one per session.
        agent_type = agent_type or "sidekick"
        nickname = nickname or "Sidekick"
    observation: dict[str, Any] = {
        "event": "start" if lowered in SUBAGENT_START_EVENTS else "stop",
        "agent_type": agent_type,
        "agent_id": agent_id,
        "transcript_path_present": bool(transcript_path),
        "transcript_exists": bool(transcript_path) and pathlib.Path(transcript_path).exists(),
        "model": resolved.get("model"),
        "nickname": nickname,
    }
    if run_agent_id:
        observation["run_agent_id"] = run_agent_id
    return {"subagent": observation}


def resolve_subagent_model(agent: str | None, transcript_path: str | None, payload: dict[str, Any]) -> dict[str, Any]:
    """Python mirror of AgentSubagentModelResolver so the bench proves the
    sidecar files the app relies on actually carry a model."""
    result: dict[str, Any] = {"model": first_string(payload, ["model", "model_id", "modelId"]), "nickname": None}
    if not transcript_path:
        return result
    path = pathlib.Path(transcript_path)
    if agent == "claude":
        meta_path = path.with_name(path.name[: -len(".jsonl")] + ".meta.json") if path.name.endswith(".jsonl") else pathlib.Path(str(path) + ".meta.json")
        meta = parse_json_object(_read_head(meta_path))
        if isinstance(meta.get("model"), str) and meta["model"].strip():
            result["model"] = meta["model"].strip()
            return result
        for line in (_read_head(path) or "").splitlines():
            if '"model"' not in line:
                continue
            obj = parse_json_object(line)
            message = obj.get("message")
            model = message.get("model") if isinstance(message, dict) else obj.get("model")
            if isinstance(model, str) and model.strip():
                result["model"] = model.strip()
                break
        return result
    if agent == "codex":
        for line in (_read_head(path) or "").splitlines():
            obj = parse_json_object(line)
            record_type = obj.get("type")
            record_payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
            if record_type == "session_meta":
                spawn = (((record_payload.get("source") or {}).get("subagent") or {}).get("thread_spawn") or {})
                if isinstance(spawn, dict) and isinstance(spawn.get("agent_nickname"), str):
                    result["nickname"] = spawn["agent_nickname"]
            elif record_type == "turn_context" and result.get("model") is None:
                model = record_payload.get("model")
                if isinstance(model, str) and model.strip():
                    result["model"] = model.strip()
            if result.get("model") and result.get("nickname"):
                break
        return result
    return result


def _read_head(path: pathlib.Path, max_bytes: int = 256 * 1024) -> str | None:
    try:
        with path.open("rb") as handle:
            return handle.read(max_bytes).decode("utf-8", errors="replace")
    except OSError:
        return None


def subagent_observations_for_records(agent: str, scenario: str, records: list[TraceRecord]) -> list[dict[str, Any]]:
    observations: list[dict[str, Any]] = []
    for record in records:
        if record.agent != agent or record.scenario != scenario or record.kind != "hook":
            continue
        if isinstance(record.extra, dict) and isinstance(record.extra.get("subagent"), dict):
            observations.append(dict(record.extra["subagent"]))
    return observations


def missing_subagent_payload_detail(observations: list[dict[str, Any]], model_required: bool = True) -> str | None:
    """None when the captured subagent hooks carry everything the sidebar
    needs; otherwise a one-line explanation of what was missing."""
    starts = [item for item in observations if item.get("event") == "start"]
    stops = [item for item in observations if item.get("event") == "stop"]
    if not starts:
        return "no SubagentStart hook payload was captured"
    if not stops:
        return "SubagentStart captured but no SubagentStop followed"
    if not any(item.get("agent_type") for item in observations):
        return "subagent hooks captured but none named an agent type"
    if not model_required:
        return None
    if not any(item.get("model") for item in observations):
        if any(item.get("transcript_exists") for item in observations):
            return "subagent transcript exists but no model could be resolved from it"
        return "subagent hooks captured but no transcript sidecar was available to resolve the model"
    return None


def missing_nested_subagent_detail(observations: list[dict[str, Any]]) -> str | None:
    """None when the captured subagent hooks prove a nested spawn: at least
    two starts with distinct agent ids, at least two stops, and every stop id
    matching a start id. Otherwise a one-line explanation."""
    starts = [item for item in observations if item.get("event") == "start"]
    stops = [item for item in observations if item.get("event") == "stop"]
    if len(starts) < 2:
        return f"nested subagents require at least 2 SubagentStart hooks but {len(starts)} were captured"
    if len(stops) < 2:
        return f"nested subagents require at least 2 SubagentStop hooks but {len(stops)} were captured"
    start_ids = [item.get("agent_id") for item in starts]
    if any(not agent_id for agent_id in start_ids):
        return "SubagentStart payload did not carry an agent_id"
    if len(set(start_ids)) < 2:
        return f"SubagentStart hooks did not carry distinct agent ids: {', '.join(str(item) for item in start_ids)}"
    unmatched = [str(item.get("agent_id")) for item in stops if item.get("agent_id") not in start_ids]
    if unmatched:
        return f"SubagentStop agent_id did not match any SubagentStart: {', '.join(unmatched)}"
    # Compare with multiplicity: a duplicated outer stop must not stand in
    # for the inner agent's missing completion.
    stop_counts = Counter(str(item.get("agent_id")) for item in stops)
    missing = sorted(agent_id for agent_id, count in Counter(str(a) for a in start_ids).items() if stop_counts[agent_id] < count)
    if missing:
        return f"SubagentStart without a matching SubagentStop: {', '.join(missing)}"
    return None


def event_order_violation_detail(agent: str, scenario: str, expectation: ScenarioExpectation, records: list[TraceRecord]) -> str | None:
    """None when every `event_order` pair holds; otherwise which pair broke
    and the observed hook sequence, so the report explains the failure."""
    observed = [
        name
        for record in records
        if record.kind == "hook" and record.agent == agent and record.scenario == scenario
        for name in hook_record_event_names(record)
        if name
    ]
    for pair in expectation.event_order:
        if len(pair) != 2:
            return f"event_order entry must be a [before, after] pair: {pair}"
        before, after = pair
        if before not in observed:
            return f"expected {before} before {after} but {before} was never observed"
        if after not in observed:
            return f"expected {before} before {after} but {after} was never observed"
        first_before = observed.index(before)
        last_after = len(observed) - 1 - observed[::-1].index(after)
        if first_before > last_after:
            return f"expected {before} before {after} but observed order was: {', '.join(observed)}"
    return None


def subagent_contract_failure(
    agent: str,
    scenario: str,
    expectation: ScenarioExpectation,
    records: list[TraceRecord],
) -> tuple[str, str] | None:
    """(result_kind, detail) for the first subagent-contract expectation that
    the trace fails — payload facts, hook ordering, nested spawn — or None."""
    observations = subagent_observations_for_records(agent, scenario, records)
    if expectation.subagent_payload_required:
        detail = missing_subagent_payload_detail(observations, model_required=expectation.subagent_model_required)
        if detail:
            return "missing-subagent-payload", detail
    if expectation.event_order:
        detail = event_order_violation_detail(agent, scenario, expectation, records)
        if detail:
            return "hook-order", detail
    if expectation.subagent_nested_required:
        detail = missing_nested_subagent_detail(observations)
        if detail:
            return "missing-nested-subagent", detail
    return None


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


def cursor_trace_extra(agent: str | None, stdin_payload: str | None) -> dict[str, Any] | None:
    if agent != "cursor" or not stdin_payload:
        return None
    payload = parse_json_object(stdin_payload)
    task_progress = cursor_transcript_task_progress(payload)
    if not task_progress:
        return None
    return {"task_progress": task_progress}


def cursor_transcript_task_progress(payload: dict[str, Any], attempts: int = 5) -> dict[str, Any] | None:
    transcript_path = first_string(payload, ["transcript_path", "transcriptPath"])
    if not transcript_path:
        return None
    attempt_count = max(1, attempts)
    for attempt in range(attempt_count):
        text = read_text_file_tail(pathlib.Path(transcript_path), 256 * 1024)
        if text is not None:
            updates: list[dict[str, Any]] = []
            for raw_line in text.splitlines():
                line = raw_line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(record, dict):
                    continue
                updates.extend(cursor_todo_updates_in_object(record))
            items = cursor_items_from_updates(updates)
            progress = cursor_progress_from_updates(updates)
            if progress:
                result: dict[str, Any] = {
                    "tool": "TodoWrite",
                    "done": progress[0],
                    "total": progress[1],
                    "source": "cursor_transcript",
                }
                if items:
                    result["items"] = items
                return result
            for record_update in reversed(updates):
                progress = todo_progress(record_update.get("tool_input"))
                if progress:
                    result = {
                        "tool": "TodoWrite",
                        "done": progress[0],
                        "total": progress[1],
                        "source": "cursor_transcript",
                    }
                    update_items = items or task_items_from_tool_input(record_update.get("tool_input"))
                    if update_items:
                        result["items"] = update_items
                    return result
        if attempt < attempt_count - 1:
            time.sleep(0.05)
    return None


def cursor_progress_from_updates(updates: list[dict[str, Any]]) -> tuple[int, int] | None:
    todos: dict[str, str] = {}
    for update in updates:
        if not update.get("merge", False):
            todos = {}
        for todo in update.get("todos", []):
            if not isinstance(todo, dict):
                continue
            key = first_string(todo, ["id", "content", "text", "title"])
            status = first_string(todo, ["status", "state"]) or "pending"
            if key:
                todos[key] = status
    if not todos:
        return None
    return (sum(1 for status in todos.values() if todo_status_is_complete(status)), len(todos))


def cursor_items_from_updates(updates: list[dict[str, Any]]) -> list[dict[str, str]] | None:
    """Same merge semantics as cursor_progress_from_updates, but keeps the
    per-item title/status pairs for item-level assertions and reporting."""
    todos: dict[str, dict[str, str]] = {}
    for update in updates:
        if not update.get("merge", False):
            todos = {}
        for todo in update.get("todos", []):
            if not isinstance(todo, dict):
                continue
            key = first_string(todo, ["id", "content", "text", "title"])
            if key:
                todos[key] = {
                    "title": first_string(todo, ["content", "text", "title", "subject", "description"]) or key,
                    "status": first_string(todo, ["status", "state"]) or "pending",
                }
    return list(todos.values()) or None


def cursor_todo_updates_in_object(value: dict[str, Any], depth: int = 0) -> list[dict[str, Any]]:
    if depth >= 6:
        return []

    tool_name = first_string(value, ["name", "tool_name", "toolName", "tool"])
    if tool_name and tool_name.strip().lower() == "todowrite":
        tool_input = first_object(value, ["input", "tool_input", "toolInput"])
        if tool_input is None and "todos" in value:
            tool_input = value
        if isinstance(tool_input, dict) and isinstance(tool_input.get("todos"), list):
            return [
                {
                    "merge": bool(tool_input.get("merge", False)),
                    "todos": tool_input.get("todos", []),
                    "tool_input": tool_input,
                }
            ]

    updates: list[dict[str, Any]] = []
    for key in ("message", "tool_use", "toolUse", "tool_use_input", "input"):
        nested = value.get(key)
        if isinstance(nested, dict):
            updates.extend(cursor_todo_updates_in_object(nested, depth + 1))

    for key in ("content", "messages"):
        items = value.get(key)
        if not isinstance(items, list):
            continue
        for item in items:
            if isinstance(item, dict):
                updates.extend(cursor_todo_updates_in_object(item, depth + 1))
    return updates


def read_text_file_tail(path: pathlib.Path, max_bytes: int) -> str | None:
    try:
        with path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - max_bytes), os.SEEK_SET)
            return handle.read().decode("utf-8", errors="replace")
    except OSError:
        return None


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
        manifests: dict[str, dict[str, Any]] | None = None,
    ) -> None:
        self.socket_path = socket_path
        self.recorder = recorder
        self.profiles = profiles
        self.scenario = scenario
        self.resources_dir = resources_dir
        self.run_dir = run_dir or socket_path.parent
        self.manifests = manifests or {}
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._active = 0
        self._active_lock = threading.Lock()
        self.current_agent: str | None = None

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
        profile = self._profile_for_bootstrap_tool(tool)
        if profile is None:
            return self._error_response(request, f"Unsupported bootstrap tool: {tool}")
        plan = LaunchPlanner(
            profile=profile,
            scenario=self.scenario,
            run_dir=self.run_dir,
            resources_dir=self.resources_dir,
            manifests=self.manifests,
        ).plan(request)
        arguments = request.get("arguments") if isinstance(request.get("arguments"), list) else []
        self.recorder.append(
            TraceRecord(
                kind="bootstrap",
                agent=self._agent_name_for_profile(profile),
                scenario=self.scenario,
                extra={
                    "arguments": [str(argument) for argument in arguments],
                    "plan": plan,
                },
            )
        )
        return {
            "version": 1,
            "id": request.get("id", ""),
            "ok": True,
            "result": {"launchPlan": plan},
            "error": None,
        }

    def _profile_for_bootstrap_tool(self, tool: Any) -> AgentProfile | None:
        if not isinstance(tool, str):
            return None
        if current_profile := self._current_profile_for_tool(tool):
            return current_profile
        profile = self.profiles.get(tool)
        if profile and profile.tool == tool:
            return profile
        matches = [profile for profile in self.profiles.values() if profile.tool == tool]
        return matches[0] if len(matches) == 1 else None

    def _current_profile_for_tool(self, tool: str | None) -> AgentProfile | None:
        if not tool or not self.current_agent:
            return None
        profile = self.profiles.get(self.current_agent)
        if profile and profile.tool == tool:
            return profile
        return None

    def _agent_name_for_profile(self, profile: AgentProfile) -> str:
        if self.current_agent and self.profiles.get(self.current_agent) is profile:
            return self.current_agent
        return profile.name

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
        agent = agent_from_adapter(
            hook.adapter,
            environment,
            stdin_payload if isinstance(stdin_payload, str) else None,
            manifests=self.manifests,
        )
        if current_profile := self._current_profile_for_tool(agent):
            agent = current_profile.name
        extra = cursor_trace_extra(agent, stdin_payload if isinstance(stdin_payload, str) else None)
        subagent_extra = subagent_trace_extra(agent, hook.event_name, stdin_payload if isinstance(stdin_payload, str) else None)
        if subagent_extra:
            extra = {**(extra or {}), **subagent_extra}
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
                extra=extra,
            )
        )


class LaunchPlanner:
    def __init__(
        self,
        profile: AgentProfile,
        scenario: str,
        run_dir: pathlib.Path,
        resources_dir: pathlib.Path | None,
        manifests: dict[str, dict[str, Any]] | None = None,
    ) -> None:
        self.profile = profile
        self.scenario = scenario
        self.run_dir = run_dir
        self.resources_dir = resources_dir
        self.manifests = manifests

    def plan(self, request: dict[str, Any]) -> dict[str, Any]:
        environment = request.get("environment") if isinstance(request.get("environment"), dict) else {}
        executable = str(environment.get("ZENTTY_REAL_BINARY") or self.profile.command)
        arguments = [str(arg) for arg in request.get("arguments", [])]
        cli_path = str(environment.get("ZENTTY_CLI_BIN") or "")
        # All `restore_launch*` scenarios exercise the bootstrap argument
        # forwarding path; we never need to actually execute the agent
        # process (which can fail synchronously on bogus session ids and race
        # the completion predicate).
        if self.scenario.startswith("restore_launch"):
            env = {"ZENTTY_AGENT_TOOL": self.profile.tool}
            if self.profile.tool == "kimi" and self.profile.kimi_variant:
                env["ZENTTY_KIMI_VARIANT"] = self.profile.kimi_variant
            return self._launch_plan("/usr/bin/true", [], env)
        method_name = f"_plan_{self.profile.tool.replace('-', '_')}"
        method = getattr(self, method_name, None)
        if method is not None:
            return method(executable, arguments, environment, cli_path)
        manifest = self._manifest_for_tool(environment)
        if manifest is not None:
            return self._plan_manifest(manifest, executable, arguments, environment, cli_path)
        return self._direct_plan(executable, arguments, environment, cli_path)

    def _manifest_for_tool(self, environment: dict[str, Any]) -> dict[str, Any] | None:
        manifests = self.manifests
        if manifests is None:
            manifests = load_agent_manifests(
                self.resources_dir,
                manifest_dirs_from_environment(environment),
            )
        return manifests.get(self.profile.tool)

    def _plan_manifest(
        self,
        manifest: dict[str, Any],
        executable: str,
        arguments: list[str],
        environment: dict[str, Any],
        cli_path: str,
    ) -> dict[str, Any]:
        """Mirror AgentLaunchBootstrap's `.manifest` branch: the launch plan is
        driven by the manifest's family rather than a hand-written per-tool
        method."""
        tool_id = str(manifest.get("id") or self.profile.tool)
        display_name = str(manifest.get("displayName") or tool_id)
        family = manifest.get("family")
        if family == "opencode-plugin":
            options = manifest.get("opencodePlugin")
            options = options if isinstance(options, dict) else {}
            return self._plan_opencode_family(
                tool_id=tool_id,
                display_name=display_name,
                env_prefix=str(options.get("envPrefix") or tool_id.upper().replace("-", "_")),
                config_dir_name=str(options.get("configDirName") or tool_id),
                executable=executable,
                arguments=arguments,
                environment=environment,
                cli_path=cli_path,
            )
        if family == "canonical":
            return self._plan_canonical_manifest(
                manifest,
                tool_id,
                display_name,
                executable,
                arguments,
                environment,
                cli_path,
            )
        return self._direct_plan(executable, arguments, environment, cli_path)

    def _plan_canonical_manifest(
        self,
        manifest: dict[str, Any],
        tool_id: str,
        display_name: str,
        executable: str,
        arguments: list[str],
        environment: dict[str, Any],
        cli_path: str,
    ) -> dict[str, Any]:
        # Mirror canonicalManifestPlan: without a CLI binary there is nothing
        # to expand {cliBin} against and no prelaunch event to send, so the
        # plan degrades to a direct exec.
        if not cli_path:
            return self._direct_plan(executable, arguments, environment, cli_path)
        canonical = manifest.get("canonical")
        canonical = canonical if isinstance(canonical, dict) else {}
        set_env = {
            "ZENTTY_AGENT_TOOL": tool_id,
            "ZENTTY_AGENT_CANONICAL_NAME": display_name,
        }
        env_overrides = canonical.get("env")
        if isinstance(env_overrides, dict):
            for key, value in env_overrides.items():
                set_env[str(key)] = str(value).replace("{cliBin}", cli_path)
        prepend = canonical.get("prependArguments")
        planned = [str(arg).replace("{cliBin}", cli_path) for arg in (prepend if isinstance(prepend, list) else [])] + arguments
        session_start = compact_json({
            "version": 1,
            "event": "session.start",
            "agent": {"name": display_name, "pid": "__ZENTTY_SELF_PID__"},
        })
        return self._launch_plan(
            executable,
            planned,
            set_env,
            prelaunch=[{"subcommand": "agent-event", "arguments": [], "standardInput": session_start}],
        )

    def _direct_plan(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        return self._launch_plan(executable, arguments, {"ZENTTY_AGENT_TOOL": self.profile.tool})

    def _plan_vibe(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        # Mirror AgentLaunchBootstrap.vibePlan: tag the tool and pre-send a
        # synthetic session.start (Vibe has no session-start hook of its own —
        # only before_tool/after_tool/post_agent_turn). The wrapper substitutes
        # the self-pid placeholder, which is what gives session_capture a tracked
        # pid via agent.pid. The Zentty-managed hooks in ~/.vibe/hooks.toml drive
        # the before_tool/after_tool/post_agent_turn records.
        #
        # We deliberately do NOT set VIBE_ENABLE_EXPERIMENTAL_HOOKS here, exactly
        # like the real vibePlan: the wrapper (AgentToolLauncher.run(plan:)) is
        # the sole owner of that flag. Leaving it out keeps this bench an honest
        # guard — if the wrapper stops setting it, Vibe fires no hooks and the
        # bench fails.
        launch_env = {str(k): str(v) for k, v in environment.items() if str(k).startswith("ZENTTY_")}
        context = compact_json({"launch": {"arguments": arguments, "environment": launch_env}})
        session_start = (
            '{"version":1,"event":"session.start","agent":{"name":"Mistral Vibe","pid":"__ZENTTY_SELF_PID__"},"context":'
            + context
            + "}"
        )
        return self._launch_plan(
            executable,
            arguments,
            {"ZENTTY_AGENT_TOOL": "vibe"},
            prelaunch=[
                {"subcommand": "agent-event", "arguments": ["--adapter=vibe"], "standardInput": session_start},
            ],
        )

    def _plan_amp(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        source_home = pathlib.Path(str(environment.get("HOME") or pathlib.Path.home())).expanduser()
        config_home = pathlib.Path(str(environment.get("XDG_CONFIG_HOME") or source_home / ".config")).expanduser()
        env = {
            "ZENTTY_AGENT_TOOL": "amp",
        }
        if self._install_amp_plugin(config_home):
            env["PLUGINS"] = "all"

        resume_arguments = sanitized_amp_resume_arguments(arguments)
        if resume_arguments:
            env["ZENTTY_AMP_RESUME_ARGUMENTS_JSON"] = compact_json(resume_arguments)
        session_start = compact_json({
            "version": 1,
            "event": "session.start",
            "agent": {"name": "Amp", "pid": "__ZENTTY_SELF_PID__"},
            "context": {"launch": {"arguments": resume_arguments}},
        })
        agent_running = compact_json({
            "version": 1,
            "event": "agent.running",
            "agent": {"name": "Amp", "pid": "__ZENTTY_SELF_PID__"},
            "context": {"launch": {"arguments": resume_arguments}},
        })
        return self._launch_plan(
            executable,
            arguments,
            env,
            prelaunch=[
                {"subcommand": "agent-event", "arguments": [], "standardInput": session_start},
                {"subcommand": "agent-event", "arguments": [], "standardInput": agent_running},
            ],
        )

    def _install_amp_plugin(self, config_home: pathlib.Path) -> bool:
        if not self.resources_dir:
            return False
        source = self.resources_dir / "amp" / "plugins" / AMP_PLUGIN_FILE_NAME
        if not source.exists():
            return False

        destination = config_home / "amp" / "plugins" / AMP_PLUGIN_FILE_NAME
        if destination.exists():
            try:
                existing = destination.read_text(encoding="utf-8")
            except OSError:
                existing = ""
            if AMP_PLUGIN_OWNERSHIP_MARKER not in existing:
                return False

        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        return True

    def _plan_claude(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        hook_command = claude_hook_command(cli_path, environment)
        settings = {"hooks": {}}
        # Mirror AgentLaunchBootstrap.claudePlan event-for-event, timeouts
        # included: SessionEnd is short so a hung IPC cannot hold the exit,
        # and the task/subagent hooks fire often enough that a slow one must
        # not stall the agent. The Swift plan is the source of truth.
        for event, timeout in (
            ("Stop", 10),
            ("SessionEnd", 1),
            ("Notification", 10),
            ("PermissionRequest", 10),
            ("UserPromptSubmit", 10),
            ("PreCompact", 10),
            ("PostCompact", 10),
            ("TaskCreated", 5),
            ("TaskCompleted", 5),
            ("SubagentStart", 5),
            ("SubagentStop", 5),
        ):
            settings["hooks"][event] = [{"matcher": "", "hooks": [{"type": "command", "command": hook_command, "timeout": timeout}]}]
        settings["hooks"]["SessionStart"] = [
            {"matcher": matcher, "hooks": [{"type": "command", "command": hook_command, "timeout": 10}]}
            for matcher in ("startup", "resume", "clear", "compact")
        ]
        settings["hooks"]["PreToolUse"] = [
            {"matcher": matcher, "hooks": [{"type": "command", "command": hook_command, "timeout": 5}]}
            for matcher in ("AskUserQuestion", "Bash|Write|Edit|MultiEdit|NotebookEdit")
        ]
        # Mirror AgentLaunchBootstrap.claudePlan: PostToolUse / PostToolUseFailure
        # are the only signals between an approved tool and the next matched
        # PreToolUse, so the sidebar can leave "Needs input" once work resumes.
        for event in ("PostToolUse", "PostToolUseFailure"):
            settings["hooks"][event] = [{"matcher": "", "hooks": [{"type": "command", "command": hook_command, "timeout": 5}]}]
        planned = ["--session-id", str(uuid.uuid4()).lower(), "--settings", compact_json(settings)] + arguments
        return self._launch_plan(executable, planned, {"ZENTTY_AGENT_TOOL": "claude"}, unset=["CLAUDECODE"])

    def _plan_codex(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        hook_specs = [
            ("SessionStart", "session_start", "session-start"),
            ("PreToolUse", "pre_tool_use", "pre-tool-use"),
            ("PermissionRequest", "permission_request", "permission-request"),
            ("PostToolUse", "post_tool_use", "post-tool-use"),
            ("UserPromptSubmit", "user_prompt_submit", "prompt-submit"),
            ("PreCompact", "pre_compact", "pre-compact"),
            ("PostCompact", "post_compact", "post-compact"),
            ("SubagentStart", "subagent_start", "subagent-start"),
            ("SubagentStop", "subagent_stop", "subagent-stop"),
            ("Stop", "stop", "stop"),
        ]
        hook_config_args = ["features.hooks=true"]
        trust_states: list[tuple[str, str]] = []
        for event, event_key, arg in hook_specs:
            command = f'"{shell_escape_double_quoted(cli_path)}" ipc agent-event --adapter=codex {arg} || echo \'{{}}\''
            hook_config_args.append(f"hooks.{event}=[{{hooks=[{{type=\"command\",command={quoted_toml_basic_string(command)},timeout=10}}]}}]")
            state_key = f"/<session-flags>/config.toml:{event_key}:0:0"
            trust_states.append((state_key, codex_hook_trusted_hash(event_key, None, command, 10)))
        state_entries = ",".join(
            f"{quoted_toml_basic_string(key)}={{trusted_hash={quoted_toml_basic_string(trusted_hash)}}}"
            for key, trusted_hash in trust_states
        )
        hook_config_args.append(f"hooks.state={{{state_entries}}}")
        planned = [
            "-c",
            f'notify={toml_string_array([cli_path, "codex-notify"])}',
            *(item for config in hook_config_args for item in ("-c", config)),
            "-c",
            "tui.notification_method=osc9",
            "-c",
            'tui.terminal_title=["status","spinner","project","task-progress"]',
        ] + arguments
        unset = ["CODEX_HOME"] if is_zentty_launch_cache_path(str(environment.get("CODEX_HOME") or "")) else []
        return self._launch_plan(executable, planned, {"ZENTTY_AGENT_TOOL": "codex"}, unset=unset)

    def _plan_small_harness(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        hook_file = self._overlay_dir("small-harness") / "managed-hooks.json"
        command = f'"{shell_escape_double_quoted(cli_path)}" ipc agent-event --adapter=small-harness || printf \'{{}}\\n\''
        hooks = {
            event: [{"hooks": [{"type": "command", "command": command, "envVars": SMALL_HARNESS_HOOK_ENV_VARS, "timeoutSec": timeout}]}]
            for event, timeout in (
                ("SessionStart", 10),
                ("UserPromptSubmit", 10),
                ("PreToolUse", 10),
                ("PermissionRequest", 10),
                ("PostToolUse", 10),
                ("PreCompact", 10),
                ("PostCompact", 10),
                ("PlanUpdated", 10),
                ("SubagentStart", 10),
                ("SubagentStop", 10),
                ("Stop", 10),
                ("SessionEnd", 1),
            )
        }
        write_json(hook_file, {"source": "zentty", "hooks": hooks})
        return self._launch_plan(
            executable,
            arguments,
            {
                "ZENTTY_AGENT_TOOL": "small-harness",
                "SMALL_HARNESS_MANAGED_HOOKS_FILE": str(hook_file),
            },
            unset=["SMALL_HARNESS_MANAGED_HOOKS_JSON"],
        )

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
        for event in (
            "sessionStart",
            "sessionEnd",
            "beforeSubmitPrompt",
            "stop",
            "beforeShellExecution",
            "afterShellExecution",
            "subagentStart",
            "subagentStop",
        ):
            hooks["hooks"][event] = [{"command": command}]
        for event in ("preToolUse", "postToolUse"):
            hooks["hooks"][event] = [{"matcher": "TodoWrite", "command": command}]
        write_json(config_dir / "hooks.json", hooks)
        return self._launch_plan(executable, arguments, {"ZENTTY_AGENT_TOOL": "cursor", "CURSOR_CONFIG_DIR": str(config_dir)})

    def _plan_devin(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        """Mirror of AgentLaunchBootstrap.devinPlan: `--config` replaces the
        user config, so the overlay is the user's real
        ~/.config/devin/config.json merged with the Zentty hook groups. A
        user-supplied --config is consumed and becomes the merge source. A
        byte-identical config.launch.json snapshot is written beside the
        overlay and the overlay/source paths are exported so hook events can
        sync in-session settings changes back to the source
        (DevinConfigWriteBack)."""
        command = f'"{shell_escape_double_quoted(cli_path)}" ipc agent-event --adapter=devin'
        hook_specs = (
            ("SessionStart", 10), ("SessionEnd", 1), ("UserPromptSubmit", 10),
            ("PreToolUse", 5), ("PostToolUse", 5), ("PermissionRequest", 10),
            ("Stop", 10), ("PostCompaction", 10),
        )
        hook_group = lambda timeout: {"matcher": "", "hooks": [{"type": "command", "command": command, "timeout": timeout}]}

        forwarded, source_override = _extract_devin_config_override(arguments)
        if source_override:
            source = pathlib.Path(source_override).expanduser()
            if not source.is_absolute():
                source = pathlib.Path(str(environment.get("PWD") or pathlib.Path.cwd())) / source
        else:
            home = pathlib.Path(str(environment.get("HOME") or pathlib.Path.home())).expanduser()
            source = home / ".config" / "devin" / "config.json"

        config = read_jsonc_object(source)
        hooks = config.get("hooks") if isinstance(config.get("hooks"), dict) else {}
        for event, timeout in hook_specs:
            groups = hooks.get(event) if isinstance(hooks.get(event), list) else []
            if not any(
                isinstance(group, dict)
                and any(
                    isinstance(hook, dict) and hook.get("type") == "command" and hook.get("command") == command
                    for hook in group.get("hooks") if isinstance(hook, dict)
                )
                for group in groups
            ):
                groups.append(hook_group(timeout))
            hooks[event] = groups
        config["hooks"] = hooks

        overlay = self._overlay_dir("devin") / "config.json"
        write_json(overlay, config)
        # Launch snapshot for the write-back diff — byte-identical to the
        # overlay, mirroring DevinConfigWriteBack.snapshotFileName.
        (overlay.parent / "config.launch.json").write_bytes(overlay.read_bytes())
        return self._launch_plan(
            executable,
            ["--config", str(overlay), *forwarded],
            {
                "ZENTTY_AGENT_TOOL": "devin",
                "ZENTTY_DEVIN_CONFIG_OVERLAY": str(overlay),
                "ZENTTY_DEVIN_CONFIG_SOURCE": str(source),
            },
        )

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
        variant = self._kimi_variant(executable, environment)
        command = toml_basic_string(f'"{shell_escape_double_quoted(cli_path)}" ipc agent-event --adapter=kimi')
        entries = "\n".join(f'[[hooks]]\nevent = "{event}"\ncommand = "{command}"\n' for event in ("SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "Notification", "PreToolUse", "PostToolUse"))
        source_dir = kimi_config_source_dir(environment, variant)
        source = source_dir / "config.toml"
        existing = remove_top_level_toml_key(source.read_text(encoding="utf-8"), "hooks") if source.exists() else ""
        separator = "\n\n" if existing.strip() else ""
        merged = existing.rstrip() + separator + entries
        env = {"ZENTTY_AGENT_TOOL": "kimi", "ZENTTY_KIMI_VARIANT": variant}
        if variant == "modern":
            # Modern kimi-code matches sessions by lexical home-path prefix, so
            # any symlinked overlay home breaks resume. Run against the REAL home.
            inherited = str(environment.get("KIMI_CODE_HOME") or "").strip()
            unset: list[str] = []
            home = str(environment.get("HOME") or pathlib.Path.home())
            default_home = pathlib.Path(home) / ".kimi-code"
            if inherited and is_zentty_launch_cache_path(inherited):
                # Stale overlay home from a pre-fix snapshot: strip it and fall
                # back to the real default home, where we install hooks.
                run_home = default_home
                unset = ["KIMI_CODE_HOME"]
                install_hooks = True
            elif inherited:
                # Genuine custom KIMI_CODE_HOME: run there but do NOT modify the
                # user's config — mirrors the Swift bootstrap, which skips the
                # persistent install for a user-set home.
                run_home = pathlib.Path(inherited)
                install_hooks = False
            else:
                run_home = default_home
                install_hooks = True

            run_home.mkdir(parents=True, exist_ok=True)
            if install_hooks:
                # Install a marker-delimited managed block (same markers/layout as
                # the Swift KimiHooksInstaller) idempotently: strip any prior
                # managed block first, so hooks never accumulate and Swift's
                # uninstall can remove a bench-written block.
                config_path = run_home / "config.toml"
                existing_config = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
                updated_config = install_kimi_managed_hook_block(existing_config, command)
                if updated_config != existing_config:
                    config_path.write_text(updated_config, encoding="utf-8")
            canonicalize_kimi_session_index_if_needed(run_home)
            return self._launch_plan(executable, arguments, env, unset=unset)
        overlay = self._overlay_dir("kimi") / "config.toml"
        overlay.write_text(merged, encoding="utf-8")
        return self._launch_plan(executable, ["--config-file", str(overlay)] + arguments, env)

    def _kimi_variant(self, executable: str, environment: dict[str, Any]) -> str:
        if self.profile.kimi_variant in ("legacy", "modern"):
            return self.profile.kimi_variant
        if environment.get("ZENTTY_KIMI_VARIANT") in ("legacy", "modern"):
            return str(environment["ZENTTY_KIMI_VARIANT"])
        return probe_kimi_variant(executable) or "legacy"

    def _plan_opencode(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        return self._plan_opencode_family(
            tool_id="opencode",
            display_name="OpenCode",
            env_prefix="OPENCODE",
            config_dir_name="opencode",
            executable=executable,
            arguments=arguments,
            environment=environment,
            cli_path=cli_path,
        )

    def _plan_opencode_family(
        self,
        tool_id: str,
        display_name: str,
        env_prefix: str,
        config_dir_name: str,
        executable: str,
        arguments: list[str],
        environment: dict[str, Any],
        cli_path: str,
    ) -> dict[str, Any]:
        """Shared plan for every `opencode-plugin` family manifest (opencode,
        kilo, …). Mirrors AgentLaunchBootstrap.openCodeFamilyPlan: the overlay
        dir is named by tool id, the shared zentty plugin is dropped into
        `plugins/`, and the agent's `<PREFIX>_CONFIG_DIR` points at the
        overlay. The approval scenario forces `permission.bash = "ask"` in the
        overlay's `<configDirName>.json` so the run blocks on a real
        permission prompt."""
        overlay = self._overlay_dir(tool_id) / "config"
        source_path = str(environment.get(f"{env_prefix}_CONFIG_DIR") or "").strip()
        source = pathlib.Path(source_path) if source_path else None
        if source:
            copy_directory_contents(source, overlay)
        plugin = self.resources_dir / "opencode" / "plugins" / "zentty-opencode-zentty.js" if self.resources_dir else None
        if plugin and plugin.exists():
            plugins = overlay / "plugins"
            plugins.mkdir(parents=True, exist_ok=True)
            shutil.copy2(plugin, plugins / plugin.name)
        config_file = overlay / f"{config_dir_name}.json"
        if self.scenario == "approval":
            config = read_json_object(config_file)
            permission = config.get("permission") if isinstance(config.get("permission"), dict) else {}
            permission["bash"] = "ask"
            config["permission"] = permission
            write_json(config_file, config)
        prelaunch = compact_json({
            "version": 1,
            "event": "session.start",
            "agent": {"name": display_name, "pid": "__ZENTTY_SELF_PID__"},
        })
        return self._launch_plan(
            executable,
            arguments,
            {
                "ZENTTY_AGENT_TOOL": tool_id,
                "ZENTTY_AGENT_CANONICAL_NAME": display_name,
                f"{env_prefix}_CONFIG": str(config_file),
                f"{env_prefix}_CONFIG_DIR": str(overlay),
                f"ZENTTY_{env_prefix}_BASE_CONFIG_DIR": str(source or ""),
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
            {"ZENTTY_AGENT_TOOL": "pi", "ZENTTY_AGENT_CANONICAL_NAME": "Pi"},
            prelaunch=[{"subcommand": "agent-event", "arguments": [], "standardInput": prelaunch}],
        )

    def _plan_omp(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        planned = list(arguments)
        extension = self.resources_dir / "omp" / "extensions" / "zentty-omp-zentty.js" if self.resources_dir else None
        if extension and extension.exists():
            planned = ["-e", str(extension)] + planned
        prelaunch = '{"version":1,"event":"session.start","agent":{"name":"OMP","pid":"__ZENTTY_SELF_PID__"}}'
        return self._launch_plan(
            executable,
            planned,
            {"ZENTTY_AGENT_TOOL": "omp", "ZENTTY_AGENT_CANONICAL_NAME": "OMP"},
            prelaunch=[{"subcommand": "agent-event", "arguments": [], "standardInput": prelaunch}],
        )

    def _plan_grok(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        # Build a sandboxed HOME that mirrors what the real `GrokHooksInstaller`
        # would drop on disk in production:
        #   ~/.grok/hooks/zentty-status.json      (the "Always trusted" config)
        #   ~/.grok/hooks/zentty-status/01-zentty-status.sh   (the forwarder)
        #
        # Skip `hooks`, `config.toml`, and `plugins` from the real-home symlink
        # set so the overlay only has what we put there (no leaked broken
        # installs from previous Zentty versions).
        home = self._overlay_home("grok", environment, {".grok": {"hooks", "config.toml", "plugins"}})
        grok_hooks_root = home / ".grok" / "hooks"
        grok_hooks_root.mkdir(parents=True, exist_ok=True)

        # The overlay must NOT have a legacy user-settings.json or hooks-paths
        # — those were never hook sources in Grok and we don't write them
        # anymore. Drop them if they leaked in via the symlink set.
        for reg_name in ("user-settings.json", "hooks-paths"):
            reg_path = home / ".grok" / reg_name
            if reg_path.is_symlink() or reg_path.exists():
                try:
                    reg_path.unlink()
                except OSError:
                    pass

        # Forwarder script — hardcode the absolute CLI path so grok-launched
        # children find `zentty` even if grok strips ZENTTY_CLI_BIN.
        escaped_cli = shell_escape_double_quoted(cli_path)
        ipc_grok_cmd = f'"{escaped_cli}" ipc agent-event --adapter=grok'
        forwarder_dir = grok_hooks_root / "zentty-status"
        forwarder_dir.mkdir(exist_ok=True)
        script_path = forwarder_dir / "01-zentty-status.sh"
        script_path.write_text(
            "#!/usr/bin/env bash\n"
            "# Zentty bench overlay forwarder for Grok hooks.\n"
            f"exec {ipc_grok_cmd}\n"
        )
        script_path.chmod(0o755)

        # Single JSON hook config at the "Always trusted" location.
        # SCHEMA: lifecycle events MUST NOT carry a `matcher`; tool-use events
        # may. Binary string: "lifecycle hooks () must not specify a matcher
        # in v0". Including a matcher on a lifecycle event silently invalidates
        # the entry — that's exactly the bug this rewrite fixes.
        lifecycle_events = [
            "SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "Notification",
            "SubagentStart", "SubagentStop", "BeforeAgent", "AfterAgent",
        ]
        tool_events = ["PreToolUse", "PostToolUse"]
        hooks_json: dict[str, Any] = {"hooks": {}}
        for event_name in lifecycle_events:
            hooks_json["hooks"][event_name] = [
                {"hooks": [{"type": "command", "command": str(script_path), "timeout": 15}]}
            ]
        for event_name in tool_events:
            hooks_json["hooks"][event_name] = [
                {"matcher": ".*", "hooks": [{"type": "command", "command": str(script_path), "timeout": 15}]}
            ]
        (grok_hooks_root / "zentty-status.json").write_text(json.dumps(hooks_json, indent=2))

        # This launch plan is only reached when the agent wrapper goes through
        # bootstrap. That requires ZENTTY_PANE_TOKEN/WORKLANE_ID/PANE_ID in
        # the env — see `BenchRunner.run` where we set those alongside the
        # capture socket.
        return self._launch_plan(
            executable,
            arguments,
            {"ZENTTY_AGENT_TOOL": "grok", "HOME": str(home)},
        )

    _HERMES_HOOK_EVENTS = [
        ("on_session_start", "on-session-start", 5),
        ("on_session_reset", "on-session-reset", 5),
        ("pre_llm_call", "pre-llm-call", 5),
        ("post_llm_call", "post-llm-call", 5),
        ("on_session_end", "on-session-end", 5),
        ("on_session_finalize", "on-session-finalize", 5),
        ("pre_tool_call", "pre-tool-call", 5),
        ("post_tool_call", "post-tool-call", 5),
        ("pre_approval_request", "pre-approval-request", 30),
        ("post_approval_response", "post-approval-response", 5),
    ]

    @staticmethod
    def _hermes_hook_script_body(cli_path: str, cli_event: str) -> str:
        return (
            "#!/bin/sh\n"
            "# Zentty-managed Hermes hook.\n"
            "# Marker: zentty hermes hook script v1\n\n"
            "if [ \"${ZENTTY_HERMES_HOOKS_DISABLED:-}\" = \"1\" ]; then\n"
            "    printf '{}\\n'\n"
            "    exit 0\n"
            "fi\n\n"
            f"ZENTTY_BIN={shlex.quote(cli_path)}\n"
            "if [ -z \"$ZENTTY_BIN\" ] || [ ! -x \"$ZENTTY_BIN\" ]; then\n"
            "    ZENTTY_BIN=\"$(command -v zentty 2>/dev/null || true)\"\n"
            "fi\n"
            "if [ -z \"$ZENTTY_BIN\" ]; then\n"
            "    printf '{}\\n'\n"
            "    exit 0\n"
            "fi\n\n"
            "zentty_resolve_hermes_pid() {\n"
            "    candidate=\"${PPID:-}\"\n"
            "    while [ -n \"$candidate\" ] && [ \"$candidate\" -gt 1 ] 2>/dev/null; do\n"
            "        command_line=\"$(ps -p \"$candidate\" -o command= 2>/dev/null || true)\"\n"
            "        case \"$command_line\" in\n"
            "            *\"/hermes\"*|*\" hermes\"*|*\"hermes-agent\"*)\n"
            "                printf '%s\\n' \"$candidate\"\n"
            "                return 0\n"
            "                ;;\n"
            "        esac\n"
            "        candidate=\"$(ps -p \"$candidate\" -o ppid= 2>/dev/null | tr -d ' ' || true)\"\n"
            "    done\n"
            "    return 1\n"
            "}\n\n"
            "if [ -z \"${ZENTTY_HERMES_PID:-}\" ]; then\n"
            "    if ZENTTY_RESOLVED_HERMES_PID=\"$(zentty_resolve_hermes_pid)\"; then\n"
            "        ZENTTY_HERMES_PID=\"$ZENTTY_RESOLVED_HERMES_PID\"\n"
            "        export ZENTTY_HERMES_PID\n"
            "    fi\n"
            "fi\n\n"
            f"\"$ZENTTY_BIN\" hermes-hook {cli_event} || printf '{{}}\\n'\n"
            "exit 0\n"
        )

    @classmethod
    def _write_hermes_hook_script(cls, hooks_dir: pathlib.Path, cli_path: str, cli_event: str) -> pathlib.Path:
        hooks_dir.mkdir(parents=True, exist_ok=True)
        script_path = hooks_dir / f"{cli_event}.sh"
        script_path.write_text(cls._hermes_hook_script_body(cli_path, cli_event), encoding="utf-8")
        script_path.chmod(0o755)
        return script_path

    def _plan_hermes(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        home = self._overlay_dir("hermes") / "home"
        home.mkdir(parents=True, exist_ok=True)
        source_hermes_home = config_source_dir(environment, "HERMES_HOME", ".hermes")
        hermes_home = home / ".hermes"
        mutable_names = {
            ".hermes_history",
            ".update_check",
            "audio_cache",
            "auth.json",
            "auth.lock",
            "config.yaml",
            "hooks",
            "image_cache",
            "interrupt_debug.log",
            "logs",
            "pairing",
            "sandboxes",
            "sessions",
            "shell-hooks-allowlist.json",
            "shell-hooks-allowlist.json.lock",
            "state.db",
            "state.db-shm",
            "state.db-wal",
        }
        symlink_directory_contents_skipping(source_hermes_home, hermes_home, mutable_names)
        for mutable_file_name in ["auth.json", "state.db", "state.db-shm", "state.db-wal"]:
            source_file = source_hermes_home / mutable_file_name
            if source_file.exists():
                shutil.copy2(source_file, hermes_home / mutable_file_name)

        hook_config_lines = ["hooks:"]
        approvals = []
        hooks_dir = hermes_home / "hooks" / "zentty-status"
        for event_name, cli_event, timeout in self._HERMES_HOOK_EVENTS:
            command = str(self._write_hermes_hook_script(hooks_dir, cli_path, cli_event))
            hook_config_lines.extend([
                f"  {event_name}:",
                f"    - command: {json.dumps(command)}",
                f"      timeout: {timeout}",
            ])
            approvals.append({
                "event": event_name,
                "command": command,
                "approved_at": "agent-bench",
            })
        source_config = source_hermes_home / "config.yaml"
        source_config_text = source_config.read_text(encoding="utf-8") if source_config.exists() else ""
        config_text = replace_top_level_yaml_block(source_config_text, "hooks", "\n".join(hook_config_lines))
        (hermes_home / "config.yaml").write_text(config_text, encoding="utf-8")
        write_json(hermes_home / "shell-hooks-allowlist.json", {"approvals": approvals})

        launch: dict[str, Any] = {"arguments": arguments}
        if str(environment.get("HERMES_HOME") or "").strip():
            launch["environment"] = {"HERMES_HOME": str(hermes_home)}
        context = compact_json({"launch": launch})
        session_start = '{"version":1,"event":"session.start","agent":{"name":"Hermes Agent","pid":"__ZENTTY_SELF_PID__"},"context":' + context + "}"
        running = '{"version":1,"event":"agent.running","agent":{"name":"Hermes Agent","pid":"__ZENTTY_SELF_PID__"},"context":' + context + "}"
        return self._launch_plan(
            executable,
            arguments,
            {
                "ZENTTY_AGENT_TOOL": "hermes",
                "HOME": str(home),
                "HERMES_HOME": str(hermes_home),
            },
            prelaunch=[
                {"subcommand": "agent-event", "arguments": ["--adapter=hermes"], "standardInput": session_start},
                {"subcommand": "agent-event", "arguments": ["--adapter=hermes"], "standardInput": running},
            ],
        )

    # Antigravity hook events Zentty subscribes to, kept in sync with
    # AgyHooksInstaller.events on the Swift side. Tool-use events take the
    # `{matcher, hooks:[...]}` wrapper; lifecycle events are plain entries.
    _AGY_LIFECYCLE_HOOK_EVENTS = [
        ("SessionStart", "session-start"),
        ("PreInvocation", "prompt-submit"),
        ("Stop", "stop"),
        ("turn-completion", "turn-completion"),
        ("Notification", "notification"),
        ("SessionEnd", "session-end"),
    ]
    _AGY_TOOL_HOOK_EVENTS = [
        ("PreToolUse", "pre-tool-use"),
        ("PostToolUse", "post-tool-use"),
    ]

    @staticmethod
    def _agy_hook_command(cli_path: str, cli_event: str) -> str:
        # Mirror AgyHooksInstaller.hookCommand so the bench exercises the same
        # shell shape the production installer writes.
        escaped = shell_escape_double_quoted(cli_path)
        return (
            ": zentty-agy-hook-v1; "
            'if [ "$ZENTTY_AGY_HOOKS_DISABLED" = "1" ]; then echo \'{}\'; exit 0; fi; '
            f"\"{escaped}\" agy-hook {cli_event} 2>/dev/null || echo '{{}}'"
        )

    def _plan_agy(self, executable: str, arguments: list[str], environment: dict[str, Any], cli_path: str) -> dict[str, Any]:
        # Skip both `antigravity-cli` (auth/state we never touch) and `config`
        # from the top-level symlink set so we can place a hooks.json we own
        # under `.gemini/config/` without mutating the real user file.
        home = self._overlay_home("agy", environment, {".gemini": {"antigravity-cli", "config"}})
        source_home = pathlib.Path(str(environment.get("HOME") or pathlib.Path.home()))

        # agy keeps its OAuth login in the macOS login keychain
        # (~/Library/Keychains), NOT under ~/.gemini. Because the overlay
        # redirects HOME, agy resolves the keychain at
        # <overlay>/Library/Keychains, finds nothing, and starts logged out —
        # forcing an interactive browser login and breaking the `tools` /
        # `session_capture` scenarios (auth-skip, no real conversation id).
        # Symlink the real login keychain into the overlay so agy reuses the
        # user's existing global Antigravity login. Only auth material is
        # shared; the agent's conversations / history / state stay isolated in
        # the fresh overlay `antigravity-cli`, preserving restore_launch
        # fixture hermeticity. If the keychain is absent (not logged in, or a
        # non-macOS host) we do nothing and behave exactly as before.
        real_keychains = source_home / "Library" / "Keychains"
        if real_keychains.exists():
            overlay_keychains = home / "Library" / "Keychains"
            overlay_keychains.parent.mkdir(parents=True, exist_ok=True)
            if not overlay_keychains.exists() and not overlay_keychains.is_symlink():
                overlay_keychains.symlink_to(real_keychains)

        # Rebuild `.gemini/config` in the overlay: symlink the real config's
        # contents (so agy still sees the user's settings) except hooks.json,
        # which we own and write fresh pointing at the bench CLI. This makes
        # the `tools` scenario hermetic — it no longer depends on the host
        # user having run `zentty install agy-hooks` first.
        overlay_config = home / ".gemini" / "config"
        symlink_directory_contents_skipping(
            source_home / ".gemini" / "config", overlay_config, {"hooks.json"}
        )
        zentty_group: dict[str, Any] = {}
        for agent_event, cli_event in self._AGY_LIFECYCLE_HOOK_EVENTS:
            zentty_group[agent_event] = [
                {"type": "command", "command": self._agy_hook_command(cli_path, cli_event), "timeout": 15}
            ]
        for agent_event, cli_event in self._AGY_TOOL_HOOK_EVENTS:
            zentty_group[agent_event] = [
                {"matcher": "*", "hooks": [{"type": "command", "command": self._agy_hook_command(cli_path, cli_event), "timeout": 120}]}
            ]
        (overlay_config / "hooks.json").write_text(json.dumps({"zentty": zentty_group}, indent=2))

        # Mirror the per-launch placeholder the Swift bootstrap mints (see
        # AgentLaunchBootstrap.agyPlan). The `zentty-placeholder-` prefix
        # is what the resume builder uses to recognise and reject this id
        # when no real `conversation_id` ever arrives from a hook.
        placeholder_session_id = "zentty-placeholder-" + str(uuid.uuid4())
        launch_context = json.dumps({"launch": {"arguments": arguments}}, separators=(",", ":"))
        prelaunch = '{"version":1,"event":"session.start","agent":{"name":"Antigravity","pid":"__ZENTTY_SELF_PID__"},"session":{"id":"' + placeholder_session_id + '"},"context":' + launch_context + "}"
        running = '{"version":1,"event":"agent.running","agent":{"name":"Antigravity","pid":"__ZENTTY_SELF_PID__"},"session":{"id":"' + placeholder_session_id + '"},"context":' + launch_context + "}"
        return self._launch_plan(
            executable,
            arguments,
            {
                "ZENTTY_AGENT_TOOL": "agy",
                "ZENTTY_AGY_PLACEHOLDER_SESSION_ID": placeholder_session_id,
                "HOME": str(home),
            },
            prelaunch=[
                {"subcommand": "agent-event", "arguments": ["--adapter=agy"], "standardInput": prelaunch},
                {"subcommand": "agent-event", "arguments": ["--adapter=agy"], "standardInput": running},
            ],
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


def agent_from_adapter(
    adapter: str | None,
    environment: dict[str, Any],
    standard_input: str | None = None,
    manifests: dict[str, dict[str, Any]] | None = None,
) -> str | None:
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
        # Grok Build (xAI) — Claude Code compatible; may self-report as "Grok", "Grok Build", "xAI Grok", etc.
        # Also handle direct normalized match.
        if normalized.startswith("grok") or normalized in ("xaigrok", "grokbuild"):
            return "grok"
        if normalized in SUPPORTED_AGENTS:
            return normalized
        # Manifest agents self-report their displayName in the payload; the
        # fixed forwarded-environment whitelist does not carry
        # ZENTTY_AGENT_TOOL, so the displayName is the only identity hint.
        for manifest_id, manifest in (manifests or {}).items():
            display = str(manifest.get("displayName") or "").strip().lower().replace(" ", "")
            if display and display == normalized:
                return manifest_id
    return adapter


def parse_event_order(profile_name: str, scenario: str, raw: Any) -> list[list[str]]:
    """Validate a profile's `event_order` at load time so a malformed pair
    fails the whole run up front instead of surfacing as a confusing
    per-scenario failure after the agent has already been driven."""
    if raw is None:
        return []
    if not isinstance(raw, list):
        raise ValueError(f"{profile_name} scenario {scenario!r}: event_order must be a list of [before, after] pairs, got {raw!r}")
    pairs: list[list[str]] = []
    for entry in raw:
        if (
            not isinstance(entry, list)
            or len(entry) != 2
            or not all(isinstance(event, str) and event.strip() for event in entry)
        ):
            raise ValueError(
                f"{profile_name} scenario {scenario!r}: each event_order entry must be a [before, after] pair "
                f"of non-empty strings, got {entry!r}"
            )
        pairs.append([entry[0], entry[1]])
    return pairs


def parse_expected_task_items(profile_name: str, scenario: str, raw: Any) -> list[dict[str, str]] | None:
    """Validate the `expected_task_items` expectation shape up front so a typo
    fails the run before the agent is driven:
    [{"title": str, "status": str}, ...]."""
    if raw is None:
        return None
    prefix = f"{profile_name} scenario {scenario!r}: expected_task_items"
    if not isinstance(raw, list) or not raw:
        raise ValueError(f"{prefix} must be a non-empty list, got {raw!r}")
    items: list[dict[str, str]] = []
    for entry in raw:
        if (
            not isinstance(entry, dict)
            or not isinstance(entry.get("title"), str)
            or not entry["title"].strip()
            or not isinstance(entry.get("status"), str)
            or not entry["status"].strip()
        ):
            raise ValueError(
                f"{prefix} entries must be objects with non-empty string "
                f"'title' and 'status', got {entry!r}"
            )
        items.append({"title": entry["title"].strip(), "status": entry["status"].strip()})
    return items


def parse_environment_by_scenario(profile_name: str, raw: Any) -> dict[str, dict[str, str]]:
    """Validate a profile's `environment_by_scenario` at load time:
    {"<scenario>": {"VAR": "value"}}."""
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise ValueError(f"{profile_name}: environment_by_scenario must be an object, got {raw!r}")
    parsed: dict[str, dict[str, str]] = {}
    for scenario, value in raw.items():
        if not isinstance(scenario, str) or not isinstance(value, dict) or not all(
            isinstance(key, str) and key.strip() and isinstance(item, str)
            for key, item in value.items()
        ):
            raise ValueError(
                f"{profile_name}: environment_by_scenario entries must map a scenario name "
                f"to an object of string values, got {scenario!r}: {value!r}"
            )
        parsed[scenario] = dict(value)
    return parsed


def load_profiles(path: pathlib.Path) -> dict[str, AgentProfile]:
    profiles: dict[str, AgentProfile] = {}
    for profile_path in sorted(path.glob("*.json")):
        raw = json.loads(profile_path.read_text(encoding="utf-8"))
        expectations: dict[str, ScenarioExpectation] = {}
        for name, value in raw.get("expectations", {}).items():
            session_identity_raw = value.get("session_identity")
            session_identity = None
            if isinstance(session_identity_raw, dict):
                session_id_pattern = session_identity_raw.get("session_id_pattern")
                if isinstance(session_id_pattern, str) and session_id_pattern.strip():
                    session_identity = SessionIdentityExpectation(
                        session_id_pattern=session_id_pattern.strip(),
                        tracked_pid=bool(session_identity_raw.get("tracked_pid", True)),
                    )
            expectations[name] = ScenarioExpectation(
                name=name,
                required_events=list(value.get("required_events", [])),
                forbidden_events=list(value.get("forbidden_events", [])),
                required_terminal_phases=list(value.get("required_terminal_phases", [])),
                forbidden_terminal_phases=list(value.get("forbidden_terminal_phases", [])),
                expected_task_progress=value.get("expected_task_progress")
                if isinstance(value.get("expected_task_progress"), dict)
                else None,
                expected_task_items=parse_expected_task_items(
                    profile_path.name,
                    name,
                    value.get("expected_task_items"),
                ),
                required_bootstrap_arguments=[
                    [str(argument) for argument in arguments]
                    for arguments in value.get("required_bootstrap_arguments", [])
                ],
                session_identity=session_identity,
                synthetic=bool(value.get("synthetic", False)),
                fixture=value.get("fixture"),
                post_stop_notification_required=bool(value.get("post_stop_notification_required", False)),
                subagent_payload_required=bool(value.get("subagent_payload_required", False)),
                subagent_model_required=bool(value.get("subagent_model_required", True)),
                event_order=parse_event_order(profile_path.name, name, value.get("event_order")),
                subagent_nested_required=bool(value.get("subagent_nested_required", False)),
                resume_roundtrip=bool(value.get("resume_roundtrip", False)),
                daemon_pane_routing=bool(value.get("daemon_pane_routing", False)),
            )
        profile = AgentProfile(
            name=raw["name"],
            command=raw["command"],
            real_binary_names=list(raw.get("real_binary_names", [raw["command"]])),
            version_args=list(raw.get("version_args", ["--version"])),
            launch_args_by_scenario={name: list(args) for name, args in raw.get("launch_args_by_scenario", {}).items()},
            expectations=expectations,
            input_by_scenario={name: list(values) for name, values in raw.get("input_by_scenario", {}).items()},
            environment_by_scenario=parse_environment_by_scenario(profile_path.name, raw.get("environment_by_scenario")),
            repeat_by_scenario={name: int(count) for name, count in raw.get("repeat_by_scenario", {}).items()},
            skip_patterns=list(raw.get("skip_patterns", [])),
            tool=str(raw.get("tool") or raw["name"]),
            kimi_variant=raw.get("kimi_variant") if raw.get("kimi_variant") in ("legacy", "modern") else None,
        )
        profiles[profile.name] = profile
    return profiles


def manifest_dirs_from_environment(environment: dict[str, Any]) -> list[pathlib.Path]:
    raw = str(environment.get("ZENTTY_AGENT_MANIFEST_DIRS") or "").strip()
    if not raw:
        return []
    return [pathlib.Path(entry) for entry in raw.split(os.pathsep) if entry.strip()]


def load_agent_manifests(
    resources_dir: pathlib.Path | None,
    manifest_dirs: list[pathlib.Path] | tuple[pathlib.Path, ...] = (),
) -> dict[str, dict[str, Any]]:
    """Load agent manifests the way AgentManifestRegistry does: bundled
    `<resources>/agents/*.json` first, then each `ZENTTY_AGENT_MANIFEST_DIRS`
    entry — later sources win by id. Malformed files are skipped, mirroring
    the Swift log-and-continue behaviour. The bench intentionally does not
    read `~/.config/zentty/agents` so runs stay hermetic."""
    manifests: dict[str, dict[str, Any]] = {}
    roots: list[pathlib.Path] = []
    if resources_dir:
        roots.append(pathlib.Path(resources_dir) / "agents")
    roots.extend(manifest_dirs)
    for root in roots:
        if not root.is_dir():
            continue
        for path in sorted(root.glob("*.json")):
            try:
                raw = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            manifest_id = raw.get("id") if isinstance(raw, dict) else None
            if isinstance(manifest_id, str) and manifest_id:
                manifests[manifest_id] = raw
    return manifests


def manifest_wrapper_script(tool_id: str, binaries: list[str], support_dir: str) -> str:
    """Byte-for-byte mirror of the script written by
    AgentManifestWrapperMaterializer.wrapperScript — a test pins the two
    templates together."""
    return (
        "#!/usr/bin/env bash\n"
        f'export ZENTTY_AGENT_TOOL="{tool_id}"\n'
        f'export ZENTTY_AGENT_REAL_BINARIES="{":".join(str(binary) for binary in binaries)}"\n'
        'export ZENTTY_AGENT_WRAPPER_DIR="$(cd "$(dirname "$0")" && pwd)"\n'
        f'exec "${{ZENTTY_WRAPPER_SUPPORT_DIR:-{support_dir}}}/zentty-agent-wrapper" "$@"\n'
    )


def materialize_manifest_wrappers(
    manifests: dict[str, dict[str, Any]],
    root: pathlib.Path,
    shared_wrapper_path: pathlib.Path,
) -> dict[str, pathlib.Path]:
    """Mirror AgentManifestWrapperMaterializer: one thin wrapper per manifest
    binary under `<root>/<id>/<binary>`. The bench owns the run-dir root, so
    wrappers live next to the captured traces instead of the app runtime dir."""
    support_dir = str(shared_wrapper_path.parent)
    directories: dict[str, pathlib.Path] = {}
    for manifest in manifests.values():
        tool_id = manifest.get("id")
        binaries = manifest.get("binaries")
        if not isinstance(tool_id, str) or not isinstance(binaries, list) or not binaries:
            continue
        directory = root / tool_id
        directory.mkdir(parents=True, exist_ok=True)
        for binary in binaries:
            script_path = directory / str(binary)
            script_path.write_text(
                manifest_wrapper_script(tool_id, [str(binary) for binary in binaries], support_dir),
                encoding="utf-8",
            )
            script_path.chmod(0o755)
        directories[tool_id] = directory
    return directories


DAEMON_STARTER_PANE_ID = "agent-bench-daemon-starter-pane"
DAEMON_STARTER_WORKLANE_ID = "agent-bench-daemon-starter-worklane"
# Not a live process: the hook CLI must drop it instead of tracking it.
DAEMON_STARTER_CLAUDE_PID = "999999"
DAEMON_STARTER_PROMPT = "Reply with exactly: ZENTTY_AGENT_BENCH_DAEMON_STARTED"
CLAUDE_DAEMON_PROCESS_PATTERN = re.compile(r"(?:^|/)claude (?:daemon run|bg-pty-host|bg-spare)(?:\s|$)")
BACKGROUNDED_SESSION_PATTERN = re.compile(r"backgrounded\s+\S\s+([0-9a-f]{8})\b")


def parse_claude_daemon_pids(ps_output: str) -> set[int]:
    pids: set[int] = set()
    for line in ps_output.splitlines():
        pid, _, command = line.strip().partition(" ")
        if pid.isdigit() and CLAUDE_DAEMON_PROCESS_PATTERN.search(command.strip()):
            pids.add(int(pid))
    return pids


def claude_daemon_pids() -> set[int]:
    result = subprocess.run(["ps", "-axo", "pid=,command="], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    return parse_claude_daemon_pids(result.stdout)


def stop_claude_daemon_processes(excluding: set[int], grace: float = 10.0) -> None:
    # A transient daemon exits on its own once its last session stops, but it
    # can leave pre-warmed spare hosts behind. Only processes that appeared
    # during the scenario are signalled.
    for signal_number in (None, signal.SIGTERM, signal.SIGKILL):
        for pid in claude_daemon_pids() - excluding if signal_number else ():
            try:
                os.kill(pid, signal_number)
            except OSError:
                pass
        deadline = time.time() + grace
        while time.time() < deadline and claude_daemon_pids() - excluding:
            time.sleep(0.5)


def backgrounded_session_ids(output: str) -> list[str]:
    return BACKGROUNDED_SESSION_PATTERN.findall(ANSI_ESCAPE_PATTERN.sub("", output))


def daemon_routing_violations(
    records: list[TraceRecord],
    expected_pane: str,
    expected_worklane: str,
    starter_claude_pid: str,
) -> list[str]:
    violations: list[str] = []
    hooks = [record for record in records if record.kind == "hook"]
    if not hooks:
        return ["no hook events captured"]
    for record in hooks:
        environment = record.environment or {}
        label = record.event_name or "hook"
        pane = environment.get("ZENTTY_PANE_ID")
        worklane = environment.get("ZENTTY_WORKLANE_ID")
        if pane != expected_pane:
            violations.append(f"{label} routed to pane {pane!r}, expected {expected_pane!r}")
        elif worklane != expected_worklane:
            violations.append(f"{label} routed to worklane {worklane!r}, expected {expected_worklane!r}")
        elif environment.get("ZENTTY_CLAUDE_PID") == starter_claude_pid:
            violations.append(f"{label} kept the daemon starter's ZENTTY_CLAUDE_PID")
    return violations


def missing_manifest_wrapper(wrapper_dir: pathlib.Path | None, profile: AgentProfile) -> str | None:
    if wrapper_dir is None or not wrapper_dir.is_dir():
        return f"no materialized wrapper directory for manifest agent {profile.tool}"
    candidate_names = list(dict.fromkeys([profile.command] + profile.real_binary_names))
    candidates = [wrapper_dir / name for name in candidate_names]
    if not any(path.exists() for path in candidates):
        names = ", ".join(path.name for path in candidates)
        return f"materialized wrapper dir {wrapper_dir} is missing a wrapper executable: expected one of {names}"
    if not any(os.access(path, os.X_OK) for path in candidates):
        names = ", ".join(path.name for path in candidates)
        return f"materialized wrapper dir {wrapper_dir} has non-executable wrapper: expected one of {names}"
    return None


class BenchRunner:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.profiles = load_profiles(BENCH_ROOT / "profiles")
        self.run_dir = pathlib.Path(args.run_dir) if args.run_dir else DEFAULT_RUNS_DIR / time.strftime("%Y%m%d-%H%M%S")
        self.run_dir.mkdir(parents=True, exist_ok=True)
        self.socket_dir = pathlib.Path(tempfile.mkdtemp(prefix="zab-", dir="/tmp"))
        self.recorder = TraceRecorder(self.run_dir)
        self.manifests: dict[str, dict[str, Any]] = {}
        self.manifest_wrapper_dirs: dict[str, pathlib.Path] = {}

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
                    manifests=self.manifests,
                )
                server.start()
                try:
                    scenario_env = dict(env)
                    scenario_env["ZENTTY_INSTANCE_SOCKET"] = str(server.socket_path)
                    # The agent wrapper (`AgentToolLauncher.shouldAttemptBootstrap`)
                    # only routes through our bootstrap planner when these three
                    # routing keys are present. Without them it bypasses bootstrap
                    # and exec's the real agent binary against the real HOME, so
                    # `_plan_*` overlay setup becomes dead code. Setting static
                    # values is fine — they're routing identifiers, not secrets.
                    scenario_env["ZENTTY_PANE_TOKEN"] = "agent-bench-pane-token"
                    scenario_env["ZENTTY_WORKLANE_ID"] = "agent-bench-worklane"
                    scenario_env["ZENTTY_PANE_ID"] = "agent-bench-pane"
                    for agent in agents:
                        server.current_agent = agent
                        try:
                            results.append(self._run_agent_scenario(agent, scenario, scenario_env))
                        finally:
                            server.current_agent = None
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
        env = dict(env)
        profile = self.profiles[agent]
        env.update(profile.environment_by_scenario.get(scenario, {}))
        if scenario not in profile.expectations:
            return self._finalize_result(
                ScenarioResult(agent, scenario, True, [], [], status="skip", detail="scenario not defined", result_kind="scenario-skip"),
                [],
                [],
            )
        if profile.expectations[scenario].synthetic:
            return self._run_synthetic_scenario(agent, scenario, env)
        if profile.expectations[scenario].resume_roundtrip:
            return self._run_resume_roundtrip_scenario(agent, scenario, env)
        if profile.expectations[scenario].daemon_pane_routing:
            return self._run_daemon_pane_routing_scenario(agent, scenario, env)
        if profile.tool in self.manifests:
            missing = missing_manifest_wrapper(self.manifest_wrapper_dirs.get(profile.tool), profile)
        else:
            missing = missing_agent_wrapper_resource(self._resolved_app_path, profile)
        if missing:
            return self._finalize_result(
                self._skip_or_fail(agent, scenario, missing, "missing-wrapper"),
                [],
                [],
            )
        if profile.tool == "kimi" and profile.kimi_variant in ("legacy", "modern"):
            names = list(dict.fromkeys([profile.command] + profile.real_binary_names))
            wrapper_candidates = all_which_candidates(names, env["PATH"])
            command = wrapper_candidates[0] if wrapper_candidates else None
            if not command:
                return self._finalize_result(self._skip_or_fail(agent, scenario, f"none of {', '.join(names)} found", "binary-skip"), [], [])
            real_command, real_skip_message = resolve_agent_binary(profile, filtered_inherited_path(env["PATH"]))
            if not real_command:
                return self._finalize_result(self._skip_or_fail(agent, scenario, real_skip_message or "kimi binary not found", "binary-skip"), [], [])
            env["PATH"] = prioritize_path_entry_after_zentty_resources(env["PATH"], str(pathlib.Path(real_command).parent))
            env["ZENTTY_KIMI_VARIANT"] = profile.kimi_variant
            env["ZENTTY_REAL_BINARY"] = real_command
        else:
            command, skip_message = resolve_agent_binary(profile, env["PATH"])
            if not command:
                return self._finalize_result(self._skip_or_fail(agent, scenario, skip_message or "binary not found", "binary-skip"), [], [])
        version = run_version(command, profile.version_args, env)
        self.recorder.append(TraceRecord(kind="version", agent=agent, scenario=scenario, extra={"version": version}))
        argv = [command] + profile.launch_args_by_scenario.get(scenario, [])
        transcript_path = self.run_dir / f"{agent}-{scenario}.terminal.log"
        expectation = profile.expectations[scenario]
        observations: list[TerminalObservation] = []
        output_parts: list[str] = []
        completed = PtyResult(0, False, "", terminal_observations=[])
        repeat_count = max(1, profile.repeat_by_scenario.get(scenario, 1))
        repo = self._make_repo(agent, scenario)
        if profile.tool == "claude":
            try:
                if ensure_claude_workspace_trust(repo):
                    self.recorder.append(
                        TraceRecord(kind="note", agent=agent, scenario=scenario, extra={"claude_workspace_trust": str(repo)})
                    )
            except OSError as error:
                self.recorder.append(
                    TraceRecord(kind="note", agent=agent, scenario=scenario, extra={"claude_workspace_trust_error": str(error)})
                )
        for iteration in range(repeat_count):
            iteration_transcript_path = transcript_path if repeat_count == 1 else self.run_dir / f"{agent}-{scenario}-{iteration + 1}.terminal.log"
            completed = run_pty(
                argv,
                env=env,
                cwd=repo,
                inputs=profile.input_by_scenario.get(scenario, []),
                timeout=self.args.timeout,
                transcript_path=iteration_transcript_path,
                completion_predicate=lambda _output, current_observations: (
                    not validate_scenario(agent, expectation, self.recorder.records(), agent_tool=profile.tool).missing_events
                    and not missing_required_terminal_phases(expectation, observations + current_observations)
                    and (
                        not scenario_requires_terminal_needs_input(scenario)
                        or terminal_needs_input_observed(observations + current_observations)
                    )
                    and (
                        not scenario_requires_scripted_input(agent, scenario)
                        or scripted_input_observed(agent, scenario, observations + current_observations)
                    )
                    and not terminal_needs_input_persisted_after_scripted_input(agent, scenario, observations + current_observations)
                ),
            )
            observations.extend(completed.terminal_observations)
            output_parts.append(completed.output)
            if completed.timed_out:
                break
            if completed.exit_code != 0 and not completed.completed_by_predicate:
                break
        completed.output = "\n".join(output_parts)
        if completed.timed_out:
            result = classify_timeout_result(
                agent=agent,
                scenario=scenario,
                expectation=expectation,
                records=self.recorder.records(),
                terminal_observations=observations,
                output=completed.output,
                skip_patterns=profile.skip_patterns,
                timeout=self.args.timeout,
                strict=self.args.strict,
                agent_tool=profile.tool,
            )
            return self._finalize_result(result, self.recorder.records(), observations)
        result = classify_completed_result(
            agent=agent,
            scenario=scenario,
            expectation=expectation,
            records=self.recorder.records(),
            terminal_observations=observations,
            output=completed.output,
            skip_patterns=profile.skip_patterns,
            exit_code=completed.exit_code,
            completed_by_predicate=completed.completed_by_predicate,
            strict=self.args.strict,
            agent_tool=profile.tool,
        )
        return self._finalize_result(result, self.recorder.records(), observations)

    def _run_daemon_pane_routing_scenario(self, agent: str, scenario: str, env: dict[str, str]) -> ScenarioResult:
        # Regression guard for dedene/zentty#121. Claude runs background
        # sessions under one per-user daemon that keeps the environment of
        # whichever pane started it. Phase 1 starts that daemon with the real
        # binary under a foreign pane identity. Phase 2 launches `claude --bg`
        # through the wrapper as the bench pane. Every hook the capture server
        # then sees must carry the bench pane, not the daemon's.
        env = dict(env)
        profile = self.profiles[agent]
        expectation = profile.expectations[scenario]
        if profile.tool != "claude":
            return self._finalize_result(
                self._skip_or_fail(agent, scenario, "daemon_pane_routing is only defined for claude", "scenario-skip"), [], []
            )
        if missing := missing_agent_wrapper_resource(self._resolved_app_path, profile):
            return self._finalize_result(self._skip_or_fail(agent, scenario, missing, "missing-wrapper"), [], [])
        command, skip_message = resolve_agent_binary(profile, env["PATH"])
        real_command, real_skip_message = resolve_agent_binary(profile, filtered_inherited_path(env["PATH"]))
        if not command or not real_command:
            detail = skip_message or real_skip_message or "claude binary not found"
            return self._finalize_result(self._skip_or_fail(agent, scenario, detail, "binary-skip"), [], [])
        preexisting = claude_daemon_pids()
        if preexisting:
            detail = "a Claude background daemon or session is already running; refusing to share or stop it"
            return self._finalize_result(self._skip_or_fail(agent, scenario, detail, "scenario-skip"), [], [])

        version = run_version(command, profile.version_args, env)
        self.recorder.append(TraceRecord(kind="version", agent=agent, scenario=scenario, extra={"version": version}))
        repo = self._make_repo(agent, scenario)
        try:
            ensure_claude_workspace_trust(repo)
        except OSError as error:
            self.recorder.append(
                TraceRecord(kind="note", agent=agent, scenario=scenario, extra={"claude_workspace_trust_error": str(error)})
            )

        starter_env = dict(env)
        starter_env["ZENTTY_PANE_ID"] = DAEMON_STARTER_PANE_ID
        starter_env["ZENTTY_WORKLANE_ID"] = DAEMON_STARTER_WORKLANE_ID
        starter_env["ZENTTY_PANE_TOKEN"] = "agent-bench-daemon-starter-token"
        starter_env["ZENTTY_CLAUDE_PID"] = DAEMON_STARTER_CLAUDE_PID
        session_ids: list[str] = []
        observations: list[TerminalObservation] = []
        try:
            starter = run_pty(
                [real_command, "--setting-sources", "project,local", "--bg", DAEMON_STARTER_PROMPT],
                env=starter_env,
                cwd=repo,
                inputs=[],
                timeout=self.args.timeout,
                transcript_path=self.run_dir / f"{agent}-{scenario}-daemon-starter.terminal.log",
            )
            session_ids.extend(backgrounded_session_ids(starter.output))
            if starter.timed_out or not session_ids:
                skip = matches_any(starter.output, profile.skip_patterns)
                detail = "could not start the Claude daemon with `claude --bg`"
                kind = "auth-skip" if skip else "process-timeout" if starter.timed_out else "scenario-skip"
                return self._finalize_result(self._skip_or_fail(agent, scenario, detail, kind), [], [])

            launched = run_pty(
                [command] + profile.launch_args_by_scenario.get(scenario, []),
                env=env,
                cwd=repo,
                inputs=[],
                timeout=self.args.timeout,
                transcript_path=self.run_dir / f"{agent}-{scenario}.terminal.log",
            )
            observations.extend(launched.terminal_observations)
            session_ids.extend(backgrounded_session_ids(launched.output))
            deadline = time.time() + self.args.timeout
            while time.time() < deadline:
                if not validate_scenario(agent, expectation, self.recorder.records(), agent_tool=profile.tool).missing_events:
                    break
                time.sleep(0.5)
        finally:
            for session_id in session_ids:
                subprocess.run(
                    [real_command, "stop", session_id],
                    env=starter_env,
                    cwd=repo,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=30,
                    check=False,
                )
            stop_claude_daemon_processes(excluding=preexisting)

        records = [record for record in self.recorder.records() if record.agent == agent and record.scenario == scenario]
        result = validate_scenario(agent, expectation, records, agent_tool=profile.tool)
        if result.passed:
            violations = daemon_routing_violations(
                records,
                expected_pane=env["ZENTTY_PANE_ID"],
                expected_worklane=env["ZENTTY_WORKLANE_ID"],
                starter_claude_pid=DAEMON_STARTER_CLAUDE_PID,
            )
            if violations:
                result.passed = False
                result.status = "fail"
                result.result_kind = "wrong-pane-routing"
                result.detail = "; ".join(violations[:3])
        return self._finalize_result(result, records, observations)

    def _run_synthetic_scenario(self, agent: str, scenario: str, env: dict[str, str]) -> ScenarioResult:
        # Synthetic scenarios bypass the agent binary entirely. They pipe a
        # JSONL fixture of hook events directly into the bench capture
        # server (using the same IPC framing the Zentty CLI would). This
        # lets us reproduce hook-ordering bugs (like Stop → late
        # Notification) deterministically without depending on the model.
        profile = self.profiles[agent]
        expectation = profile.expectations[scenario]
        if not expectation.fixture:
            return self._finalize_result(
                self._skip_or_fail(agent, scenario, "synthetic scenario missing 'fixture'", "scenario-skip"),
                [],
                [],
            )
        fixture_path = BENCH_ROOT / "fixtures" / expectation.fixture
        if not fixture_path.is_file():
            return self._finalize_result(
                self._skip_or_fail(agent, scenario, f"fixture not found: {fixture_path}", "scenario-skip"),
                [],
                [],
            )
        socket_path_str = env.get("ZENTTY_INSTANCE_SOCKET")
        if not socket_path_str:
            return self._finalize_result(
                self._skip_or_fail(agent, scenario, "ZENTTY_INSTANCE_SOCKET not set", "scenario-skip"),
                [],
                [],
            )
        socket_path = pathlib.Path(socket_path_str)
        request_environment = {
            key: env[key]
            for key in (
                "ZENTTY_WINDOW_ID",
                "ZENTTY_WORKLANE_ID",
                "ZENTTY_PANE_ID",
                "ZENTTY_PANE_TOKEN",
                "ZENTTY_INSTANCE_ID",
                "ZENTTY_CLAUDE_PID",
            )
            if env.get(key)
        }
        for index, raw_line in enumerate(fixture_path.read_text(encoding="utf-8").splitlines()):
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            request = {
                "version": 1,
                "id": f"synthetic-{scenario}-{index}",
                "kind": "ipc",
                "subcommand": "agent-event",
                "arguments": [f"--adapter={agent}"],
                "standardInput": line,
                "environment": request_environment,
                # Wait for server ack so the trace record is appended before
                # we read records() below; otherwise validation can race the
                # capture server's worker thread.
                "expectsResponse": True,
                "tool": agent,
            }
            send_ipc(socket_path, request)
        records = self.recorder.records()
        scenario_records = [
            record for record in records if record.agent == agent and record.scenario == scenario
        ]
        result = validate_scenario(agent, expectation, scenario_records, agent_tool=profile.tool)
        if (
            result.passed
            and expectation.post_stop_notification_required
            and not _trace_contains_post_stop_notification(scenario_records)
        ):
            result.passed = False
            result.status = "fail"
            result.detail = "expected a Notification arriving after Stop in the same session, none captured"
            result.result_kind = "missing-hook"
        return self._finalize_result(result, scenario_records, [])

    def _resolve_kimi_commands(
        self, profile: AgentProfile, env: dict[str, str]
    ) -> tuple[str | None, str | None, str | None]:
        """Resolve (wrapper_command, real_binary, skip_reason) for a kimi profile
        — the same resolution `_run_agent_scenario` uses for the kimi branch."""
        names = list(dict.fromkeys([profile.command] + profile.real_binary_names))
        wrapper_candidates = all_which_candidates(names, env["PATH"])
        command = wrapper_candidates[0] if wrapper_candidates else None
        if not command:
            return None, None, f"none of {', '.join(names)} found"
        real_command, real_skip_message = resolve_agent_binary(profile, filtered_inherited_path(env["PATH"]))
        if not real_command:
            return None, None, real_skip_message or "kimi binary not found"
        return command, real_command, None

    def _run_resume_roundtrip_scenario(self, agent: str, scenario: str, env: dict[str, str]) -> ScenarioResult:
        # True end-to-end resume proof for modern kimi-code. Phase 1 creates a
        # real session through the wrapper bootstrap against a BENCH-OWNED home
        # (KIMI_CODE_HOME under the run dir, auth symlinked from the operator's
        # ~/.kimi-code). Phase 2 is a fresh wrapper invocation (a new bootstrap —
        # the harness idiom for an app restart) that resumes the captured session
        # id and must echo the marker. A "not found" resume fails loudly: that is
        # the exact regression the overlay bug produced.
        env = dict(env)
        profile = self.profiles[agent]
        if not (profile.tool == "kimi" and profile.kimi_variant == "modern"):
            return self._finalize_result(
                self._skip_or_fail(agent, scenario, "resume_roundtrip is only defined for modern kimi-code", "scenario-skip"),
                [],
                [],
            )
        if missing := missing_agent_wrapper_resource(self._resolved_app_path, profile):
            return self._finalize_result(self._skip_or_fail(agent, scenario, missing, "missing-wrapper"), [], [])

        command, real_command, skip_reason = self._resolve_kimi_commands(profile, env)
        if not command or not real_command:
            return self._finalize_result(self._skip_or_fail(agent, scenario, skip_reason or "kimi binary not found", "binary-skip"), [], [])
        env["PATH"] = prioritize_path_entry_after_zentty_resources(env["PATH"], str(pathlib.Path(real_command).parent))
        env["ZENTTY_KIMI_VARIANT"] = "modern"
        env["ZENTTY_REAL_BINARY"] = real_command

        # Bench-owned home + auth seed. Operator home is overridable for tests.
        bench_home = self.run_dir / f"{agent}-{scenario}-kimi-home"
        operator_home = pathlib.Path(
            env.get("ZENTTY_BENCH_KIMI_SOURCE_HOME") or os.path.expanduser("~/.kimi-code")
        )
        if not seed_kimi_bench_home(bench_home, operator_home):
            return self._finalize_result(
                self._skip_or_fail(agent, scenario, "kimi auth not available to seed bench home", "auth-skip"),
                [],
                [],
            )
        env["KIMI_CODE_HOME"] = str(bench_home)

        # Phase 1 — create a real session. Phase 2 MUST reuse this workdir:
        # kimi pins sessions to the directory they were created under and
        # refuses to resume them from anywhere else.
        repo = self._make_repo(agent, f"{scenario}-phase1")
        phase1_args = profile.launch_args_by_scenario.get(scenario, [])
        completed1 = run_pty(
            [command] + phase1_args,
            env=env,
            cwd=repo,
            inputs=[],
            timeout=self.args.timeout,
            transcript_path=self.run_dir / f"{agent}-{scenario}-phase1.terminal.log",
        )
        if matches_any(completed1.output, profile.skip_patterns):
            return self._finalize_result(
                self._skip_or_fail(agent, scenario, "phase 1 hit an auth/login skip pattern", "auth-skip"),
                self.recorder.records(),
                [],
            )
        session_id = latest_kimi_session_id(bench_home)
        if not session_id:
            result = ScenarioResult(
                agent, scenario, False, ["session_index.jsonl entry"], [],
                status="fail", detail="phase 1 did not record a session id in session_index.jsonl",
                result_kind="resume-no-session",
            )
            return self._finalize_result(result, self.recorder.records(), [])

        # Phase 2 — fresh bootstrap (new process) resumes by id.
        # Modern kimi-code has no --print; -p/--prompt alone runs non-interactively.
        phase2_args = ["-S", session_id, "--prompt", RESUME_ROUNDTRIP_PROMPT]
        completed2 = run_pty(
            [command] + phase2_args,
            env=env,
            cwd=repo,
            inputs=[],
            timeout=self.args.timeout,
            transcript_path=self.run_dir / f"{agent}-{scenario}-phase2.terminal.log",
        )

        if resume_not_found_in_output(completed2.output):
            result = ScenarioResult(
                agent, scenario, False, [], [],
                status="fail",
                detail=f"resume of {session_id} reported the session as not found — the overlay regression",
                result_kind="resume-not-found",
            )
            return self._finalize_result(result, self.recorder.records(), [])
        if not resume_sentinel_in_output(completed2.output):
            result = ScenarioResult(
                agent, scenario, False, [RESUME_ROUNDTRIP_SENTINEL], [],
                status="fail",
                detail=f"resume of {session_id} did not recall the sentinel {RESUME_ROUNDTRIP_SENTINEL}",
                result_kind="resume-no-marker",
            )
            return self._finalize_result(result, self.recorder.records(), [])

        # Hook events are a soft signal here (SessionStart at minimum): the hard
        # assertion is that the conversation reopened. Surface any gap as a
        # warning rather than failing the regression on hook timing.
        expectation = profile.expectations[scenario]
        warnings: list[str] = []
        if expectation.required_events:
            validation = validate_scenario(agent, expectation, self.recorder.records(), agent_tool=profile.tool)
            if validation.missing_events:
                warnings.append("resume hooks missing: " + ", ".join(validation.missing_events))
        result = ScenarioResult(
            agent, scenario, True, [], [f"resumed:{session_id}"],
            status="pass",
            detail=f"created and resumed {session_id}; phase 2 recalled {RESUME_ROUNDTRIP_SENTINEL}",
            result_kind="resume-pass",
            warnings=warnings,
        )
        return self._finalize_result(result, self.recorder.records(), [])

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
        result.terminal_final_phase = terminal_final_phase(observations)
        result.terminal_post_scripted_input_phase = terminal_phase_after_scripted_input(result.agent, result.scenario, observations)
        result.terminal_phase_sequence = terminal_phase_sequence(observations)
        result.terminal_observations = [dataclasses.asdict(observation) for observation in observations]
        result.task_observations = task_observations_for_records(result.agent, result.scenario, records)
        result.task_item_observations = [
            {
                "event": item.get("event"),
                "tool": item.get("raw_tool_name") or item.get("tool"),
                "items": item["items"],
            }
            for item in result.task_observations
            if isinstance(item.get("items"), list) and item["items"]
        ]
        result.subagent_observations = subagent_observations_for_records(result.agent, result.scenario, records)
        result.timeline = build_timeline(result.agent, result.scenario, records, observations)
        result.rerun_command = self._rerun_command(result.agent, result.scenario)
        if observations and not any(warning.startswith("terminal observations") for warning in result.warnings):
            result.warnings.append(f"terminal observations captured: {len(observations)}")
        if result.terminal_post_scripted_input_phase == "needs-input" and not any(
            warning.startswith("terminal post-scripted-input phase") for warning in result.warnings
        ):
            result.warnings.append("terminal post-scripted-input phase: needs-input")
        if result.task_observations and not any(warning.startswith("task observations") for warning in result.warnings):
            result.warnings.append(f"task observations captured: {len(result.task_observations)}")
        if result.subagent_observations and not any(warning.startswith("subagent observations") for warning in result.warnings):
            models = sorted({str(item.get("model")) for item in result.subagent_observations if item.get("model")})
            result.warnings.append(
                f"subagent observations captured: {len(result.subagent_observations)}"
                + (f" (models: {', '.join(models)})" if models else "")
            )
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
            if app_has_agent_bench_resources(candidate):
                return candidate
            # Prefer this repo's DerivedData app: the global latest-mtime
            # fallback can pick a different worktree's (stale) build.
            derived_data_candidate = repo_derived_data_app() or latest_derived_data_zentty_app()
            if derived_data_candidate is not None:
                return derived_data_candidate
            if candidate.exists():
                raise SystemExit(
                    "--no-build found build/Debug/Zentty.app, but it is missing agent bench resources. "
                    "Pass --app-path to a fresh build product or run without --no-build."
                )
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
        # Manifest agents have no bundled wrapper; materialize the same thin
        # scripts the app's AgentManifestWrapperMaterializer writes, under the
        # run dir. Manifest sources mirror AgentManifestRegistry: bundled
        # agents/ plus ZENTTY_AGENT_MANIFEST_DIRS (which the bench seeds with
        # the in-repo fixtures so `zentty launch <manifest-id>` resolves).
        manifest_dirs = manifest_dirs_from_environment(env)
        fixture_agents = BENCH_ROOT / "fixtures" / "generic-canonical" / "agents"
        if fixture_agents.is_dir():
            manifest_dirs.append(fixture_agents)
        if manifest_dirs:
            env["ZENTTY_AGENT_MANIFEST_DIRS"] = os.pathsep.join(str(path) for path in manifest_dirs)
        self.manifests = load_agent_manifests(resources_dir, manifest_dirs)
        self.manifest_wrapper_dirs = materialize_manifest_wrappers(
            self.manifests,
            self.run_dir / "agent-wrappers",
            shared / "zentty-agent-wrapper",
        )
        wrapper_dirs += [
            self.manifest_wrapper_dirs[agent]
            for agent in SUPPORTED_AGENTS
            if agent in self.manifest_wrapper_dirs
        ]
        # Fixture binaries sit between the wrapper dirs and the inherited PATH:
        # `which <binary>` resolves the wrapper while the launcher's real-binary
        # lookup (which skips wrapper dirs) finds the fixture script.
        fixture_bins = [BENCH_ROOT / "fixtures" / agent / "bin" for agent in SUPPORTED_AGENTS]
        fixture_bins = [path for path in fixture_bins if path.is_dir()]
        inherited_path = filtered_inherited_path(env.get("PATH", ""))
        env["PATH"] = os.pathsep.join(
            [*(str(path) for path in wrapper_dirs), str(shared), *(str(path) for path in fixture_bins), inherited_path]
        )
        env["ZENTTY_CLI_BIN"] = str(shared / "zentty")
        env["ZENTTY_WRAPPER_SUPPORT_DIR"] = str(shared)
        env["ZENTTY_ALL_WRAPPER_BIN_DIRS"] = os.pathsep.join(str(path) for path in wrapper_dirs)
        env["ZENTTY_WRAPPER_BIN_DIRS"] = env["ZENTTY_ALL_WRAPPER_BIN_DIRS"]
        env["ZENTTY_WINDOW_ID"] = "bench-window"
        env["ZENTTY_WORKLANE_ID"] = "bench-worklane"
        env["ZENTTY_PANE_ID"] = "bench-pane"
        env["ZENTTY_PANE_TOKEN"] = "bench-pane-token"
        env["ZENTTY_INSTANCE_ID"] = "agent-bench"
        if is_zentty_launch_cache_path(str(env.get("CODEX_HOME") or "")):
            env.pop("CODEX_HOME", None)
        return env

    def _write_report(self, results: list[ScenarioResult]) -> None:
        summary = [dataclasses.asdict(result) for result in results]
        write_json(self.run_dir / "summary.json", summary)
        app_path = str(getattr(self, "_resolved_app_path", "") or "")
        write_json(
            self.run_dir / "metadata.json",
            {
                "app_path": app_path,
                "strict": bool(self.args.strict),
                "no_build": bool(self.args.no_build),
            },
        )
        timeline = [
            {"agent": result.agent, "scenario": result.scenario, **entry}
            for result in results
            for entry in result.timeline
        ]
        write_json(self.run_dir / "timeline.json", timeline)
        lines = ["# Agent Bench Report", ""]
        if app_path:
            lines.extend([f"App: `{app_path}`", ""])
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
            if result.terminal_final_phase:
                lines.append(f"  Terminal final phase: {result.terminal_final_phase}")
            if result.terminal_phase_sequence:
                lines.append(f"  Terminal phases: {' -> '.join(result.terminal_phase_sequence)}")
            if result.terminal_post_scripted_input_phase:
                lines.append(f"  Terminal post-scripted-input phase: {result.terminal_post_scripted_input_phase}")
            if result.terminal_observations:
                observations = ", ".join(f"{item['kind']}={item['text']}" for item in result.terminal_observations[:3])
                suffix = "..." if len(result.terminal_observations) > 3 else ""
                lines.append(f"  Terminal: {observations}{suffix}")
            if result.task_observations:
                tasks = ", ".join(
                    f"{item.get('event', '?')}:{item.get('done', '-')}/{item.get('total', '-')}"
                    for item in result.task_observations[:3]
                )
                suffix = "..." if len(result.task_observations) > 3 else ""
                lines.append(f"  Tasks: {tasks}{suffix}")
            if result.scenario == "tasks":
                tools = sorted(
                    {
                        str(item.get("raw_tool_name") or item.get("tool") or "?")
                        for item in result.task_observations
                    }
                )
                item_events: list[str] = []
                richest: dict[str, Any] | None = None
                for item in result.task_observations:
                    captured = item.get("items")
                    if not isinstance(captured, list) or not captured:
                        continue
                    event = str(item.get("event") or "?")
                    if event not in item_events:
                        item_events.append(event)
                    if richest is None or len(captured) >= len(richest.get("items") or []):
                        richest = item
                lines.append(f"  Task tools: {', '.join(tools) if tools else '-'}")
                lines.append(f"  Task item events: {', '.join(item_events) if item_events else '-'}")
                if richest:
                    captured = richest["items"]
                    lines.append(f"  Task items ({len(captured)}):")
                    for entry in captured[:3]:
                        lines.append(f"    - [{entry.get('status', '?')}] {entry.get('title', '?')}")
                    if len(captured) > 3:
                        lines.append(f"    ... +{len(captured) - 3} more")
            if result.session_identity_observations:
                identities = ", ".join(
                    f"{item.get('event', 'hook')} session={item.get('session_id', '-')} pid={item.get('tracked_pid', '-')}"
                    for item in result.session_identity_observations[:3]
                )
                suffix = "..." if len(result.session_identity_observations) > 3 else ""
                lines.append(f"  Session identity: {identities}{suffix}")
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
                    text_so_far = output.decode("utf-8", errors="replace")
                    os.write(master, str(item.get("text", "")).encode("utf-8"))
                    terminal_observations.append(
                        TerminalObservation(
                            kind="input",
                            text=scripted_input_label(item),
                            offset=len(text_so_far),
                            timestamp=time.time(),
                        )
                    )
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
            if completion_predicate is not None and completion_predicate(
                output.decode("utf-8", errors="replace"),
                terminal_observations,
            ):
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


def scripted_input_label(item: dict[str, Any]) -> str:
    label = item.get("label")
    if isinstance(label, str) and label.strip():
        return label.strip()

    text = str(item.get("text", ""))
    if text == "\x03":
        return "ctrl-c"
    if text == "\x1b":
        return "escape"
    return redact_pii_text(text.replace("\n", "\\n"))[:80]


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


def resolve_agent_binary(
    profile: AgentProfile,
    path_value: str,
    variant_probe: Any = None,
) -> tuple[str | None, str | None]:
    names = list(dict.fromkeys([profile.command] + profile.real_binary_names))
    candidates = all_which_candidates(names, path_value)
    if profile.tool == "kimi" and profile.kimi_variant in ("legacy", "modern"):
        probe = variant_probe or probe_kimi_variant
        for candidate in candidates:
            if probe(candidate) == profile.kimi_variant:
                return candidate, None
        return None, f"no {profile.kimi_variant} kimi binary found"
    if candidates:
        return candidates[0], None
    return None, f"none of {', '.join(names)} found"


def all_which_candidates(names: list[str], path_value: str) -> list[str]:
    candidates: list[str] = []
    seen: set[str] = set()
    for name in names:
        first = shutil.which(name, path=path_value)
        if first and first not in seen:
            seen.add(first)
            candidates.append(first)
        for entry in path_value.split(os.pathsep):
            if not entry:
                continue
            candidate = str(pathlib.Path(entry) / name)
            if candidate in seen:
                continue
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                seen.add(candidate)
                candidates.append(candidate)
    return candidates


def probe_kimi_variant(executable: str) -> str | None:
    cached = KIMI_VARIANT_PROBE_CACHE.get(executable)
    if cached:
        return cached
    env = os.environ.copy()
    env["NO_COLOR"] = "1"
    env["TERM"] = "dumb"
    try:
        result = subprocess.run(
            [executable, "--help"],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
        )
        if result.returncode != 0:
            variant = "legacy"
        else:
            variant = "modern" if is_modern_kimi_help_output(result.stdout) else "legacy"
    except Exception:
        variant = "legacy"
    KIMI_VARIANT_PROBE_CACHE[executable] = variant
    return variant


def is_modern_kimi_help_output(help_text: str) -> bool:
    return "--config-file" not in strip_ansi_sequences(help_text)


def strip_ansi_sequences(text: str) -> str:
    return ANSI_ESCAPE_PATTERN.sub("", text)


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


def app_has_agent_bench_resources(app_path: pathlib.Path) -> bool:
    return (app_path / "Contents" / "Resources" / "bin" / "shared" / "zentty").exists()


def missing_agent_wrapper_resource(app_path: pathlib.Path, profile: AgentProfile) -> str | None:
    resources_dir = app_path / "Contents" / "Resources"
    shared_launcher = resources_dir / "bin" / "shared" / "zentty"
    if not shared_launcher.exists():
        return f"app is missing shared Zentty launcher: {shared_launcher}"

    wrapper_dir = resources_dir / "bin" / profile.tool
    if not wrapper_dir.exists():
        return f"app is missing {profile.tool} wrapper directory: {wrapper_dir}"

    candidate_names = list(dict.fromkeys([profile.command] + profile.real_binary_names))
    candidates = [wrapper_dir / name for name in candidate_names]
    if not any(path.exists() for path in candidates):
        names = ", ".join(path.name for path in candidates)
        return f"app is missing {profile.tool} wrapper executable in {wrapper_dir}: expected one of {names}"
    if not any(os.access(path, os.X_OK) for path in candidates):
        names = ", ".join(path.name for path in candidates)
        return f"app has non-executable {profile.tool} wrapper in {wrapper_dir}: expected one of {names}"

    return None


def repo_derived_data_app() -> pathlib.Path | None:
    """This repo's DerivedData Debug app, resolved without building."""
    try:
        settings = subprocess.run(
            ["xcodebuild", "-project", "Zentty.xcodeproj", "-scheme", "Zentty", "-showBuildSettings"],
            cwd=REPO_ROOT,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        ).stdout
    except (subprocess.CalledProcessError, OSError):
        return None
    values = parse_build_settings(settings)
    products_dir = values.get("BUILT_PRODUCTS_DIR")
    if not products_dir:
        return None
    candidate = pathlib.Path(products_dir) / values.get("FULL_PRODUCT_NAME", "Zentty.app")
    return candidate if app_has_agent_bench_resources(candidate) else None


def latest_derived_data_zentty_app(home: pathlib.Path | None = None) -> pathlib.Path | None:
    derived_data = (home or pathlib.Path.home()) / "Library" / "Developer" / "Xcode" / "DerivedData"
    candidates = [
        path
        for path in derived_data.glob("Zentty-*/Build/Products/Debug/Zentty.app")
        if app_has_agent_bench_resources(path)
    ]
    if not candidates:
        return None
    return max(candidates, key=lambda path: path.stat().st_mtime)


def matches_any(text: str, patterns: list[str]) -> bool:
    return any(re.search(pattern, text, flags=re.I) for pattern in patterns)


def bench_marker_observed(text: str) -> bool:
    return (
        "ZENTTY_AGENT_BENCH_OK" in text
        or "ZENTTY_AGENT_BENCH_APPROVAL_OK" in text
        or "ZENTTY_AGENT_BENCH_AUTO_APPROVAL_OK" in text
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


def prioritize_path_entry_after_zentty_resources(path_value: str, preferred_entry: str) -> str:
    if not preferred_entry:
        return path_value
    entries = [entry for entry in path_value.split(os.pathsep) if entry and entry != preferred_entry]
    insert_at = 0
    while insert_at < len(entries) and is_zentty_resource_bin_path(entries[insert_at]):
        insert_at += 1
    entries.insert(insert_at, preferred_entry)
    return os.pathsep.join(entries)


def config_source_dir(environment: dict[str, Any], env_key: str, default_name: str) -> pathlib.Path:
    home = pathlib.Path(str(environment.get("HOME") or pathlib.Path.home())).expanduser()
    configured = str(environment.get(env_key) or "").strip()
    if configured and not is_zentty_launch_cache_path(configured):
        return pathlib.Path(configured).expanduser()
    return home / default_name


def kimi_config_source_dir(environment: dict[str, Any], variant: str) -> pathlib.Path:
    if variant == "modern":
        return config_source_dir(environment, "KIMI_CODE_HOME", ".kimi-code")
    if str(environment.get("KIMI_SHARE_DIR") or "").strip():
        return config_source_dir(environment, "KIMI_SHARE_DIR", ".kimi")
    return config_source_dir(environment, "KIMI_HOME", ".kimi")


_KIMI_SESSION_INDEX_LOCK = threading.Lock()
_KIMI_SESSIONS_MARKER = "/sessions/"


def _rewrite_kimi_session_index_line(
    line: str,
    *,
    source_home_path: str,
    source_home_prefix: str,
) -> tuple[str, bool]:
    trimmed = line.strip()
    if not trimmed:
        return line, False
    try:
        json_obj = json.loads(trimmed)
    except json.JSONDecodeError:
        return line, False
    if not isinstance(json_obj, dict):
        return line, False

    session_id = json_obj.get("sessionId") or json_obj.get("id")
    session_dir = json_obj.get("sessionDir")
    if not isinstance(session_id, str) or not isinstance(session_dir, str):
        return line, False

    session_dir_path = str(pathlib.Path(session_dir).expanduser())
    if session_dir_path == source_home_path or session_dir_path.startswith(source_home_prefix):
        return line, False

    marker_index = session_dir_path.find(_KIMI_SESSIONS_MARKER)
    if marker_index < 0:
        return line, False

    canonical_path = source_home_path + session_dir_path[marker_index:]
    if not pathlib.Path(canonical_path).exists():
        return line, False

    json_obj["sessionDir"] = canonical_path
    return json.dumps(json_obj, sort_keys=True, separators=(",", ":")), True


def canonicalize_kimi_session_index_if_needed(source_home: pathlib.Path) -> None:
    """Rewrite stale overlay sessionDir paths in Kimi's shared session index.

    Mirrors AgentLaunchBootstrap.canonicalizeKimiSessionIndexIfNeeded: remap
    absolute overlay paths that contain `/sessions/...` onto the durable source
    home, but only when the remapped directory already exists on disk.
    """
    index_path = source_home / "session_index.jsonl"
    if not index_path.is_file():
        return

    source_home_path = str(source_home.resolve())
    source_home_prefix = source_home_path if source_home_path.endswith("/") else source_home_path + "/"

    with _KIMI_SESSION_INDEX_LOCK:
        try:
            raw_text = index_path.read_text(encoding="utf-8")
        except OSError:
            return

        changed = False
        new_lines: list[str] = []
        for line in raw_text.split("\n"):
            rewritten, line_changed = _rewrite_kimi_session_index_line(
                line,
                source_home_path=source_home_path,
                source_home_prefix=source_home_prefix,
            )
            new_lines.append(rewritten)
            if line_changed:
                changed = True

        if not changed:
            return

        try:
            index_path.write_text("\n".join(new_lines), encoding="utf-8")
        except OSError:
            return


# resume_roundtrip markers/prompt. Phase 1 prints a sentinel with NO tool use;
# phase 2 asks the resumed session to RECALL that sentinel WITHOUT the token
# appearing in the prompt — so a model merely echoing the prompt cannot satisfy
# the assertion. Only a genuine reopen of the conversation history passes.
RESUME_ROUNDTRIP_SENTINEL = "ZENTTY_AGENT_BENCH_OK"
RESUME_ROUNDTRIP_PROMPT = (
    "Without using any tools, reply with exactly the sentinel token you were "
    "asked to print earlier in this conversation."
)
# Auth material shared (by symlink) from the operator's real kimi home into the
# bench-owned home, so token refreshes land back in the shared store — exactly
# what the operator validated in their lab. device_id is copied (not shared).
KIMI_AUTH_SYMLINK_NAMES = ("credentials", "oauth")


def seed_kimi_bench_home(bench_home: pathlib.Path, operator_home: pathlib.Path) -> bool:
    """Seed a bench-owned kimi home with the operator's auth so a real session
    can be created without an interactive login. `credentials/` and `oauth/` are
    SYMLINKED (token refreshes flow back to the shared store); `device_id` is
    copied. Returns True when auth material (credentials) is present to seed;
    False lets the caller honor the profile's auth-skip behavior.
    """
    bench_home.mkdir(parents=True, exist_ok=True)
    for name in KIMI_AUTH_SYMLINK_NAMES:
        source = operator_home / name
        target = bench_home / name
        if source.exists() and not target.exists() and not target.is_symlink():
            target.symlink_to(source)
    device_id = operator_home / "device_id"
    if device_id.is_file() and not (bench_home / "device_id").exists():
        shutil.copy2(device_id, bench_home / "device_id")
    # The operator's config.toml carries default_model; without it kimi refuses
    # prompt mode ("No model configured") even with valid credentials. The hook
    # installer later merges the managed block into this copy.
    config = operator_home / "config.toml"
    if config.is_file() and not (bench_home / "config.toml").exists():
        shutil.copy2(config, bench_home / "config.toml")
    credentials = operator_home / "credentials"
    return credentials.exists()


def latest_kimi_session_id(bench_home: pathlib.Path) -> str | None:
    """Return the most recent `session_<uuid>` id from the bench home's
    `session_index.jsonl` (kimi appends one line per session)."""
    index = bench_home / "session_index.jsonl"
    if not index.is_file():
        return None
    session_id: str | None = None
    try:
        raw_text = index.read_text(encoding="utf-8")
    except OSError:
        return None
    for line in raw_text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict):
            continue
        candidate = obj.get("sessionId") or obj.get("id")
        if isinstance(candidate, str) and candidate.strip():
            session_id = candidate.strip()
    return session_id


def resume_sentinel_in_output(output: str) -> bool:
    """True when the phase-1 sentinel appears in phase-2 output (ANSI-stripped),
    proving the resumed session recalled it from conversation history."""
    return RESUME_ROUNDTRIP_SENTINEL in strip_ansi_sequences(output)


def resume_not_found_in_output(output: str) -> bool:
    """True when kimi reported the resumed session could not be found — the
    exact failure the overlay bug produced and this scenario guards against.
    ANSI-stripped, and scoped to session-not-found so an unrelated "file not
    found" from the model does not trip the regression."""
    text = strip_ansi_sequences(output).lower()
    if re.search(r"session\b[^\n]*\bnot found", text):
        return True
    return "no such session" in text


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


def strip_jsonc(text: str) -> str:
    """Remove // and /* */ comments and trailing commas, mirroring
    JSONCRelaxedParse on the app side — Devin config files are JSONC."""
    result: list[str] = []
    index = 0
    in_string = False
    escaped = False
    while index < len(text):
        char = text[index]
        nxt = text[index + 1] if index + 1 < len(text) else ""
        if in_string:
            result.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue
        if char == '"':
            in_string = True
            result.append(char)
            index += 1
        elif char == "/" and nxt == "/":
            while index < len(text) and text[index] not in "\r\n":
                index += 1
        elif char == "/" and nxt == "*":
            index += 2
            while index + 1 < len(text) and not (text[index] == "*" and text[index + 1] == "/"):
                index += 1
            index += 2
        else:
            result.append(char)
            index += 1
    cleaned = "".join(result)
    return re.sub(r",(\s*[}\]])", r"\1", cleaned)


def read_jsonc_object(path: pathlib.Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        value = json.loads(strip_jsonc(path.read_text(encoding="utf-8")))
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def _extract_devin_config_override(arguments: list[str]) -> tuple[list[str], str | None]:
    """Python mirror of AgentLaunchBootstrap.extractDevinConfigOverride."""
    forwarded: list[str] = []
    source: str | None = None
    iterator = iter(arguments)
    for argument in iterator:
        if argument == "--":
            forwarded.extend([argument, *iterator])
            break
        elif argument == "--config":
            value = next(iterator, None)
            if value is None:
                forwarded.append(argument)
            else:
                source = value
        elif argument.startswith("--config="):
            source = argument[len("--config="):]
        else:
            forwarded.append(argument)
    return forwarded, source


def codex_hook_trusted_hash(event_key: str, matcher: str | None, command: str, timeout: int) -> str:
    identity: dict[str, Any] = {
        "event_name": event_key,
        "hooks": [
            {
                "async": False,
                "command": command,
                "timeout": timeout,
                "type": "command",
            }
        ],
    }
    if matcher is not None:
        identity["matcher"] = matcher
    serialized = json.dumps(identity, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return "sha256:" + hashlib.sha256(serialized).hexdigest()


# Marker strings + block layout mirror Swift KimiHooksInstaller (array-tables
# style) exactly, so a bench-written block is byte-faithful enough for Swift's
# `zentty uninstall kimi-hooks` / Settings toggle to remove it.
KIMI_MANAGED_BEGIN_MARKER = "### BEGIN ZENTTY KIMI HOOKS"
KIMI_MANAGED_END_MARKER = "### END ZENTTY KIMI HOOKS"
KIMI_MANAGED_STYLE_MARKER = "# zentty-managed-style = array-tables"
KIMI_MANAGED_EVENTS = (
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "Stop",
    "Notification",
    "PreToolUse",
    "PostToolUse",
)
_KIMI_MANAGED_BLOCK_PATTERN = re.compile(
    r"(?m)^\#\#\# BEGIN ZENTTY KIMI HOOKS[ \t]*$.*?^\#\#\# END ZENTTY KIMI HOOKS[ \t]*$\n?",
    re.DOTALL,
)


def kimi_managed_hook_block(command: str) -> str:
    """The Zentty-managed Kimi hook block (array-tables style), marker-delimited."""
    lines = [KIMI_MANAGED_BEGIN_MARKER, KIMI_MANAGED_STYLE_MARKER]
    for index, event in enumerate(KIMI_MANAGED_EVENTS):
        if index:
            lines.append("")
        lines.append("[[hooks]]")
        lines.append(f'event = "{event}"')
        lines.append(f'command = "{command}"')
    lines.append(KIMI_MANAGED_END_MARKER)
    return "\n".join(lines)


def remove_kimi_managed_hook_block(text: str) -> str:
    """Strip any marker-delimited Zentty-managed Kimi hook block(s)."""
    return _KIMI_MANAGED_BLOCK_PATTERN.sub("", text)


def install_kimi_managed_hook_block(existing: str, command: str) -> str:
    """Return `existing` with exactly one fresh managed block. Idempotent:
    removes any prior managed block before appending, so running it repeatedly
    against the same config yields identical content (no unbounded growth)."""
    without_block = remove_kimi_managed_hook_block(existing).rstrip()
    block = kimi_managed_hook_block(command)
    if without_block:
        return without_block + "\n\n" + block + "\n"
    return block + "\n"


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


def replace_top_level_yaml_block(text: str, key: str, replacement: str) -> str:
    lines = text.splitlines()
    output: list[str] = []
    index = 0
    key_pattern = re.compile(rf"^{re.escape(key)}:\s*(?:#.*)?$")
    while index < len(lines):
        line = lines[index]
        if key_pattern.match(line):
            index += 1
            while index < len(lines):
                candidate = lines[index]
                is_top_level = bool(candidate.strip()) and not candidate.startswith((" ", "\t"))
                is_comment = candidate.lstrip().startswith("#")
                if is_top_level and not is_comment:
                    break
                index += 1
            continue
        output.append(line)
        index += 1

    base = "\n".join(output).rstrip()
    replacement = replacement.rstrip()
    if base:
        return f"{base}\n\n{replacement}\n"
    return f"{replacement}\n"


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


def sanitized_amp_resume_arguments(arguments: list[str]) -> list[str]:
    remaining = list(arguments)
    if remaining and remaining[0] == "amp":
        remaining = remaining[1:]
    if len(remaining) >= 2 and remaining[0] in {"threads", "thread", "t"} and remaining[1] in {"continue", "c"}:
        remaining = remaining[2:]
        if remaining and re.fullmatch(r"T-[A-Za-z0-9_-]+", remaining[0]):
            remaining = remaining[1:]
    if remaining and remaining[0] in {
        "login",
        "logout",
        "mcp",
        "permission",
        "permissions",
        "review",
        "skill",
        "skills",
        "tool",
        "tools",
        "update",
        "up",
        "usage",
        "version",
    }:
        return []
    rejected_flags = {"--execute", "--print", "-x", "--help", "-h", "--version", "-V", "--jetbrains"}
    if any(amp_option_name(argument) in rejected_flags for argument in remaining):
        return []

    safe_value_options = {"--mode", "-m", "--effort", "--settings-file", "--log-level", "--log-file", "--mcp-config", "--visibility"}
    dropped_value_options = {"--label", "-l"}
    dropped_flags = {"--archive", "--stream-json", "--stream-json-input", "--stream-json-thinking", "--json", "--output-format"}
    sanitized: list[str] = []
    index = 0
    while index < len(remaining):
        argument = remaining[index]
        option_name = argument.split("=", 1)[0] if argument.startswith("--") else argument
        if option_name in safe_value_options:
            if "=" in argument:
                sanitized.append(argument)
            elif index + 1 < len(remaining) and not remaining[index + 1].startswith("-"):
                sanitized.extend([argument, remaining[index + 1]])
                index += 1
        elif option_name in dropped_value_options:
            if "=" not in argument and index + 1 < len(remaining) and not remaining[index + 1].startswith("-"):
                index += 1
        elif option_name in dropped_flags:
            if option_name == "--output-format" and "=" not in argument and index + 1 < len(remaining) and not remaining[index + 1].startswith("-"):
                index += 1
        elif argument.startswith("-"):
            pass
        else:
            break
        index += 1
    return sanitized


def amp_option_name(argument: str) -> str:
    return argument.split("=", 1)[0] if argument.startswith("--") else argument


CLAUDE_HOOK_ROUTING_KEYS = (
    "ZENTTY_INSTANCE_SOCKET",
    "ZENTTY_INSTANCE_ID",
    "ZENTTY_WINDOW_ID",
    "ZENTTY_WORKLANE_ID",
    "ZENTTY_PANE_ID",
    "ZENTTY_PANE_TOKEN",
)


def claude_hook_command(cli_path: str, environment: dict[str, Any]) -> str:
    # Mirror AgentLaunchBootstrap.claudeHookCommand: the command carries the
    # launch pane's routing so a daemon-run session does not use the daemon's.
    command = f'"{shell_escape_double_quoted(cli_path)}" ipc agent-event --adapter=claude'

    def value(key: str) -> str:
        return str(environment.get(key) or "").strip()

    if not all(value(key) for key in ("ZENTTY_WORKLANE_ID", "ZENTTY_PANE_ID", "ZENTTY_PANE_TOKEN")):
        return command
    unset = [f"-u {key}" for key in CLAUDE_HOOK_ROUTING_KEYS if not value(key)]
    assignments = [f'{key}="{shell_escape_double_quoted(value(key))}"' for key in CLAUDE_HOOK_ROUTING_KEYS if value(key)]
    return " ".join(["/usr/bin/env", *unset, *assignments, command])


def shell_escape_double_quoted(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")


def toml_basic_string(value: str) -> str:
    escaped: list[str] = []
    for char in value:
        codepoint = ord(char)
        if char == "\b":
            escaped.append("\\b")
        elif char == "\t":
            escaped.append("\\t")
        elif char == "\n":
            escaped.append("\\n")
        elif char == "\f":
            escaped.append("\\f")
        elif char == "\r":
            escaped.append("\\r")
        elif char == '"':
            escaped.append('\\"')
        elif char == "\\":
            escaped.append("\\\\")
        elif codepoint < 0x20:
            escaped.append(f"\\u{codepoint:04x}")
        else:
            escaped.append(char)
    return "".join(escaped)


def quoted_toml_basic_string(value: str) -> str:
    return f'"{toml_basic_string(value)}"'


def toml_string_array(values: list[str]) -> str:
    return "[" + ",".join(quoted_toml_basic_string(value) for value in values) + "]"


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
