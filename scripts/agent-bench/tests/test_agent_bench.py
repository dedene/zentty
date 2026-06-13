import importlib.util
import json
import os
import pathlib
import socket
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("agent_bench", ROOT / "agent_bench.py")
agent_bench = importlib.util.module_from_spec(SPEC)
sys.modules["agent_bench"] = agent_bench
SPEC.loader.exec_module(agent_bench)


class RedactionTests(unittest.TestCase):
    def test_redacts_secret_values_and_keeps_routing_context(self):
        env = {
            "ZENTTY_PANE_ID": "pane-1",
            "ZENTTY_WORKLANE_ID": "worklane-1",
            "ZENTTY_HERMES_PID": "4242",
            "ZENTTY_PANE_TOKEN": "pane-secret",
            "OPENAI_API_KEY": "sk-secret",
            "PATH": "/usr/bin",
        }

        redacted = agent_bench.redacted_environment(env)

        self.assertEqual(redacted["ZENTTY_PANE_ID"], "pane-1")
        self.assertEqual(redacted["ZENTTY_WORKLANE_ID"], "worklane-1")
        self.assertEqual(redacted["ZENTTY_HERMES_PID"], "4242")
        self.assertEqual(redacted["ZENTTY_PANE_TOKEN"], "<redacted>")
        self.assertEqual(redacted["OPENAI_API_KEY"], "<redacted>")
        self.assertNotIn("PATH", redacted)

    def test_redacts_personal_paths_from_routing_environment_values(self):
        env = {
            "HOME": "/Users/example",
            "CODEX_HOME": "/Users/example/.codex",
            "OPENCODE_CONFIG": "/Users/example/.config/opencode/config.json",
            "ZENTTY_PANE_ID": "pane-1",
        }

        redacted = agent_bench.redacted_environment(env)

        self.assertEqual(redacted["HOME"], "/Users/<user>")
        self.assertEqual(redacted["CODEX_HOME"], "/Users/<user>/.codex")
        self.assertEqual(redacted["OPENCODE_CONFIG"], "/Users/<user>/.config/opencode/config.json")
        self.assertEqual(redacted["ZENTTY_PANE_ID"], "pane-1")

    def test_redacts_personal_fields_from_hook_standard_input(self):
        payload = {
            "hook_event_name": "sessionStart",
            "user_email": "dev@example.invalid",
            "workspace_roots": ["/Users/example/Development/project"],
            "prompt": "run the smoke command",
        }

        redacted = agent_bench.redact_standard_input(json.dumps(payload))

        self.assertIn('"user_email":"<redacted>"', redacted)
        self.assertIn('"/Users/<user>/Development/project"', redacted)
        self.assertIn('"prompt":"run the smoke command"', redacted)


class EventInferenceTests(unittest.TestCase):
    def test_infers_adapter_and_event_from_ipc_arguments(self):
        event = agent_bench.infer_hook_event(
            subcommand="agent-event",
            arguments=["--adapter=codex", "pre-tool-use"],
            standard_input='{"hook_event_name":"Ignored"}',
        )

        self.assertEqual(event.adapter, "codex")
        self.assertEqual(event.event_name, "pre-tool-use")

    def test_infers_event_from_common_json_fields_when_no_positional_event_exists(self):
        event = agent_bench.infer_hook_event(
            subcommand="agent-event",
            arguments=["--adapter=claude"],
            standard_input='{"hook_event_name":"SessionStart","session_id":"abc"}',
        )

        self.assertEqual(event.adapter, "claude")
        self.assertEqual(event.event_name, "SessionStart")

    def test_infers_agent_from_canonical_payload_agent_name(self):
        agent = agent_bench.agent_from_adapter(
            adapter=None,
            environment={},
            standard_input='{"version":1,"event":"session.start","agent":{"name":"OpenCode"}}',
        )

        self.assertEqual(agent, "opencode")


class SyntheticScenarioTests(unittest.TestCase):
    def test_post_stop_notification_detector_flags_late_notification(self):
        records = [
            agent_bench.TraceRecord(kind="hook", agent="claude", scenario="stop_race", event_name="SessionStart"),
            agent_bench.TraceRecord(kind="hook", agent="claude", scenario="stop_race", event_name="Stop"),
            agent_bench.TraceRecord(kind="hook", agent="claude", scenario="stop_race", event_name="Notification"),
        ]
        self.assertTrue(agent_bench._trace_contains_post_stop_notification(records))

    def test_post_stop_notification_detector_ignores_notification_before_stop(self):
        records = [
            agent_bench.TraceRecord(kind="hook", agent="claude", scenario="stop_race", event_name="Notification"),
            agent_bench.TraceRecord(kind="hook", agent="claude", scenario="stop_race", event_name="Stop"),
        ]
        self.assertFalse(agent_bench._trace_contains_post_stop_notification(records))

    def test_load_profiles_parses_synthetic_fields_for_stop_race_scenario(self):
        profile_dir = ROOT / "profiles"
        profiles = agent_bench.load_profiles(profile_dir)
        stop_race = profiles["claude"].expectations["stop_race"]
        self.assertTrue(stop_race.synthetic)
        self.assertEqual(stop_race.fixture, "claude_stop_then_late_notification.jsonl")
        self.assertTrue(stop_race.post_stop_notification_required)

    def test_load_profiles_parses_restore_launch_bootstrap_requirements(self):
        profile_dir = ROOT / "profiles"
        profiles = agent_bench.load_profiles(profile_dir)
        restore_launch = profiles["codex"].expectations["restore_launch"]

        self.assertEqual(restore_launch.required_events, [])
        self.assertEqual(restore_launch.required_bootstrap_arguments, [["resume", "session-codex"]])

    def test_compact_profiles_require_pre_and_post_compact_hooks(self):
        profile_dir = ROOT / "profiles"
        profiles = agent_bench.load_profiles(profile_dir)

        self.assertEqual(
            profiles["codex"].expectations["manual_compact"].required_events,
            ["pre-compact", "post-compact"],
        )
        self.assertEqual(
            profiles["claude"].expectations["manual_compact"].required_events,
            ["SessionStart", "PreCompact"],
        )
        self.assertEqual(
            profiles["opencode"].expectations["manual_compact"].required_events,
            ["session.start", "agent.compacting"],
        )
        self.assertIn("manual_compact", profiles["opencode"].input_by_scenario)
        self.assertEqual(profiles["opencode"].input_by_scenario["manual_compact"][0]["text"], "/compact\r")

    def test_cursor_profile_defines_session_capture_restore_and_interactive_completion(self):
        profile_dir = ROOT / "profiles"
        profiles = agent_bench.load_profiles(profile_dir)
        cursor = profiles["cursor"]

        self.assertIn("session_capture", cursor.expectations)
        self.assertIn("restore_launch", cursor.expectations)
        self.assertIn("interactive_turn_complete", cursor.expectations)
        self.assertEqual(
            cursor.expectations["session_capture"].session_identity.session_id_pattern,
            "uuid",
        )
        self.assertEqual(
            cursor.expectations["restore_launch"].required_bootstrap_arguments,
            [["--resume=237d8c32-2a27-4850-8da8-3a110f13682c"]],
        )
        self.assertEqual(
            cursor.expectations["interactive_turn_complete"].required_events,
            ["beforeSubmitPrompt", "sessionStart", "stop"],
        )

    def test_stop_race_fixture_contains_late_notification_after_stop(self):
        fixture_path = ROOT / "fixtures" / "claude_stop_then_late_notification.jsonl"
        events = []
        for line in fixture_path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            events.append(json.loads(stripped)["hook_event_name"])
        self.assertIn("Stop", events)
        self.assertIn("Notification", events)
        # The bug-trigger ordering: Notification must follow Stop in the
        # fixture so a synthetic replay reproduces the timing pattern.
        self.assertGreater(events.index("Notification"), events.index("Stop"))


class ExpectationTests(unittest.TestCase):
    def test_load_profiles_parses_session_identity_requirements(self):
        profile_dir = ROOT / "profiles"
        profiles = agent_bench.load_profiles(profile_dir)
        session_capture = profiles["codex"].expectations["session_capture"]

        self.assertEqual(session_capture.session_identity.session_id_pattern, "codex")
        self.assertTrue(session_capture.session_identity.tracked_pid)

    def test_validation_reports_missing_required_bootstrap_arguments(self):
        scenario = agent_bench.ScenarioExpectation(
            name="restore_launch",
            required_events=[],
            required_bootstrap_arguments=[["resume", "session-codex"]],
        )
        observed = [
            agent_bench.TraceRecord(
                kind="bootstrap",
                agent="codex",
                scenario="restore_launch",
                extra={"arguments": ["exec", "do work"]},
            )
        ]

        result = agent_bench.validate_scenario("codex", scenario, observed)

        self.assertFalse(result.passed)
        self.assertEqual(result.missing_events, ["bootstrap:resume session-codex"])
        self.assertEqual(result.result_kind, "missing-bootstrap")

    def test_validation_marks_required_bootstrap_arguments_as_passed(self):
        scenario = agent_bench.ScenarioExpectation(
            name="restore_launch",
            required_events=[],
            required_bootstrap_arguments=[["resume", "session-codex"]],
        )
        observed = [
            agent_bench.TraceRecord(
                kind="bootstrap",
                agent="codex",
                scenario="restore_launch",
                extra={"arguments": ["resume", "session-codex"]},
            )
        ]

        result = agent_bench.validate_scenario("codex", scenario, observed)

        self.assertTrue(result.passed)
        self.assertEqual(result.result_kind, "bootstrap-pass")

    def test_scenario_expectation_keeps_required_terminal_phases_as_third_positional_argument(self):
        scenario = agent_bench.ScenarioExpectation("tui_restart", [], ["idle"])

        self.assertEqual(scenario.required_terminal_phases, ["idle"])
        self.assertEqual(scenario.forbidden_events, [])

    def test_validation_fails_when_forbidden_hook_event_is_observed(self):
        scenario = agent_bench.ScenarioExpectation(
            name="auto_approval",
            required_events=["session-start", "prompt-submit", "stop"],
            forbidden_events=["permission-request"],
        )
        observed = [
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="auto_approval", event_name="session-start"),
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="auto_approval", event_name="prompt-submit"),
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="auto_approval", event_name="permission-request"),
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="auto_approval", event_name="stop"),
        ]

        result = agent_bench.validate_scenario("codex", scenario, observed)

        self.assertFalse(result.passed)
        self.assertEqual(result.missing_events, ["forbidden:permission-request"])
        self.assertEqual(result.result_kind, "forbidden-hook")

    def test_validation_reports_missing_session_identity(self):
        scenario = agent_bench.ScenarioExpectation(
            name="session_capture",
            required_events=["session-start"],
            session_identity=agent_bench.SessionIdentityExpectation(
                session_id_pattern="codex",
                tracked_pid=True,
            ),
        )
        observed = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="codex",
                scenario="session_capture",
                event_name="session-start",
                standard_input='{"hook_event_name":"SessionStart"}',
                environment={"ZENTTY_PANE_ID": "pane-1"},
            )
        ]

        result = agent_bench.validate_scenario("codex", scenario, observed)

        self.assertFalse(result.passed)
        self.assertEqual(result.result_kind, "missing-session-identity")
        self.assertEqual(result.missing_events, ["session-id:codex", "tracked-pid"])

    def test_validation_accepts_session_identity_from_payload_and_environment(self):
        scenario = agent_bench.ScenarioExpectation(
            name="session_capture",
            required_events=["session-start"],
            session_identity=agent_bench.SessionIdentityExpectation(
                session_id_pattern="codex",
                tracked_pid=True,
            ),
        )
        observed = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="codex",
                scenario="session_capture",
                event_name="session-start",
                standard_input='{"hook_event_name":"SessionStart","session_id":"019e213c-12ca-7bd2-8fa8-514563f745a6"}',
                environment={"ZENTTY_CODEX_PID": "5925"},
            )
        ]

        result = agent_bench.validate_scenario("codex", scenario, observed)

        self.assertTrue(result.passed)
        self.assertEqual(result.result_kind, "hook-pass")
        self.assertEqual(
            result.session_identity_observations,
            [
                {
                    "event": "session-start",
                    "session_id": "019e213c-12ca-7bd2-8fa8-514563f745a6",
                    "session_id_pattern": "codex",
                    "session_id_valid": True,
                    "session_id_source": "session_id",
                    "tracked_pid": 5925,
                    "tracked_pid_source": "ZENTTY_CODEX_PID",
                }
            ],
        )

    def test_validation_accepts_nested_session_identity_from_payload(self):
        scenario = agent_bench.ScenarioExpectation(
            name="session_capture",
            required_events=["session.start"],
            session_identity=agent_bench.SessionIdentityExpectation(
                session_id_pattern="opencode",
                tracked_pid=True,
            ),
        )
        observed = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="opencode",
                scenario="session_capture",
                event_name="session.start",
                standard_input='{"event":"session.start","session":{"id":"ses_ZenttyBenchRestore"},"agent":{"name":"OpenCode","pid":19405}}',
            )
        ]

        result = agent_bench.validate_scenario("opencode", scenario, observed)

        self.assertTrue(result.passed)
        self.assertEqual(result.session_identity_observations[0]["session_id_source"], "session.id")
        self.assertEqual(result.session_identity_observations[0]["tracked_pid_source"], "agent.pid")

    def test_validation_accepts_cursor_conversation_id_as_session_identity(self):
        scenario = agent_bench.ScenarioExpectation(
            name="session_capture",
            required_events=["sessionStart"],
            session_identity=agent_bench.SessionIdentityExpectation(
                session_id_pattern="uuid",
                tracked_pid=True,
            ),
        )
        observed = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="cursor",
                scenario="session_capture",
                event_name="sessionStart",
                standard_input='{"hook_event_name":"sessionStart","conversation_id":"237d8c32-2a27-4850-8da8-3a110f13682c"}',
                environment={"ZENTTY_CURSOR_PID": "5925"},
            )
        ]

        result = agent_bench.validate_scenario("cursor", scenario, observed)

        self.assertTrue(result.passed)
        self.assertEqual(
            result.session_identity_observations[0]["session_id_source"],
            "conversation_id",
        )

    def test_validation_ignores_non_cursor_conversation_id_as_session_identity(self):
        scenario = agent_bench.ScenarioExpectation(
            name="session_capture",
            required_events=["sessionStart"],
            session_identity=agent_bench.SessionIdentityExpectation(
                session_id_pattern="uuid",
                tracked_pid=False,
            ),
        )
        observed = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="codex",
                scenario="session_capture",
                event_name="sessionStart",
                standard_input='{"event":"session.start","conversation_id":"237d8c32-2a27-4850-8da8-3a110f13682c"}',
            )
        ]

        result = agent_bench.validate_scenario("codex", scenario, observed)

        self.assertFalse(result.passed)
        self.assertEqual(result.missing_events, ["session-id:uuid"])

    def test_validation_ignores_pid_environment_for_other_agents(self):
        scenario = agent_bench.ScenarioExpectation(
            name="session_capture",
            required_events=["SessionStart"],
            session_identity=agent_bench.SessionIdentityExpectation(
                session_id_pattern="uuid",
                tracked_pid=True,
            ),
        )
        observed = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="claude",
                scenario="session_capture",
                event_name="SessionStart",
                standard_input='{"hook_event_name":"SessionStart","session_id":"0943211c-e3cf-4327-9334-cdacb3f4ec29"}',
                environment={"ZENTTY_CODEX_PID": "5925"},
            )
        ]

        result = agent_bench.validate_scenario("claude", scenario, observed)

        self.assertFalse(result.passed)
        self.assertEqual(result.missing_events, ["tracked-pid"])
        self.assertNotIn("tracked_pid", result.session_identity_observations[0])

    def test_validation_reports_missing_required_events(self):
        scenario = agent_bench.ScenarioExpectation(
            name="smoke",
            required_events=["SessionStart", "UserPromptSubmit", "Stop"],
        )
        observed = [
            agent_bench.TraceRecord(kind="hook", agent="claude", scenario="smoke", event_name="SessionStart"),
            agent_bench.TraceRecord(kind="hook", agent="claude", scenario="smoke", event_name="Stop"),
        ]

        result = agent_bench.validate_scenario("claude", scenario, observed)

        self.assertFalse(result.passed)
        self.assertEqual(result.missing_events, ["UserPromptSubmit"])

    def test_validation_marks_complete_hooks_as_hook_pass(self):
        scenario = agent_bench.ScenarioExpectation(
            name="smoke",
            required_events=["SessionStart", "Stop"],
        )
        observed = [
            agent_bench.TraceRecord(kind="hook", agent="claude", scenario="smoke", event_name="SessionStart"),
            agent_bench.TraceRecord(kind="hook", agent="claude", scenario="smoke", event_name="Stop"),
        ]

        result = agent_bench.validate_scenario("claude", scenario, observed)

        self.assertTrue(result.passed)
        self.assertEqual(result.result_kind, "hook-pass")

    def test_validation_counts_duplicate_required_events(self):
        scenario = agent_bench.ScenarioExpectation(
            name="restart",
            required_events=["session-start", "stop", "session-start", "stop"],
        )
        observed = [
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="restart", event_name="session-start"),
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="restart", event_name="stop"),
        ]

        result = agent_bench.validate_scenario("codex", scenario, observed)

        self.assertFalse(result.passed)
        self.assertEqual(result.missing_events, ["session-start", "stop"])

    def test_timeout_without_required_hooks_is_classified_by_taxonomy(self):
        result = agent_bench.classify_timeout_result(
            agent="codex",
            scenario="approval",
            expectation=agent_bench.ScenarioExpectation("approval", ["permission-request"]),
            records=[],
            terminal_observations=[],
            output="working for a while",
            skip_patterns=[],
            timeout=3,
            strict=False,
        )

        self.assertEqual(result.status, "skip")
        self.assertEqual(result.result_kind, "process-timeout")
        self.assertIn("timed out", result.detail)

    def test_completed_refusal_is_classified_separately_from_missing_hook(self):
        result = agent_bench.classify_completed_result(
            agent="claude",
            scenario="approval",
            expectation=agent_bench.ScenarioExpectation("approval", ["PreToolUse"]),
            records=[],
            terminal_observations=[],
            output="I cannot run that command without more context.",
            skip_patterns=[],
            exit_code=0,
            completed_by_predicate=False,
            strict=False,
        )

        self.assertFalse(result.passed)
        self.assertEqual(result.status, "fail")
        self.assertEqual(result.result_kind, "agent-refusal")

    def test_completed_missing_hook_uses_missing_hook_taxonomy(self):
        result = agent_bench.classify_completed_result(
            agent="opencode",
            scenario="approval",
            expectation=agent_bench.ScenarioExpectation("approval", ["agent.needs-input"]),
            records=[
                agent_bench.TraceRecord(kind="hook", agent="opencode", scenario="approval", event_name="session.start")
            ],
            terminal_observations=[],
            output="done",
            skip_patterns=[],
            exit_code=0,
            completed_by_predicate=False,
            strict=False,
        )

        self.assertFalse(result.passed)
        self.assertEqual(result.status, "fail")
        self.assertEqual(result.result_kind, "missing-hook")

    def test_completed_bench_marker_with_auth_text_still_fails_missing_hooks(self):
        result = agent_bench.classify_completed_result(
            agent="gemini",
            scenario="approval",
            expectation=agent_bench.ScenarioExpectation("approval", ["Notification"]),
            records=[],
            terminal_observations=[],
            output="Waiting for authentication...\nZENTTY_AGENT_BENCH_APPROVAL_OK",
            skip_patterns=["auth"],
            exit_code=0,
            completed_by_predicate=False,
            strict=False,
        )

        self.assertFalse(result.passed)
        self.assertEqual(result.status, "fail")
        self.assertEqual(result.result_kind, "missing-hook")
        self.assertIn("command completed", result.detail)

    def test_timeout_bench_marker_with_auth_text_still_fails_missing_hooks(self):
        result = agent_bench.classify_timeout_result(
            agent="gemini",
            scenario="approval",
            expectation=agent_bench.ScenarioExpectation("approval", ["Notification"]),
            records=[],
            terminal_observations=[],
            output="Waiting for authentication...\nZENTTY_AGENT_BENCH_APPROVAL_OK",
            skip_patterns=["auth"],
            timeout=30,
            strict=False,
        )

        self.assertFalse(result.passed)
        self.assertEqual(result.status, "fail")
        self.assertEqual(result.result_kind, "missing-hook")

    def test_question_scenario_requires_terminal_needs_input_title(self):
        records = [
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="question", event_name="session-start"),
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="question", event_name="prompt-submit"),
        ]
        result = agent_bench.classify_completed_result(
            agent="codex",
            scenario="question",
            expectation=agent_bench.ScenarioExpectation("question", ["session-start", "prompt-submit"]),
            records=records,
            terminal_observations=[],
            output="",
            skip_patterns=[],
            exit_code=0,
            completed_by_predicate=False,
            strict=False,
        )

        self.assertFalse(result.passed)
        self.assertEqual(result.result_kind, "missing-terminal-needs-input")

    def test_question_scenario_accepts_action_required_title(self):
        records = [
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="question", event_name="session-start"),
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="question", event_name="prompt-submit"),
        ]
        result = agent_bench.classify_completed_result(
            agent="codex",
            scenario="question",
            expectation=agent_bench.ScenarioExpectation("question", ["session-start", "prompt-submit"]),
            records=records,
            terminal_observations=[
                agent_bench.TerminalObservation(kind="title", text="[ ! ] Action Required | codex-question", offset=0)
            ],
            output="",
            skip_patterns=[],
            exit_code=0,
            completed_by_predicate=True,
            strict=False,
        )

        self.assertTrue(result.passed)
        self.assertEqual(result.result_kind, "hook-pass")

    def test_question_interrupt_scenario_requires_scripted_input_trace(self):
        records = [
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="question_interrupt", event_name="session-start"),
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="question_interrupt", event_name="prompt-submit"),
        ]
        result = agent_bench.classify_completed_result(
            agent="codex",
            scenario="question_interrupt",
            expectation=agent_bench.ScenarioExpectation("question_interrupt", ["session-start", "prompt-submit"]),
            records=records,
            terminal_observations=[
                agent_bench.TerminalObservation(kind="title", text="[ ! ] Action Required | codex-question", offset=0)
            ],
            output="",
            skip_patterns=[],
            exit_code=0,
            completed_by_predicate=True,
            strict=False,
        )

        self.assertFalse(result.passed)
        self.assertEqual(result.result_kind, "missing-scripted-input")

    def test_question_interrupt_scenario_accepts_ctrl_c_input_trace(self):
        records = [
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="question_interrupt", event_name="session-start"),
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="question_interrupt", event_name="prompt-submit"),
        ]
        result = agent_bench.classify_completed_result(
            agent="codex",
            scenario="question_interrupt",
            expectation=agent_bench.ScenarioExpectation("question_interrupt", ["session-start", "prompt-submit"]),
            records=records,
            terminal_observations=[
                agent_bench.TerminalObservation(kind="title", text="[ ! ] Action Required | codex-question", offset=0),
                agent_bench.TerminalObservation(kind="input", text="ctrl-c", offset=12),
            ],
            output="",
            skip_patterns=[],
            exit_code=130,
            completed_by_predicate=True,
            strict=False,
        )

        self.assertTrue(result.passed)
        self.assertEqual(result.result_kind, "hook-pass")

    def test_question_interrupt_scenario_rejects_trust_input_as_scripted_interrupt(self):
        records = [
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="question_interrupt", event_name="session-start"),
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="question_interrupt", event_name="prompt-submit"),
        ]
        result = agent_bench.classify_completed_result(
            agent="codex",
            scenario="question_interrupt",
            expectation=agent_bench.ScenarioExpectation("question_interrupt", ["session-start", "prompt-submit"]),
            records=records,
            terminal_observations=[
                agent_bench.TerminalObservation(kind="title", text="[ ! ] Action Required | codex-question", offset=0),
                agent_bench.TerminalObservation(kind="input", text="trust-workspace", offset=12),
            ],
            output="",
            skip_patterns=[],
            exit_code=0,
            completed_by_predicate=True,
            strict=False,
        )

        self.assertFalse(result.passed)
        self.assertEqual(result.result_kind, "missing-scripted-input")

    def test_question_interrupt_scenario_fails_when_action_required_persists_after_ctrl_c(self):
        records = [
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="question_interrupt", event_name="session-start"),
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="question_interrupt", event_name="prompt-submit"),
        ]
        result = agent_bench.classify_completed_result(
            agent="codex",
            scenario="question_interrupt",
            expectation=agent_bench.ScenarioExpectation("question_interrupt", ["session-start", "prompt-submit"]),
            records=records,
            terminal_observations=[
                agent_bench.TerminalObservation(kind="title", text="[ ! ] Action Required | codex-question", offset=0),
                agent_bench.TerminalObservation(kind="input", text="ctrl-c", offset=12),
                agent_bench.TerminalObservation(kind="title", text="[ ! ] Action Required | codex-question", offset=30),
            ],
            output="",
            skip_patterns=[],
            exit_code=130,
            completed_by_predicate=True,
            strict=False,
        )

        self.assertFalse(result.passed)
        self.assertEqual(result.result_kind, "stale-terminal-needs-input")

    def test_approval_scenario_rejects_stale_terminal_approval_after_scripted_approval(self):
        records = [
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="approval", event_name="session-start"),
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="approval", event_name="prompt-submit"),
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="approval", event_name="permission-request"),
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="approval", event_name="post-tool-use"),
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="approval", event_name="stop"),
        ]
        result = agent_bench.classify_completed_result(
            agent="codex",
            scenario="approval",
            expectation=agent_bench.ScenarioExpectation(
                "approval",
                ["session-start", "prompt-submit", "permission-request", "post-tool-use", "stop"],
            ),
            records=records,
            terminal_observations=[
                agent_bench.TerminalObservation(kind="title", text="Requires approval", offset=0),
                agent_bench.TerminalObservation(kind="input", text="approve-command", offset=12),
                agent_bench.TerminalObservation(kind="title", text="[ . ] Action Required | codex-approval", offset=24),
            ],
            output="",
            skip_patterns=[],
            exit_code=0,
            completed_by_predicate=False,
            strict=False,
        )

        self.assertFalse(result.passed)
        self.assertEqual(result.result_kind, "stale-terminal-needs-input")

    def test_non_codex_approval_scenario_does_not_require_codex_scripted_input_label(self):
        records = [
            agent_bench.TraceRecord(kind="hook", agent="claude", scenario="approval", event_name="SessionStart"),
            agent_bench.TraceRecord(kind="hook", agent="claude", scenario="approval", event_name="UserPromptSubmit"),
            agent_bench.TraceRecord(kind="hook", agent="claude", scenario="approval", event_name="PreToolUse"),
            agent_bench.TraceRecord(kind="hook", agent="claude", scenario="approval", event_name="PermissionRequest"),
        ]
        result = agent_bench.classify_completed_result(
            agent="claude",
            scenario="approval",
            expectation=agent_bench.ScenarioExpectation(
                "approval",
                ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest"],
            ),
            records=records,
            terminal_observations=[
                agent_bench.TerminalObservation(kind="input", text="approve-tool", offset=12),
            ],
            output="",
            skip_patterns=[],
            exit_code=0,
            completed_by_predicate=True,
            strict=False,
        )

        self.assertTrue(result.passed)
        self.assertEqual(result.result_kind, "hook-pass")

    def test_codex_approval_profile_requires_post_tool_use_resume_signal(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["codex"]

        self.assertIn("post-tool-use", profile.expectations["approval"].required_events)

    def test_codex_auto_approval_profile_forbids_manual_approval_signals(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["codex"]
        expectation = profile.expectations["auto_approval"]

        self.assertIn("auto_approval", profile.launch_args_by_scenario)
        self.assertEqual(expectation.forbidden_events, ["permission-request"])
        self.assertEqual(expectation.forbidden_terminal_phases, ["needs-input"])
        self.assertNotIn("auto_approval", profile.input_by_scenario)

    def test_completed_result_fails_when_forbidden_terminal_phase_is_observed(self):
        result = agent_bench.classify_completed_result(
            agent="codex",
            scenario="auto_approval",
            expectation=agent_bench.ScenarioExpectation(
                "auto_approval",
                ["session-start", "prompt-submit", "stop"],
                forbidden_terminal_phases=["needs-input"],
            ),
            records=[
                agent_bench.TraceRecord(kind="hook", agent="codex", scenario="auto_approval", event_name="session-start"),
                agent_bench.TraceRecord(kind="hook", agent="codex", scenario="auto_approval", event_name="prompt-submit"),
                agent_bench.TraceRecord(kind="hook", agent="codex", scenario="auto_approval", event_name="stop"),
            ],
            terminal_observations=[
                agent_bench.TerminalObservation(kind="title", text="main needs approval", offset=0),
            ],
            output="ZENTTY_AGENT_BENCH_AUTO_APPROVAL_OK",
            skip_patterns=[],
            exit_code=0,
            completed_by_predicate=True,
            strict=True,
        )

        self.assertFalse(result.passed)
        self.assertEqual(result.result_kind, "forbidden-terminal-phase")

    def test_timeout_result_fails_when_forbidden_terminal_phase_is_observed(self):
        result = agent_bench.classify_timeout_result(
            agent="codex",
            scenario="auto_approval",
            expectation=agent_bench.ScenarioExpectation(
                "auto_approval",
                ["session-start", "prompt-submit"],
                forbidden_terminal_phases=["needs-input"],
            ),
            records=[
                agent_bench.TraceRecord(kind="hook", agent="codex", scenario="auto_approval", event_name="session-start"),
                agent_bench.TraceRecord(kind="hook", agent="codex", scenario="auto_approval", event_name="prompt-submit"),
            ],
            terminal_observations=[
                agent_bench.TerminalObservation(kind="title", text="main needs approval", offset=0),
            ],
            output="",
            skip_patterns=[],
            timeout=30,
            strict=True,
        )

        self.assertFalse(result.passed)
        self.assertEqual(result.result_kind, "forbidden-terminal-phase")


class TimelineTests(unittest.TestCase):
    def test_extracts_terminal_title_and_osc9_observations(self):
        output = "\x1b]0;Codex Working 1/3\x07hello\x1b]9;Codex needs input\x1b\\"

        observations = agent_bench.extract_terminal_observations(output)

        self.assertEqual(
            [(item.kind, item.text) for item in observations],
            [("title", "Codex Working 1/3"), ("progress", "Codex Working 1/3"), ("osc9", "Codex needs input")],
        )

    def test_requires_approval_title_counts_as_needs_input_phase(self):
        phase = agent_bench.terminal_observation_phase(
            agent_bench.TerminalObservation(kind="title", text="Requires approval", offset=0)
        )

        self.assertEqual(phase, "needs-input")

    def test_extracts_copilot_asking_question_title_as_progress_observation(self):
        output = "\x1b]0;Asking question\x07"

        observations = agent_bench.extract_terminal_observations(output)

        self.assertEqual(
            [(item.kind, item.text) for item in observations],
            [("title", "Asking question"), ("progress", "Asking question")],
        )

    def test_builds_normalized_timeline_from_records_and_terminal_observations(self):
        base = 1000.0
        records = [
            agent_bench.TraceRecord(kind="version", agent="codex", scenario="smoke", timestamp=base, extra={"version": "codex 1"}),
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="smoke", event_name="session-start", timestamp=base + 0.25),
        ]
        observations = [
            agent_bench.TerminalObservation(kind="title", text="Codex Working", offset=12, timestamp=base + 0.1),
            agent_bench.TerminalObservation(kind="input", text="ctrl-c", offset=24, timestamp=base + 0.2),
        ]

        timeline = agent_bench.build_timeline("codex", "smoke", records, observations)

        self.assertEqual([entry["source"] for entry in timeline], ["process", "terminal", "terminal", "hook"])
        self.assertEqual([entry["time_ms"] for entry in timeline], [0, 100, 200, 250])
        self.assertEqual(timeline[1]["event"], "title")
        self.assertEqual(timeline[2]["event"], "input")
        self.assertEqual(timeline[3]["event"], "session-start")

    def test_terminal_phase_sequence_keeps_codex_startup_idle_visible(self):
        base = 1000.0
        observations = [
            agent_bench.TerminalObservation(kind="title", text="Ready | zentty", offset=0, timestamp=base),
            agent_bench.TerminalObservation(kind="progress", text="Ready | zentty", offset=0, timestamp=base),
            agent_bench.TerminalObservation(kind="title", text="Starting ⠹ zentty", offset=12, timestamp=base + 0.5),
            agent_bench.TerminalObservation(kind="progress", text="Starting ⠹ zentty", offset=12, timestamp=base + 0.5),
            agent_bench.TerminalObservation(kind="title", text="Working ⠋ zentty", offset=24, timestamp=base + 1.0),
        ]

        self.assertEqual(
            agent_bench.terminal_phase_sequence(observations),
            ["idle", "starting", "running"],
        )

    def test_legacy_terminal_observations_without_timestamp_sort_after_records(self):
        base = 1000.0
        records = [
            agent_bench.TraceRecord(kind="version", agent="codex", scenario="smoke", timestamp=base, extra={"version": "codex 1"}),
            agent_bench.TraceRecord(kind="hook", agent="codex", scenario="smoke", event_name="session-start", timestamp=base + 0.25),
        ]
        observations = [
            agent_bench.TerminalObservation(kind="title", text="Codex Working", offset=12),
        ]

        timeline = agent_bench.build_timeline("codex", "smoke", records, observations)

        self.assertEqual([entry["source"] for entry in timeline], ["process", "hook", "terminal"])
        self.assertEqual([entry["time_ms"] for entry in timeline], [0, 250, 250])

    def test_report_writes_taxonomy_timeline_and_rerun_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = type(
                "Args",
                (),
                {
                    "run_dir": tmp,
                    "app_path": "/tmp/Zentty.app",
                    "no_build": True,
                    "timeout": 30,
                    "strict": False,
                    "agents": "codex",
                    "scenarios": "approval",
                },
            )()
            runner = agent_bench.BenchRunner(args)
            result = agent_bench.ScenarioResult(
                agent="codex",
                scenario="approval",
                passed=False,
                missing_events=["permission-request"],
                observed_events=["session-start"],
                status="fail",
                detail="missing required hooks",
                result_kind="missing-hook",
                timeline=[{"time_ms": 0, "source": "hook", "event": "session-start"}],
                rerun_command="python3 scripts/agent-bench/agent_bench.py run --agents codex --scenarios approval",
            )

            runner._write_report([result])

            summary = json.loads((pathlib.Path(tmp) / "summary.json").read_text(encoding="utf-8"))
            report = (pathlib.Path(tmp) / "report.md").read_text(encoding="utf-8")

        self.assertEqual(summary[0]["result_kind"], "missing-hook")
        self.assertEqual(summary[0]["timeline"][0]["event"], "session-start")
        self.assertIn("Result kind: missing-hook", report)
        self.assertIn("Rerun: python3 scripts/agent-bench/agent_bench.py run --agents codex --scenarios approval", report)

    def test_report_writes_session_identity_observations(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = type(
                "Args",
                (),
                {
                    "run_dir": tmp,
                    "app_path": "/tmp/Zentty.app",
                    "no_build": True,
                    "timeout": 30,
                    "strict": False,
                    "agents": "codex",
                    "scenarios": "session_capture",
                },
            )()
            runner = agent_bench.BenchRunner(args)
            result = agent_bench.ScenarioResult(
                agent="codex",
                scenario="session_capture",
                passed=True,
                missing_events=[],
                observed_events=["session-start"],
                status="pass",
                result_kind="hook-pass",
                session_identity_observations=[
                    {
                        "event": "session-start",
                        "session_id": "session-codex",
                        "session_id_valid": True,
                        "tracked_pid": 5925,
                    }
                ],
            )

            runner._write_report([result])

            summary = json.loads((pathlib.Path(tmp) / "summary.json").read_text(encoding="utf-8"))
            report = (pathlib.Path(tmp) / "report.md").read_text(encoding="utf-8")

        self.assertEqual(summary[0]["session_identity_observations"][0]["session_id"], "session-codex")
        self.assertIn("Session identity: session-start session=session-codex pid=5925", report)

    def test_self_test_rerun_command_uses_self_test_subcommand(self):
        args = type(
            "Args",
            (),
            {
                "run_dir": None,
                "app_path": "/tmp/Zentty.app",
                "no_build": True,
                "timeout": 30,
                "strict": False,
                "agents": "codex",
                "scenarios": "smoke",
            },
        )()
        runner = agent_bench.BenchRunner(args)

        command = runner._rerun_command("codex", "self-test")

        self.assertEqual(
            command,
            "python3 scripts/agent-bench/agent_bench.py self-test --timeout 30 --no-build --app-path /tmp/Zentty.app",
        )


class TaskObservationTests(unittest.TestCase):
    def test_extracts_cursor_todo_write_progress_from_hook_payload(self):
        records = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="cursor",
                scenario="tasks",
                event_name="preToolUse",
                adapter="cursor",
                standard_input=json.dumps(
                    {
                        "hook_event_name": "preToolUse",
                        "tool_name": "TodoWrite",
                        "tool_input": {
                            "todos": [
                                {"content": "Review logs", "status": "completed"},
                                {"content": "Patch adapter", "status": "in_progress"},
                                {"content": "Run tests", "status": "pending"},
                            ]
                        },
                    }
                ),
            )
        ]

        observations = agent_bench.task_observations_for_records("cursor", "tasks", records)

        self.assertEqual(
            observations,
            [{"event": "preToolUse", "tool": "TodoWrite", "done": 1, "total": 3, "source": "raw_tool_call"}],
        )

    def test_extracts_cursor_todo_write_merge_progress_from_hook_payloads(self):
        records = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="cursor",
                scenario="tasks",
                event_name="preToolUse",
                adapter="cursor",
                standard_input=json.dumps(
                    {
                        "hook_event_name": "preToolUse",
                        "conversation_id": "cursor-session",
                        "tool_name": "TodoWrite",
                        "tool_input": {
                            "merge": False,
                            "todos": [
                                {"id": "dummy-1", "content": "Review logs", "status": "pending"},
                                {"id": "dummy-2", "content": "Run tests", "status": "pending"},
                                {"id": "dummy-3", "content": "Verify profile", "status": "pending"},
                                {"id": "dummy-4", "content": "Check resume", "status": "pending"},
                                {"id": "dummy-5", "content": "Smoke test", "status": "pending"},
                            ],
                        },
                    }
                ),
            ),
            agent_bench.TraceRecord(
                kind="hook",
                agent="cursor",
                scenario="tasks",
                event_name="preToolUse",
                adapter="cursor",
                standard_input=json.dumps(
                    {
                        "hook_event_name": "preToolUse",
                        "conversation_id": "cursor-session",
                        "tool_name": "TodoWrite",
                        "tool_input": {
                            "merge": True,
                            "todos": [
                                {"id": "dummy-1", "content": "Review logs", "status": "completed"},
                                {"id": "dummy-3", "content": "Verify profile", "status": "completed"},
                            ],
                        },
                    }
                ),
            ),
            agent_bench.TraceRecord(
                kind="hook",
                agent="cursor",
                scenario="tasks",
                event_name="preToolUse",
                adapter="cursor",
                standard_input=json.dumps(
                    {
                        "hook_event_name": "preToolUse",
                        "conversation_id": "cursor-session",
                        "tool_name": "TodoWrite",
                        "tool_input": {
                            "merge": True,
                            "todos": [{"id": "dummy-6", "content": "Validate AgentEventBridge", "status": "pending"}],
                        },
                    }
                ),
            ),
        ]

        observations = agent_bench.task_observations_for_records("cursor", "tasks", records)

        self.assertEqual(
            observations[-1],
            {"event": "preToolUse", "tool": "TodoWrite", "done": 2, "total": 6, "source": "raw_tool_call"},
        )

    def test_extracts_cursor_todo_write_progress_from_trace_extra(self):
        records = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="cursor",
                scenario="tasks",
                event_name="afterShellExecution",
                adapter="cursor",
                standard_input=json.dumps({"hook_event_name": "afterShellExecution"}),
                extra={"task_progress": {"tool": "TodoWrite", "done": 1, "total": 3, "source": "cursor_transcript"}},
            )
        ]

        observations = agent_bench.task_observations_for_records("cursor", "tasks", records)

        self.assertEqual(
            observations,
            [{"event": "afterShellExecution", "tool": "TodoWrite", "done": 1, "total": 3, "source": "cursor_transcript"}],
        )

    def test_extracts_cursor_todo_write_progress_from_transcript_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            transcript_path = pathlib.Path(tmp) / "cursor.jsonl"
            transcript_path.write_text(
                json.dumps(
                    {
                        "role": "assistant",
                        "message": {
                            "content": [
                                {
                                    "type": "tool_use",
                                    "name": "TodoWrite",
                                    "input": {
                                        "todos": [
                                            {"content": "Review logs", "status": "completed"},
                                            {"content": "Patch adapter", "status": "in_progress"},
                                            {"content": "Run tests", "status": "pending"},
                                        ]
                                    },
                                }
                            ]
                        },
                    }
                ),
                encoding="utf-8",
            )

            progress = agent_bench.cursor_transcript_task_progress(
                {"transcript_path": str(transcript_path)},
                attempts=1,
            )

        self.assertEqual(
            progress,
            {"tool": "TodoWrite", "done": 1, "total": 3, "source": "cursor_transcript"},
        )

    def test_extracts_cursor_todo_write_merge_progress_from_transcript_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            transcript_path = pathlib.Path(tmp) / "cursor.jsonl"
            transcript_path.write_text(
                "\n".join(
                    [
                        json.dumps(
                            {
                                "role": "assistant",
                                "message": {
                                    "content": [
                                        {
                                            "type": "tool_use",
                                            "name": "TodoWrite",
                                            "input": {
                                                "merge": False,
                                                "todos": [
                                                    {"id": "dummy-1", "content": "Review logs", "status": "pending"},
                                                    {"id": "dummy-2", "content": "Run tests", "status": "pending"},
                                                    {"id": "dummy-3", "content": "Verify profile", "status": "pending"},
                                                    {"id": "dummy-4", "content": "Check resume", "status": "pending"},
                                                    {"id": "dummy-5", "content": "Smoke test", "status": "pending"},
                                                ],
                                            },
                                        }
                                    ]
                                },
                            }
                        ),
                        json.dumps(
                            {
                                "role": "assistant",
                                "message": {
                                    "content": [
                                        {
                                            "type": "tool_use",
                                            "name": "TodoWrite",
                                            "input": {
                                                "merge": True,
                                                "todos": [
                                                    {"id": "dummy-1", "content": "Review logs", "status": "completed"},
                                                    {"id": "dummy-3", "content": "Verify profile", "status": "completed"},
                                                ],
                                            },
                                        }
                                    ]
                                },
                            }
                        ),
                        json.dumps(
                            {
                                "role": "assistant",
                                "message": {
                                    "content": [
                                        {
                                            "type": "tool_use",
                                            "name": "TodoWrite",
                                            "input": {
                                                "merge": True,
                                                "todos": [
                                                    {"id": "dummy-6", "content": "Validate AgentEventBridge", "status": "pending"}
                                                ],
                                            },
                                        }
                                    ]
                                },
                            }
                        ),
                    ]
                ),
                encoding="utf-8",
            )

            progress = agent_bench.cursor_transcript_task_progress(
                {"transcript_path": str(transcript_path)},
                attempts=1,
            )

        self.assertEqual(
            progress,
            {"tool": "TodoWrite", "done": 2, "total": 6, "source": "cursor_transcript"},
        )

    def test_extracts_canonical_task_progress_source(self):
        records = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="grok",
                scenario="tasks",
                event_name="task.progress",
                adapter="grok",
                standard_input=json.dumps({"event": "task.progress", "progress": {"done": 2, "total": 4}}),
            )
        ]

        observations = agent_bench.task_observations_for_records("grok", "tasks", records)

        self.assertEqual(
            observations,
            [{"event": "task.progress", "tool": "TodoWrite", "done": 2, "total": 4, "source": "canonical"}],
        )

    def test_completed_tasks_scenario_without_todo_write_is_missing_task_hook(self):
        result = agent_bench.classify_completed_result(
            agent="codex",
            scenario="tasks",
            expectation=agent_bench.ScenarioExpectation("tasks", ["sessionStart", "sessionEnd"]),
            records=[
                agent_bench.TraceRecord(kind="hook", agent="codex", scenario="tasks", event_name="sessionStart"),
                agent_bench.TraceRecord(kind="hook", agent="codex", scenario="tasks", event_name="sessionEnd"),
            ],
            terminal_observations=[],
            output="ZENTTY_AGENT_BENCH_TASKS_OK",
            skip_patterns=[],
            exit_code=0,
            completed_by_predicate=False,
            strict=False,
        )

        self.assertFalse(result.passed)
        self.assertEqual(result.status, "fail")
        self.assertEqual(result.result_kind, "missing-task-hook")

    def test_cursor_tasks_scenario_without_todo_write_is_missing_task_hook(self):
        result = agent_bench.classify_completed_result(
            agent="cursor",
            scenario="tasks",
            expectation=agent_bench.ScenarioExpectation("tasks", ["sessionStart", "afterShellExecution", "sessionEnd"]),
            records=[
                agent_bench.TraceRecord(kind="hook", agent="cursor", scenario="tasks", event_name="sessionStart"),
                agent_bench.TraceRecord(kind="hook", agent="cursor", scenario="tasks", event_name="afterShellExecution"),
                agent_bench.TraceRecord(kind="hook", agent="cursor", scenario="tasks", event_name="sessionEnd"),
            ],
            terminal_observations=[],
            output="ZENTTY_AGENT_BENCH_TASKS_OK",
            skip_patterns=[],
            exit_code=0,
            completed_by_predicate=False,
            strict=False,
        )

        self.assertFalse(result.passed)
        self.assertEqual(result.status, "fail")
        self.assertEqual(result.result_kind, "missing-task-hook")

    def test_tasks_scenario_fails_when_expected_task_progress_is_missing(self):
        result = agent_bench.classify_completed_result(
            agent="cursor",
            scenario="tasks",
            expectation=agent_bench.ScenarioExpectation(
                "tasks",
                ["sessionStart", "afterShellExecution", "sessionEnd"],
                expected_task_progress={"done": 2, "total": 6},
            ),
            records=[
                agent_bench.TraceRecord(kind="hook", agent="cursor", scenario="tasks", event_name="sessionStart"),
                agent_bench.TraceRecord(
                    kind="hook",
                    agent="cursor",
                    scenario="tasks",
                    event_name="afterShellExecution",
                    extra={"task_progress": {"tool": "TodoWrite", "done": 0, "total": 1, "source": "cursor_transcript"}},
                ),
                agent_bench.TraceRecord(kind="hook", agent="cursor", scenario="tasks", event_name="sessionEnd"),
            ],
            terminal_observations=[],
            output="ZENTTY_AGENT_BENCH_TASKS_OK",
            skip_patterns=[],
            exit_code=0,
            completed_by_predicate=False,
            strict=False,
        )

        self.assertFalse(result.passed)
        self.assertEqual(result.result_kind, "missing-task-progress")

    def test_tasks_scenario_passes_when_expected_task_progress_is_observed(self):
        result = agent_bench.classify_completed_result(
            agent="cursor",
            scenario="tasks",
            expectation=agent_bench.ScenarioExpectation(
                "tasks",
                ["sessionStart", "afterShellExecution", "sessionEnd"],
                expected_task_progress={"done": 2, "total": 6},
            ),
            records=[
                agent_bench.TraceRecord(kind="hook", agent="cursor", scenario="tasks", event_name="sessionStart"),
                agent_bench.TraceRecord(
                    kind="hook",
                    agent="cursor",
                    scenario="tasks",
                    event_name="afterShellExecution",
                    extra={"task_progress": {"tool": "TodoWrite", "done": 2, "total": 6, "source": "cursor_transcript"}},
                ),
                agent_bench.TraceRecord(kind="hook", agent="cursor", scenario="tasks", event_name="sessionEnd"),
            ],
            terminal_observations=[],
            output="ZENTTY_AGENT_BENCH_TASKS_OK",
            skip_patterns=[],
            exit_code=0,
            completed_by_predicate=False,
            strict=False,
        )

        self.assertTrue(result.passed)
        self.assertEqual(result.result_kind, "hook-pass")


class IPCServerTests(unittest.TestCase):
    def test_bench_runner_uses_short_socket_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = type(
                "Args",
                (),
                {
                    "run_dir": tmp,
                    "app_path": "/tmp/Zentty.app",
                    "no_build": True,
                    "timeout": 30,
                    "strict": False,
                    "agents": "codex",
                    "scenarios": "question_interrupt",
                },
            )()
            runner = agent_bench.BenchRunner(args)
            try:
                socket_path = runner.socket_dir / "question_interrupt.sock"

                self.assertTrue(str(socket_path).startswith("/tmp/zab-"))
                self.assertLess(len(str(socket_path)), 100)
            finally:
                runner._cleanup_socket_dir()

    def test_capture_server_accepts_newline_delimited_requests_and_records_hooks(self):
        with tempfile.TemporaryDirectory() as tmp:
            profile = agent_bench.AgentProfile(
                name="codex",
                command="codex",
                real_binary_names=["codex"],
                version_args=["--version"],
                launch_args_by_scenario={"smoke": []},
                expectations={"smoke": agent_bench.ScenarioExpectation("smoke", ["pre-tool-use"])},
            )
            recorder = agent_bench.TraceRecorder(pathlib.Path(tmp))
            server = agent_bench.CaptureServer(
                pathlib.Path(tmp) / "bench.sock",
                recorder=recorder,
                profiles={"codex": profile},
                scenario="smoke",
            )
            server.start()
            try:
                request = {
                    "version": 1,
                    "id": "req-1",
                    "kind": "ipc",
                    "arguments": ["--adapter=codex", "pre-tool-use"],
                    "standardInput": '{"event":"x"}',
                    "environment": {"ZENTTY_PANE_ID": "pane-1", "OPENAI_API_KEY": "secret"},
                    "expectsResponse": False,
                    "subcommand": "agent-event",
                    "tool": None,
                }
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.connect(str(server.socket_path))
                    client.sendall(json.dumps(request).encode("utf-8") + b"\n")

                records = recorder.wait_for_count(1)
            finally:
                server.stop()

        self.assertEqual(len(records), 1)
        self.assertEqual(records[0].agent, "codex")
        self.assertEqual(records[0].event_name, "pre-tool-use")
        self.assertEqual(records[0].environment["OPENAI_API_KEY"], "<redacted>")
        self.assertEqual(records[0].standard_input, '{"event":"x"}')


class ProfileTests(unittest.TestCase):
    def test_loads_profiles_for_all_zentty_supported_agents(self):
        profiles = agent_bench.load_profiles(ROOT / "profiles")

        self.assertEqual(
            sorted(profiles),
            ["agy", "amp", "claude", "codex", "copilot", "cursor", "droid", "gemini", "grok", "hermes", "kimi", "opencode", "pi", "vibe"],
        )
        self.assertEqual(sorted(agent_bench.SUPPORTED_AGENTS), sorted(profiles))
        for profile in profiles.values():
            self.assertIn("smoke", profile.expectations)

    def test_amp_profile_covers_session_capture_and_restore_launch(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["amp"]

        self.assertEqual(profile.command, "amp")
        self.assertIn("--execute", profile.launch_args_by_scenario["smoke"])
        self.assertEqual(
            profile.expectations["session_capture"].session_identity.session_id_pattern,
            "amp",
        )
        self.assertEqual(
            profile.expectations["restore_launch"].required_bootstrap_arguments,
            [["threads", "continue", "T-ZenttyBenchRestore"]],
        )

    def test_cursor_smoke_profile_uses_headless_hook_events(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["cursor"]

        self.assertIn("--force", profile.launch_args_by_scenario["smoke"])
        self.assertEqual(
            profile.expectations["smoke"].required_events,
            ["sessionStart", "afterShellExecution", "sessionEnd"],
        )

    def test_cursor_approval_profile_bypasses_workspace_trust_for_permission_path(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["cursor"]

        self.assertNotIn("--trust", profile.launch_args_by_scenario["approval"])
        self.assertEqual(profile.input_by_scenario["approval"][0]["text"], "a")

    def test_cursor_tasks_profile_drives_todo_write_scenario(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["cursor"]

        self.assertIn("tasks", profile.launch_args_by_scenario)
        self.assertIn("TodoWrite", profile.launch_args_by_scenario["tasks"][-1])
        self.assertEqual(
            profile.expectations["tasks"].required_events,
            ["sessionStart", "afterShellExecution", "sessionEnd"],
        )
        self.assertEqual(profile.expectations["tasks"].expected_task_progress, {"done": 2, "total": 6})

    def test_copilot_approval_profile_drives_interactive_prompt_like_a_person(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["copilot"]

        self.assertEqual(profile.launch_args_by_scenario["approval"][:2], ["--prompt", "Run this exact shell command: printf ZENTTY_AGENT_BENCH_APPROVAL_OK"])
        self.assertIn("--allow-all-paths", profile.launch_args_by_scenario["approval"])
        self.assertNotIn("--allow-all-tools", profile.launch_args_by_scenario["approval"])

    def test_claude_approval_profile_drives_permission_tool_hook(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["claude"]
        approval_args = profile.launch_args_by_scenario["approval"]
        prompt = approval_args[-1]

        self.assertIn("--setting-sources", approval_args)
        self.assertIn("project,local", approval_args)
        self.assertIn("--permission-mode", approval_args)
        self.assertIn("default", approval_args)
        self.assertNotIn("--print", approval_args)
        self.assertNotIn("--output-format", approval_args)
        self.assertIn("integration hook regression test", prompt)
        self.assertIn("Write tool", prompt)
        self.assertIn("ZENTTY_AGENT_BENCH_APPROVAL_OK", prompt)
        self.assertNotIn("Ask before running", prompt)
        self.assertEqual(
            profile.expectations["approval"].required_events,
            ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest"],
        )
        self.assertEqual(
            profile.input_by_scenario["approval"],
            [
                {
                    "match": "Command to approve|Yes, allow|Do you want|Permission|allow",
                    "text": "1\n",
                }
            ],
        )

    def test_codex_question_profile_waits_for_action_required_title(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["codex"]

        self.assertIn("question", profile.launch_args_by_scenario)
        self.assertIn("question_interrupt", profile.launch_args_by_scenario)
        self.assertEqual(
            profile.expectations["question"].required_events,
            ["session-start", "prompt-submit"],
        )
        self.assertEqual(
            profile.expectations["question_interrupt"].required_events,
            ["session-start", "prompt-submit"],
        )
        self.assertEqual(profile.input_by_scenario["question"][0]["match"], "trust")
        self.assertEqual(profile.input_by_scenario["question_interrupt"][-1]["label"], "ctrl-c")

    def test_codex_restart_profile_runs_smoke_twice_in_same_pane(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["codex"]

        self.assertEqual(profile.repeat_by_scenario["restart"], 2)
        self.assertEqual(
            profile.launch_args_by_scenario["restart"],
            profile.launch_args_by_scenario["smoke"],
        )
        self.assertEqual(
            profile.expectations["restart"].required_events,
            [
                "session-start",
                "prompt-submit",
                "pre-tool-use",
                "post-tool-use",
                "stop",
                "session-start",
                "prompt-submit",
                "pre-tool-use",
                "post-tool-use",
                "stop",
            ],
        )

    def test_codex_tui_restart_profile_quits_interactive_codex_twice(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["codex"]

        self.assertEqual(profile.repeat_by_scenario["tui_restart"], 2)
        self.assertIn("--no-alt-screen", profile.launch_args_by_scenario["tui_restart"])
        self.assertEqual(
            profile.expectations["tui_restart"].required_events,
            [],
        )
        self.assertEqual(
            profile.expectations["tui_restart"].required_terminal_phases,
            ["idle", "starting", "idle", "starting"],
        )
        self.assertEqual(profile.input_by_scenario["tui_restart"][0]["label"], "trust-workspace")
        self.assertEqual(profile.input_by_scenario["tui_restart"][1]["label"], "quit")

    def test_classification_rejects_out_of_order_terminal_phase_requirements(self):
        result = agent_bench.classify_completed_result(
            agent="codex",
            scenario="tui_restart",
            expectation=agent_bench.ScenarioExpectation(
                name="tui_restart",
                required_events=[],
                required_terminal_phases=["idle", "starting", "idle", "starting"],
            ),
            records=[],
            terminal_observations=[
                agent_bench.TerminalObservation(kind="title", text="starting", offset=0),
                agent_bench.TerminalObservation(kind="title", text="idle", offset=1),
                agent_bench.TerminalObservation(kind="title", text="starting", offset=2),
                agent_bench.TerminalObservation(kind="title", text="idle", offset=3),
            ],
            output="",
            skip_patterns=[],
            exit_code=0,
            completed_by_predicate=True,
            strict=False,
        )

        self.assertFalse(result.passed)
        self.assertEqual(result.result_kind, "missing-terminal-phase")
        self.assertEqual(result.missing_events, ["starting"])

    def test_gemini_smoke_profile_skips_trust_prompt_for_headless_runs(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["gemini"]

        self.assertIn("--skip-trust", profile.launch_args_by_scenario["smoke"])

    def test_droid_approval_profile_waits_for_real_permission_prompt(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["droid"]

        self.assertEqual(profile.launch_args_by_scenario["approval"][0], "exec")
        self.assertIn("touch ZENTTY_AGENT_BENCH_APPROVAL_OK", profile.launch_args_by_scenario["approval"][1])

    def test_agy_profile_uses_supported_headless_flags_and_wrapper_lifecycle(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["agy"]

        self.assertIn("--print", profile.launch_args_by_scenario["smoke"])
        self.assertIn("--prompt", profile.launch_args_by_scenario["smoke"])
        self.assertNotIn("--format", profile.launch_args_by_scenario["smoke"])
        self.assertEqual(
            profile.expectations["smoke"].required_events,
            ["session.start", "agent.running"],
        )
        self.assertEqual(
            profile.expectations["restore_launch"].required_bootstrap_arguments,
            [["--continue"]],
        )

    def test_agy_profile_session_capture_requires_uuid_session_identity(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["agy"]
        identity = profile.expectations["session_capture"].session_identity
        self.assertIsNotNone(identity)
        assert identity is not None  # narrow for type-checker
        self.assertEqual(identity.session_id_pattern, "uuid")
        self.assertTrue(identity.tracked_pid)

    def test_agy_profile_tools_scenario_requires_tool_use_lifecycle_events(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["agy"]
        self.assertIn("tools", profile.launch_args_by_scenario)
        self.assertIn("--dangerously-skip-permissions", profile.launch_args_by_scenario["tools"])
        # Tool-use hook events show up in bench traces under the kebab-case
        # positional our shell command passes through `agy-hook`, not the
        # PascalCase names the Antigravity CLI uses in its JSON payload.
        self.assertEqual(
            profile.expectations["tools"].required_events,
            ["session.start", "agent.running", "pre-tool-use", "post-tool-use", "stop"],
        )

    def test_agy_profile_restore_launch_with_id_asserts_conversation_flag(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["agy"]
        self.assertIn("restore_launch_with_id", profile.launch_args_by_scenario)
        self.assertEqual(
            profile.launch_args_by_scenario["restore_launch_with_id"][0],
            "--conversation",
        )
        self.assertEqual(
            profile.expectations["restore_launch_with_id"].required_bootstrap_arguments,
            [["--conversation", "zentty-bench-conversation-fixture"]],
        )

    def test_agy_plan_installs_overlay_hooks_and_preserves_user_config(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["agy"]
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = pathlib.Path(tmp)
            # Populate HOME with a `.gemini/antigravity-cli/settings.json`
            # we can verify the overlay does NOT surface, and a
            # `.gemini/config/config.json` we can verify the overlay DOES
            # surface (user settings must survive alongside our hooks.json).
            real_home = run_dir / "real-home"
            (real_home / ".gemini" / "antigravity-cli").mkdir(parents=True)
            (real_home / ".gemini" / "antigravity-cli" / "settings.json").write_text("{}")
            (real_home / ".gemini" / "config").mkdir(parents=True)
            (real_home / ".gemini" / "config" / "config.json").write_text('{"theme":"dark"}')

            plan = agent_bench.LaunchPlanner(
                profile=profile,
                scenario="tools",
                run_dir=run_dir,
                resources_dir=None,
            ).plan(
                {
                    "arguments": ["--print", "--prompt", "hello"],
                    "environment": {
                        "ZENTTY_REAL_BINARY": "/usr/local/bin/agy",
                        "ZENTTY_CLI_BIN": "/tmp/zentty-bench",
                        "HOME": str(real_home),
                    },
                }
            )

            overlay_home = pathlib.Path(plan["setEnvironment"]["HOME"])

            self.assertEqual(plan["setEnvironment"]["ZENTTY_AGENT_TOOL"], "agy")
            # The user's config.json survives via the symlinked config dir…
            self.assertTrue((overlay_home / ".gemini" / "config" / "config.json").exists())
            # …the antigravity-cli subtree is skipped…
            self.assertFalse((overlay_home / ".gemini" / "antigravity-cli" / "settings.json").exists())
            # …and we write a real hooks.json (not a symlink) so the tools
            # scenario fires real hooks against the bench CLI.
            overlay_hooks = overlay_home / ".gemini" / "config" / "hooks.json"
            self.assertTrue(overlay_hooks.exists())
            self.assertFalse(overlay_hooks.is_symlink())
            hooks_doc = json.loads(overlay_hooks.read_text())
            self.assertEqual(
                set(hooks_doc["zentty"].keys()),
                {"SessionStart", "PreInvocation", "Stop", "turn-completion",
                 "Notification", "SessionEnd", "PreToolUse", "PostToolUse"},
            )
            # Tool-use events carry the matcher wrapper; lifecycle do not.
            self.assertIn("matcher", hooks_doc["zentty"]["PreToolUse"][0])
            self.assertNotIn("matcher", hooks_doc["zentty"]["Stop"][0])
            # The bench CLI path is baked into the hook command, and the
            # event positional is forwarded to agy-hook.
            stop_cmd = hooks_doc["zentty"]["Stop"][0]["command"]
            self.assertIn("/tmp/zentty-bench", stop_cmd)
            self.assertIn("agy-hook stop", stop_cmd)

            self.assertEqual([action["arguments"] for action in plan["preLaunchActions"]], [["--adapter=agy"], ["--adapter=agy"]])
            self.assertIn('"event":"session.start"', plan["preLaunchActions"][0]["standardInput"])
            self.assertIn('"event":"agent.running"', plan["preLaunchActions"][1]["standardInput"])

            placeholder = plan["setEnvironment"]["ZENTTY_AGY_PLACEHOLDER_SESSION_ID"]
            # The placeholder follows the `zentty-placeholder-<uuid>`
            # pattern so the Swift resume builder can recognise and strip
            # it; downstream code never confuses it for a real
            # conversation_id.
            self.assertTrue(placeholder.startswith("zentty-placeholder-"), placeholder)
            import uuid as _uuid
            _uuid.UUID(placeholder[len("zentty-placeholder-"):])
            self.assertIn('"id":"' + placeholder + '"', plan["preLaunchActions"][0]["standardInput"])
            self.assertIn('"id":"' + placeholder + '"', plan["preLaunchActions"][1]["standardInput"])
            self.assertNotIn("pane-antigravity", plan["preLaunchActions"][0]["standardInput"])

    def test_hermes_plan_installs_overlay_hooks_and_preserves_launch_context(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["hermes"]
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = pathlib.Path(tmp)
            real_home = run_dir / "real-home"
            (real_home / ".hermes").mkdir(parents=True)
            (real_home / ".hermes" / "hooks").mkdir()
            (real_home / ".hermes" / "hooks" / "foreign.sh").write_text("# untouched\n", encoding="utf-8")
            (real_home / ".hermes" / "logs").mkdir()
            (real_home / ".hermes" / "logs" / "agent.log").write_text("real log\n", encoding="utf-8")
            (real_home / ".hermes" / "auth.json").write_text("{}")
            (real_home / ".hermes" / "credentials.json").write_text("{}")
            (real_home / ".hermes" / "state.db").write_text("state")
            (real_home / ".hermes" / "state.db-wal").write_text("wal")
            (real_home / ".hermes" / "config.yaml").write_text(
                "\n".join([
                    "model: test",
                    "providers:",
                    "  xai-oauth:",
                    "    base_url: https://api.x.ai/v1",
                    "hooks:",
                    "  on_session_start:",
                    "    - command: /real/hooks/old.sh",
                    "      timeout: 99",
                    "terminal:",
                    "  backend: local",
                ]) + "\n",
                encoding="utf-8",
            )

            plan = agent_bench.LaunchPlanner(
                profile=profile,
                scenario="session_capture",
                run_dir=run_dir,
                resources_dir=None,
            ).plan(
                {
                    "arguments": ["--tui", "--model", "anthropic/claude-sonnet-4.6"],
                    "environment": {
                        "ZENTTY_REAL_BINARY": "/usr/local/bin/hermes",
                        "ZENTTY_CLI_BIN": "/tmp/zentty-bench",
                        "HOME": str(real_home),
                    },
                }
            )

            overlay_home = pathlib.Path(plan["setEnvironment"]["HOME"])
            hermes_home = pathlib.Path(plan["setEnvironment"]["HERMES_HOME"])

            self.assertEqual(plan["setEnvironment"]["ZENTTY_AGENT_TOOL"], "hermes")
            self.assertEqual(hermes_home, overlay_home / ".hermes")
            self.assertTrue((hermes_home / "auth.json").exists())
            self.assertFalse((hermes_home / "auth.json").is_symlink())
            self.assertTrue((hermes_home / "state.db").exists())
            self.assertFalse((hermes_home / "state.db").is_symlink())
            self.assertTrue((hermes_home / "state.db-wal").exists())
            self.assertFalse((hermes_home / "state.db-wal").is_symlink())
            self.assertTrue((hermes_home / "credentials.json").exists())
            self.assertFalse((hermes_home / "config.yaml").is_symlink())
            self.assertFalse((hermes_home / "shell-hooks-allowlist.json").is_symlink())

            config = (hermes_home / "config.yaml").read_text(encoding="utf-8")
            self.assertIn("model: test", config)
            self.assertIn("providers:", config)
            self.assertIn("terminal:", config)
            self.assertIn("on_session_start:", config)
            self.assertIn("pre_approval_request:", config)
            self.assertIn("/hooks/zentty-status/on-session-start.sh", config)
            self.assertNotIn("/real/hooks/old.sh", config)
            self.assertNotIn("sh -c", config)
            hook_script = hermes_home / "hooks" / "zentty-status" / "on-session-start.sh"
            self.assertFalse((hermes_home / "hooks").is_symlink())
            self.assertFalse((hermes_home / "logs").is_symlink())
            self.assertEqual((real_home / ".hermes" / "hooks" / "foreign.sh").read_text(encoding="utf-8"), "# untouched\n")
            self.assertEqual((real_home / ".hermes" / "logs" / "agent.log").read_text(encoding="utf-8"), "real log\n")
            self.assertTrue(hook_script.exists())
            self.assertTrue(os.access(hook_script, os.X_OK))
            hook_script_text = hook_script.read_text(encoding="utf-8")
            self.assertIn("/tmp/zentty-bench", hook_script_text)
            self.assertIn("zentty_resolve_hermes_pid()", hook_script_text)
            self.assertIn("ZENTTY_HERMES_PID=\"$ZENTTY_RESOLVED_HERMES_PID\"", hook_script_text)
            self.assertIn("hermes-hook on-session-start", hook_script_text)

            allowlist = json.loads((hermes_home / "shell-hooks-allowlist.json").read_text(encoding="utf-8"))
            self.assertEqual({item["event"] for item in allowlist["approvals"]}, {event[0] for event in agent_bench.LaunchPlanner._HERMES_HOOK_EVENTS})
            self.assertTrue(all("/hooks/zentty-status/" in item["command"] for item in allowlist["approvals"]))

            self.assertEqual([action["arguments"] for action in plan["preLaunchActions"]], [["--adapter=hermes"], ["--adapter=hermes"]])
            self.assertIn('"event":"session.start"', plan["preLaunchActions"][0]["standardInput"])
            self.assertIn('"event":"agent.running"', plan["preLaunchActions"][1]["standardInput"])
            self.assertNotIn('"session"', plan["preLaunchActions"][0]["standardInput"])
            self.assertIn('"arguments":["--tui","--model","anthropic/claude-sonnet-4.6"]', plan["preLaunchActions"][0]["standardInput"])

    def test_hermes_profile_waits_for_turn_completion_hook(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["hermes"]

        self.assertEqual(profile.launch_args_by_scenario["session_capture"][:2], ["chat", "--query"])
        self.assertEqual(
            profile.expectations["session_capture"].required_events,
            ["session.start", "agent.running", "post-llm-call"],
        )

    def test_claude_plan_installs_tool_use_hooks_for_permission_sensitive_tools(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["claude"]
        with tempfile.TemporaryDirectory() as tmp:
            plan = agent_bench.LaunchPlanner(
                profile=profile,
                scenario="approval",
                run_dir=pathlib.Path(tmp),
                resources_dir=None,
            ).plan(
                {
                    "arguments": ["--print", "Run this exact shell command to print a harmless sentinel for an integration hook regression test: printf ZENTTY_AGENT_BENCH_APPROVAL_OK"],
                    "environment": {
                        "ZENTTY_REAL_BINARY": "/usr/local/bin/claude",
                        "ZENTTY_CLI_BIN": "/tmp/zentty",
                    },
                }
            )

        settings_index = plan["arguments"].index("--settings")
        settings = json.loads(plan["arguments"][settings_index + 1])
        pre_tool_use = settings["hooks"]["PreToolUse"]

        self.assertEqual(
            [entry["matcher"] for entry in pre_tool_use],
            ["AskUserQuestion", "Bash|Write|Edit|MultiEdit|NotebookEdit"],
        )


class AppPathResolutionTests(unittest.TestCase):
    def test_app_has_agent_bench_resources_requires_shared_launcher(self):
        with tempfile.TemporaryDirectory() as tmp:
            app_path = pathlib.Path(tmp) / "Zentty.app"

            self.assertFalse(agent_bench.app_has_agent_bench_resources(app_path))

            launcher = app_path / "Contents" / "Resources" / "bin" / "shared" / "zentty"
            launcher.parent.mkdir(parents=True)
            launcher.write_text("#!/bin/sh\n", encoding="utf-8")

            self.assertTrue(agent_bench.app_has_agent_bench_resources(app_path))

    def test_missing_agent_wrapper_resource_reports_absent_selected_wrapper(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["agy"]
        with tempfile.TemporaryDirectory() as tmp:
            app_path = pathlib.Path(tmp) / "Zentty.app"
            launcher = app_path / "Contents" / "Resources" / "bin" / "shared" / "zentty"
            launcher.parent.mkdir(parents=True)
            launcher.write_text("#!/bin/sh\n", encoding="utf-8")

            missing = agent_bench.missing_agent_wrapper_resource(app_path, profile)

        self.assertIn("missing agy wrapper directory", missing)

    def test_missing_agent_wrapper_resource_accepts_executable_selected_wrapper(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["agy"]
        with tempfile.TemporaryDirectory() as tmp:
            app_path = pathlib.Path(tmp) / "Zentty.app"
            launcher = app_path / "Contents" / "Resources" / "bin" / "shared" / "zentty"
            wrapper = app_path / "Contents" / "Resources" / "bin" / "agy" / "agy"
            launcher.parent.mkdir(parents=True)
            wrapper.parent.mkdir(parents=True)
            launcher.write_text("#!/bin/sh\n", encoding="utf-8")
            wrapper.write_text("#!/bin/sh\n", encoding="utf-8")
            wrapper.chmod(0o755)

            missing = agent_bench.missing_agent_wrapper_resource(app_path, profile)

        self.assertIsNone(missing)

    def test_no_build_resolver_skips_stale_build_debug_app_for_derived_data_app(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = pathlib.Path(tmp)
            stale_app = tmp_path / "build" / "Debug" / "Zentty.app"
            stale_app.mkdir(parents=True)
            derived_app = tmp_path / "DerivedData" / "Zentty.app"
            launcher = derived_app / "Contents" / "Resources" / "bin" / "shared" / "zentty"
            launcher.parent.mkdir(parents=True)
            launcher.write_text("#!/bin/sh\n", encoding="utf-8")
            args = type(
                "Args",
                (),
                {
                    "run_dir": tmp,
                    "app_path": None,
                    "no_build": True,
                    "timeout": 30,
                    "strict": False,
                    "agents": "codex",
                    "scenarios": "question",
                },
            )()
            old_repo_root = agent_bench.REPO_ROOT
            old_latest = agent_bench.latest_derived_data_zentty_app
            agent_bench.REPO_ROOT = tmp_path
            agent_bench.latest_derived_data_zentty_app = lambda: derived_app
            runner = agent_bench.BenchRunner(args)
            try:
                self.assertEqual(runner._resolve_app_path(), derived_app)
            finally:
                runner._cleanup_socket_dir()
                agent_bench.REPO_ROOT = old_repo_root
                agent_bench.latest_derived_data_zentty_app = old_latest


class EnvironmentTests(unittest.TestCase):
    def test_base_environment_drops_nested_zentty_codex_home(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = type(
                "Args",
                (),
                {
                    "run_dir": tmp,
                    "app_path": "/tmp/Zentty.app",
                    "no_build": True,
                    "timeout": 30,
                    "strict": False,
                    "agents": "codex",
                    "scenarios": "question",
                },
            )()
            old = os.environ.get("CODEX_HOME")
            os.environ["CODEX_HOME"] = "/Users/tester/Library/Caches/Zentty/ipc-1/launch/worklane/pane/codex/home"
            runner = agent_bench.BenchRunner(args)
            try:
                env = runner._base_environment(pathlib.Path("/tmp/Zentty.app/Contents/Resources"))
            finally:
                runner._cleanup_socket_dir()
                if old is None:
                    os.environ.pop("CODEX_HOME", None)
                else:
                    os.environ["CODEX_HOME"] = old

        self.assertNotIn("CODEX_HOME", env)

    def test_parse_build_settings_ignores_malformed_assignment_lines(self):
        values = agent_bench.parse_build_settings(
            """
                BUILT_PRODUCTS_DIR = /tmp/build
                 = malformed
                FULL_PRODUCT_NAME = Zentty.app
            """
        )

        self.assertEqual(values["BUILT_PRODUCTS_DIR"], "/tmp/build")
        self.assertEqual(values["FULL_PRODUCT_NAME"], "Zentty.app")

    def test_filters_inherited_zentty_wrapper_paths(self):
        inherited = os.pathsep.join(
            [
                "/Applications/Zentty.app/Contents/Resources/bin/claude",
                "/Users/tester/.local/bin",
                "/tmp/Zentty.app/Contents/Resources/bin/shared",
                "/usr/bin",
            ]
        )

        filtered = agent_bench.filtered_inherited_path(inherited)

        self.assertEqual(filtered, os.pathsep.join(["/Users/tester/.local/bin", "/usr/bin"]))

    def test_config_source_dir_ignores_nested_zentty_cache_home(self):
        source = agent_bench.config_source_dir(
            {
                "HOME": "/Users/tester",
                "CODEX_HOME": "/Users/tester/Library/Caches/Zentty/ipc-1/launch/worklane/pane/codex/home",
            },
            "CODEX_HOME",
            ".codex",
        )

        self.assertEqual(source, pathlib.Path("/Users/tester/.codex"))

    def test_config_source_dir_respects_non_cache_override(self):
        source = agent_bench.config_source_dir(
            {
                "HOME": "/Users/tester",
                "CODEX_HOME": "/tmp/custom-codex-home",
            },
            "CODEX_HOME",
            ".codex",
        )

        self.assertEqual(source, pathlib.Path("/tmp/custom-codex-home"))


class LaunchPlannerTests(unittest.TestCase):
    def test_codex_plan_installs_compact_hooks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            profile = agent_bench.AgentProfile(
                name="codex",
                command="codex",
                real_binary_names=["codex"],
                version_args=["--version"],
                launch_args_by_scenario={"manual_compact": []},
                expectations={"manual_compact": agent_bench.ScenarioExpectation("manual_compact", ["pre-compact"])},
            )
            plan = agent_bench.LaunchPlanner(
                profile=profile,
                scenario="manual_compact",
                run_dir=root / "run",
                resources_dir=None,
            ).plan(
                {
                    "arguments": [],
                    "environment": {
                        "ZENTTY_REAL_BINARY": "/usr/local/bin/codex",
                        "ZENTTY_CLI_BIN": "/tmp/zentty",
                    },
                }
            )

            config_arguments = [argument for argument in plan["arguments"] if argument.startswith("hooks.")]
            self.assertTrue(any(argument.startswith("hooks.PreCompact=") and "pre-compact" in argument for argument in config_arguments))
            self.assertTrue(any(argument.startswith("hooks.PostCompact=") and "post-compact" in argument for argument in config_arguments))
            state_argument = next(argument for argument in config_arguments if argument.startswith("hooks.state="))
            self.assertIn("pre_compact", state_argument)
            self.assertIn("post_compact", state_argument)

    def test_claude_plan_installs_compact_hooks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            profile = agent_bench.AgentProfile(
                name="claude",
                command="claude",
                real_binary_names=["claude"],
                version_args=["--version"],
                launch_args_by_scenario={"manual_compact": []},
                expectations={"manual_compact": agent_bench.ScenarioExpectation("manual_compact", ["PreCompact"])},
            )
            plan = agent_bench.LaunchPlanner(
                profile=profile,
                scenario="manual_compact",
                run_dir=root / "run",
                resources_dir=None,
            ).plan(
                {
                    "arguments": [],
                    "environment": {
                        "ZENTTY_REAL_BINARY": "/usr/local/bin/claude",
                        "ZENTTY_CLI_BIN": "/tmp/zentty",
                    },
                }
            )

            settings_index = plan["arguments"].index("--settings")
            settings = json.loads(plan["arguments"][settings_index + 1])
            self.assertIn("PreCompact", settings["hooks"])
            self.assertIn("PostCompact", settings["hooks"])

    def test_codex_plan_unsets_nested_zentty_codex_home(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            profile = agent_bench.AgentProfile(
                name="codex",
                command="codex",
                real_binary_names=["codex"],
                version_args=["--version"],
                launch_args_by_scenario={"smoke": []},
                expectations={"smoke": agent_bench.ScenarioExpectation("smoke", ["session-start"])},
            )
            plan = agent_bench.LaunchPlanner(
                profile=profile,
                scenario="smoke",
                run_dir=root / "run",
                resources_dir=None,
            ).plan(
                {
                    "arguments": [],
                    "environment": {
                        "ZENTTY_REAL_BINARY": "/usr/local/bin/codex",
                        "ZENTTY_CLI_BIN": "/tmp/zentty",
                        "HOME": "/Users/tester",
                        "CODEX_HOME": "/Users/tester/Library/Caches/Zentty/ipc-1/launch/worklane/pane/codex/home",
                    },
                }
            )

            self.assertIn("CODEX_HOME", plan["unsetEnvironment"])
            self.assertNotIn("CODEX_HOME", plan["setEnvironment"])

    def test_codex_plan_preserves_custom_codex_home(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            profile = agent_bench.AgentProfile(
                name="codex",
                command="codex",
                real_binary_names=["codex"],
                version_args=["--version"],
                launch_args_by_scenario={"smoke": []},
                expectations={"smoke": agent_bench.ScenarioExpectation("smoke", ["session-start"])},
            )
            plan = agent_bench.LaunchPlanner(
                profile=profile,
                scenario="smoke",
                run_dir=root / "run",
                resources_dir=None,
            ).plan(
                {
                    "arguments": [],
                    "environment": {
                        "ZENTTY_REAL_BINARY": "/usr/local/bin/codex",
                        "ZENTTY_CLI_BIN": "/tmp/zentty",
                        "HOME": "/Users/tester",
                        "CODEX_HOME": "/tmp/custom-codex-home",
                    },
                }
            )

            self.assertNotIn("CODEX_HOME", plan["unsetEnvironment"])

    def test_cursor_plan_writes_overlay_hooks_without_mutating_real_hooks_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            real_home = root / "real-home"
            real_hooks = real_home / ".cursor" / "hooks.json"
            real_hooks.parent.mkdir(parents=True)
            real_hooks.write_text('{"hooks":{"user":[{"command":"echo user"}]}}\n', encoding="utf-8")

            profile = agent_bench.AgentProfile(
                name="cursor",
                command="cursor-agent",
                real_binary_names=["cursor-agent"],
                version_args=["--version"],
                launch_args_by_scenario={"smoke": []},
                expectations={"smoke": agent_bench.ScenarioExpectation("smoke", ["sessionStart"])},
            )
            plan = agent_bench.LaunchPlanner(
                profile=profile,
                scenario="smoke",
                run_dir=root / "run",
                resources_dir=None,
            ).plan(
                {
                    "arguments": [],
                    "environment": {
                        "ZENTTY_REAL_BINARY": "/usr/local/bin/cursor-agent",
                        "ZENTTY_CLI_BIN": "/tmp/zentty",
                        "HOME": str(real_home),
                    },
                }
            )

            self.assertNotIn("HOME", plan["setEnvironment"])
            overlay_home = root / "run" / "overlays" / "smoke" / "cursor" / "home"
            overlay_config = pathlib.Path(plan["setEnvironment"]["CURSOR_CONFIG_DIR"])
            self.assertEqual(overlay_config, overlay_home / ".cursor")
            overlay_hooks = overlay_config / "hooks.json"

            self.assertTrue(overlay_hooks.exists())
            self.assertFalse(overlay_hooks.is_symlink())
            hooks = json.loads(overlay_hooks.read_text(encoding="utf-8"))["hooks"]
            for event in ("sessionStart", "sessionEnd", "beforeSubmitPrompt", "stop", "beforeShellExecution", "afterShellExecution"):
                self.assertIn(event, hooks)
            self.assertEqual(real_hooks.read_text(encoding="utf-8"), '{"hooks":{"user":[{"command":"echo user"}]}}\n')

    def test_copilot_plan_preserves_user_config_without_hooks_and_adds_managed_hooks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            real_home = root / "real-home"
            config = real_home / ".copilot" / "config.json"
            config.parent.mkdir(parents=True)
            config.write_text('{"theme":"dark"}\n', encoding="utf-8")

            profile = agent_bench.AgentProfile(
                name="copilot",
                command="copilot",
                real_binary_names=["copilot"],
                version_args=["--version"],
                launch_args_by_scenario={"smoke": []},
                expectations={"smoke": agent_bench.ScenarioExpectation("smoke", ["session-start"])},
            )
            plan = agent_bench.LaunchPlanner(
                profile=profile,
                scenario="smoke",
                run_dir=root / "run",
                resources_dir=None,
            ).plan(
                {
                    "arguments": [],
                    "environment": {
                        "ZENTTY_REAL_BINARY": "/usr/local/bin/copilot",
                        "ZENTTY_CLI_BIN": "/tmp/zentty",
                        "HOME": str(real_home),
                    },
                }
            )

            overlay_config = pathlib.Path(plan["setEnvironment"]["COPILOT_HOME"]) / "config.json"
            merged = json.loads(overlay_config.read_text(encoding="utf-8"))

            self.assertEqual(merged["theme"], "dark")
            for event in ("sessionStart", "sessionEnd", "userPromptSubmitted", "preToolUse", "postToolUse", "errorOccurred"):
                self.assertIn(event, merged["hooks"])

    def test_kimi_plan_preserves_user_model_config_when_overlaying_hooks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            real_home = root / "real-home"
            config = real_home / ".kimi" / "config.toml"
            config.parent.mkdir(parents=True)
            config.write_text('default_model = "moonshot/kimi-k2"\nhooks = []\n', encoding="utf-8")

            profile = agent_bench.AgentProfile(
                name="kimi",
                command="kimi",
                real_binary_names=["kimi"],
                version_args=["--version"],
                launch_args_by_scenario={"smoke": []},
                expectations={"smoke": agent_bench.ScenarioExpectation("smoke", ["SessionStart"])},
            )
            plan = agent_bench.LaunchPlanner(
                profile=profile,
                scenario="smoke",
                run_dir=root / "run",
                resources_dir=None,
            ).plan(
                {
                    "arguments": [],
                    "environment": {
                        "ZENTTY_REAL_BINARY": "/usr/local/bin/kimi",
                        "ZENTTY_CLI_BIN": "/tmp/zentty",
                        "HOME": str(real_home),
                    },
                }
            )

            overlay_config = pathlib.Path(plan["arguments"][plan["arguments"].index("--config-file") + 1])
            merged = overlay_config.read_text(encoding="utf-8")

            self.assertIn('default_model = "moonshot/kimi-k2"', merged)
            self.assertNotIn("hooks = []", merged)
            self.assertIn('[[hooks]]', merged)

    def test_opencode_approval_plan_forces_bash_permissions_to_ask(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            resources = root / "resources"
            plugin = resources / "opencode" / "plugins" / "zentty-opencode-zentty.js"
            plugin.parent.mkdir(parents=True)
            plugin.write_text("// plugin\n", encoding="utf-8")

            source = root / "source"
            source.mkdir()
            (source / "opencode.json").write_text('{"autoupdate":true}\n', encoding="utf-8")

            profile = agent_bench.AgentProfile(
                name="opencode",
                command="opencode",
                real_binary_names=["opencode"],
                version_args=["--version"],
                launch_args_by_scenario={"approval": []},
                expectations={"approval": agent_bench.ScenarioExpectation("approval", ["agent.needs-input"])},
            )
            plan = agent_bench.LaunchPlanner(
                profile=profile,
                scenario="approval",
                run_dir=root / "run",
                resources_dir=resources,
            ).plan(
                {
                    "arguments": [],
                    "environment": {
                        "ZENTTY_REAL_BINARY": "/usr/local/bin/opencode",
                        "ZENTTY_CLI_BIN": "/tmp/zentty",
                        "OPENCODE_CONFIG_DIR": str(source),
                    },
                }
            )

            overlay = pathlib.Path(plan["setEnvironment"]["OPENCODE_CONFIG_DIR"])
            merged = json.loads((overlay / "opencode.json").read_text(encoding="utf-8"))

            self.assertEqual(plan["setEnvironment"]["OPENCODE_CONFIG"], str(overlay / "opencode.json"))
            self.assertTrue(merged["autoupdate"])
            self.assertEqual(merged["permission"]["bash"], "ask")

    def test_amp_plan_installs_plugin_into_user_config_home(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            real_home = root / "real-home"
            real_plugin = real_home / ".config" / "amp" / "plugins" / "user.ts"
            real_plugin.parent.mkdir(parents=True)
            real_plugin.write_text("// user plugin\n", encoding="utf-8")
            real_marker = real_home / ".config" / "amp" / "settings.json"
            real_marker.write_text('{"amp.notifications.enabled":false}\n', encoding="utf-8")
            real_agents = real_home / ".config" / "amp" / "AGENTS.md"
            real_agents.write_text("personal amp guidance\n", encoding="utf-8")
            resources = root / "resources"
            plugin = resources / "amp" / "plugins" / "zentty-amp-zentty.ts"
            plugin.parent.mkdir(parents=True)
            plugin.write_text("// zentty plugin\n", encoding="utf-8")
            profile = agent_bench.AgentProfile(
                name="amp",
                command="amp",
                real_binary_names=["amp"],
                version_args=["--version"],
                launch_args_by_scenario={"smoke": []},
                expectations={"smoke": agent_bench.ScenarioExpectation("smoke", ["session.start"])},
            )

            plan = agent_bench.LaunchPlanner(
                profile=profile,
                scenario="smoke",
                run_dir=root / "run",
                resources_dir=resources,
            ).plan(
                {
                    "arguments": ["--mode", "smart", "hello"],
                    "environment": {
                        "ZENTTY_REAL_BINARY": "/usr/local/bin/amp",
                        "ZENTTY_CLI_BIN": "/tmp/zentty",
                        "HOME": str(real_home),
                    },
                }
            )

            self.assertNotIn("HOME", plan["setEnvironment"])
            self.assertNotIn("XDG_CONFIG_HOME", plan["setEnvironment"])
            self.assertNotIn("AMP_SETTINGS_FILE", plan["setEnvironment"])
            amp_config = real_home / ".config" / "amp"
            installed_plugin = amp_config / "plugins" / "zentty-amp-zentty.ts"
            self.assertTrue(installed_plugin.exists())
            user_plugin = amp_config / "plugins" / "user.ts"
            self.assertFalse(user_plugin.is_symlink())
            self.assertEqual(user_plugin.resolve(), real_plugin.resolve())
            settings = amp_config / "settings.json"
            self.assertFalse(settings.is_symlink())
            self.assertEqual(settings.resolve(), real_marker.resolve())
            agents = amp_config / "AGENTS.md"
            self.assertFalse(agents.is_symlink())
            self.assertEqual(agents.resolve(), real_agents.resolve())
            self.assertEqual(real_plugin.read_text(encoding="utf-8"), "// user plugin\n")
            self.assertEqual(plan["setEnvironment"]["ZENTTY_AGENT_TOOL"], "amp")
            self.assertEqual(plan["setEnvironment"]["PLUGINS"], "all")
            self.assertEqual(plan["setEnvironment"]["ZENTTY_AMP_RESUME_ARGUMENTS_JSON"], '["--mode","smart"]')
            self.assertEqual([action["standardInput"] for action in plan["preLaunchActions"]], [
                '{"version":1,"event":"session.start","agent":{"name":"Amp","pid":"__ZENTTY_SELF_PID__"},"context":{"launch":{"arguments":["--mode","smart"]}}}',
                '{"version":1,"event":"agent.running","agent":{"name":"Amp","pid":"__ZENTTY_SELF_PID__"},"context":{"launch":{"arguments":["--mode","smart"]}}}',
            ])

    def test_amp_plan_refuses_to_overwrite_unmarked_plugin(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            home = root / "home"
            existing_plugin = home / ".config" / "amp" / "plugins" / "zentty-amp-zentty.ts"
            existing_plugin.parent.mkdir(parents=True)
            existing_plugin.write_text("// user-owned file\n", encoding="utf-8")
            resources = root / "resources"
            plugin = resources / "amp" / "plugins" / "zentty-amp-zentty.ts"
            plugin.parent.mkdir(parents=True)
            plugin.write_text("// zentty-amp-plugin-v1\n", encoding="utf-8")
            profile = agent_bench.AgentProfile(
                name="amp",
                command="amp",
                real_binary_names=["amp"],
                version_args=["--version"],
                launch_args_by_scenario={"smoke": []},
                expectations={"smoke": agent_bench.ScenarioExpectation("smoke", ["session.start"])},
            )

            plan = agent_bench.LaunchPlanner(
                profile=profile,
                scenario="smoke",
                run_dir=root / "run",
                resources_dir=resources,
            ).plan(
                {
                    "arguments": ["hello"],
                    "environment": {
                        "ZENTTY_REAL_BINARY": "/usr/local/bin/amp",
                        "HOME": str(home),
                    },
                }
            )

            self.assertEqual(existing_plugin.read_text(encoding="utf-8"), "// user-owned file\n")
            self.assertNotIn("PLUGINS", plan["setEnvironment"])

    def test_amp_resume_argument_sanitizer_rejects_execute_with_value(self):
        self.assertEqual(agent_bench.sanitized_amp_resume_arguments(["--execute=echo hi"]), [])

    def test_timeout_with_skip_pattern_is_classified_as_prerequisite_skip(self):
        result = agent_bench.classify_timeout_result(
            agent="gemini",
            scenario="smoke",
            expectation=agent_bench.ScenarioExpectation("smoke", ["SessionStart"]),
            records=[],
            terminal_observations=[],
            output="Gemini CLI is not running in a trusted directory",
            skip_patterns=["not running in a trusted directory"],
            timeout=120,
            strict=False,
        )

        self.assertEqual(result.status, "skip")
        self.assertEqual(result.detail, "auth or provider prerequisite not available")


if __name__ == "__main__":
    unittest.main()
