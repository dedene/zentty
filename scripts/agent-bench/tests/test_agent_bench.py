import importlib.util
import json
import os
import pathlib
import socket
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("agent_bench", ROOT / "agent_bench.py")
agent_bench = importlib.util.module_from_spec(SPEC)
sys.modules["agent_bench"] = agent_bench
SPEC.loader.exec_module(agent_bench)


def _write_kimi_session_index(
    source_home: pathlib.Path,
    *,
    session_id: str,
    session_dir: str,
    work_dir: str = "/tmp/project",
) -> pathlib.Path:
    index_path = source_home / "session_index.jsonl"
    index_path.write_text(
        json.dumps(
            {
                "sessionId": session_id,
                "sessionDir": session_dir,
                "workDir": work_dir,
            }
        )
        + "\n",
        encoding="utf-8",
    )
    return index_path


def _modern_kimi_launch_planner(run_dir: pathlib.Path) -> agent_bench.LaunchPlanner:
    return agent_bench.LaunchPlanner(
        profile=agent_bench.AgentProfile(
            name="kimi-code",
            tool="kimi",
            command="kimi",
            real_binary_names=["kimi"],
            version_args=["--version"],
            launch_args_by_scenario={},
            expectations={},
            kimi_variant="modern",
        ),
        scenario="smoke",
        run_dir=run_dir,
        resources_dir=None,
    )


class RedactionTests(unittest.TestCase):
    def test_redacts_secret_values_and_keeps_routing_context(self):
        env = {
            "ZENTTY_INSTANCE_SOCKET": "/tmp/zentty.sock",
            "ZENTTY_PANE_ID": "pane-1",
            "ZENTTY_WORKLANE_ID": "worklane-1",
            "ZENTTY_HERMES_PID": "4242",
            "ZENTTY_PANE_TOKEN": "pane-secret",
            "OPENAI_API_KEY": "sk-secret",
            "PATH": "/usr/bin",
        }

        redacted = agent_bench.redacted_environment(env)

        self.assertEqual(redacted["ZENTTY_INSTANCE_SOCKET"], "/tmp/zentty.sock")
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

    def test_agent_inference_ignores_removed_bench_scoping_env(self):
        agent = agent_bench.agent_from_adapter(
            adapter="kimi",
            environment={"ZENTTY_AGENT_BENCH_AGENT": "kimi-code"},
            standard_input=None,
        )

        self.assertEqual(agent, "kimi")


class SyntheticScenarioTests(unittest.TestCase):
    def test_load_profiles_parses_tool_and_kimi_variant_fields(self):
        profiles = agent_bench.load_profiles(ROOT / "profiles")

        self.assertEqual(profiles["codex"].tool, "codex")
        self.assertIsNone(profiles["codex"].kimi_variant)
        self.assertEqual(profiles["kimi"].tool, "kimi")
        self.assertEqual(profiles["kimi"].kimi_variant, "legacy")
        self.assertEqual(profiles["kimi-code"].tool, "kimi")
        self.assertEqual(profiles["kimi-code"].kimi_variant, "modern")
        self.assertEqual(profiles["opencode"].opencode_generation, "v1")
        self.assertEqual(profiles["opencode-v2"].tool, "opencode")
        self.assertEqual(profiles["opencode-v2"].opencode_generation, "v2")
        self.assertNotIn("tasks", profiles["opencode-v2"].launch_args_by_scenario)

    def test_parse_opencode_generation_reads_v1_and_styled_v2_versions(self):
        self.assertEqual(agent_bench.parse_opencode_generation("1.18.35\n"), "v1")
        self.assertEqual(agent_bench.parse_opencode_generation("\x1b[1mopencode\x1b[0m v2.0.26\n"), "v2")
        self.assertIsNone(agent_bench.parse_opencode_generation("Error: postinstall script was not run"))

    def test_opencode_standalone_arguments_mirror_bootstrap(self):
        cases = [
            ([], ["--standalone"]),
            (["run", "hi"], ["run", "--standalone", "hi"]),
            (["--session", "ses_x"], ["--standalone", "--session", "ses_x"]),
            (["--prompt", "run"], ["--standalone", "--prompt", "run"]),
            (["mini"], ["mini", "--standalone"]),
            (["auth", "login"], ["auth", "login"]),
            (["--server", "http://127.0.0.1:1"], ["--server", "http://127.0.0.1:1"]),
            (["run", "--standalone", "hi"], ["run", "--standalone", "hi"]),
            (["--version"], ["--version"]),
        ]
        for arguments, expected in cases:
            self.assertEqual(agent_bench.opencode_standalone_arguments(arguments), expected, arguments)

    def test_resolve_agent_binary_picks_pinned_opencode_generation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            first = root / "first"
            second = root / "second"
            first.mkdir()
            second.mkdir()
            v1 = first / "opencode"
            v2 = second / "opencode"
            for binary in (v1, v2):
                binary.write_text("#!/bin/sh\n", encoding="utf-8")
                binary.chmod(0o755)
            profiles = agent_bench.load_profiles(ROOT / "profiles")
            path_value = os.pathsep.join([str(first), str(second)])
            probe = lambda path: "v2" if pathlib.Path(path) == v2 else "v1"

            resolved_v2, skip_v2 = agent_bench.resolve_agent_binary(profiles["opencode-v2"], path_value, variant_probe=probe)
            resolved_v1, _ = agent_bench.resolve_agent_binary(profiles["opencode"], path_value, variant_probe=probe)
            missing, skip = agent_bench.resolve_agent_binary(profiles["opencode-v2"], str(first), variant_probe=probe)

        self.assertEqual(resolved_v2, str(v2))
        self.assertIsNone(skip_v2)
        self.assertEqual(resolved_v1, str(v1))
        self.assertIsNone(missing)
        self.assertEqual(skip, "no opencode v2 binary found")

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
        # /compact on the empty home screen has no session to compact, and an
        # Enter sent in the same write is swallowed by the autocomplete popup:
        # seed a session first, then type the command and submit separately.
        for name in ("opencode", "opencode-v2"):
            texts = [step["text"] for step in profiles[name].input_by_scenario["manual_compact"]]
            self.assertEqual(texts, ["Reply with the single word OK\r", "/compact", "\r"], name)

    def test_cursor_profile_defines_session_capture_restore_and_interactive_completion(self):
        profile_dir = ROOT / "profiles"
        profiles = agent_bench.load_profiles(profile_dir)
        cursor = profiles["cursor"]

        self.assertIn("session_capture", cursor.expectations)
        self.assertIn("restore_launch", cursor.expectations)
        self.assertIn("interactive_turn_complete", cursor.expectations)
        self.assertIn("subagents", cursor.expectations)
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
        self.assertTrue(cursor.expectations["subagents"].synthetic)
        self.assertEqual(
            cursor.expectations["subagents"].fixture,
            "cursor_subagent_lifecycle.jsonl",
        )
        self.assertEqual(
            cursor.expectations["subagents"].required_events,
            ["sessionStart", "subagentStart", "subagentStop", "stop"],
        )

    def test_ensure_claude_workspace_trust_marks_repo_and_prunes_stale_bench_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            config = root / ".claude.json"
            repo = root / "run" / "repos" / "claude-approval"
            repo.mkdir(parents=True)
            stale = str(root / "old-run" / "repos" / "claude-smoke")
            config.write_text(
                json.dumps(
                    {
                        "projects": {
                            "/Users/someone/project": {"hasTrustDialogAccepted": True, "lastCost": 1},
                            stale: {"hasTrustDialogAccepted": True},
                        },
                        "other": "kept",
                    }
                ),
                encoding="utf-8",
            )

            self.assertTrue(agent_bench.ensure_claude_workspace_trust(repo, config_path=config))
            written = json.loads(config.read_text(encoding="utf-8"))
            self.assertEqual(written["other"], "kept")
            self.assertEqual(written["projects"]["/Users/someone/project"], {"hasTrustDialogAccepted": True, "lastCost": 1})
            self.assertNotIn(stale, written["projects"])
            self.assertTrue(written["projects"][str(repo)]["hasTrustDialogAccepted"])
            # Second call is a no-op.
            self.assertFalse(agent_bench.ensure_claude_workspace_trust(repo, config_path=config))

    def test_ensure_claude_workspace_trust_creates_config_when_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            config = root / ".claude.json"
            repo = root / "repos" / "claude-smoke"
            repo.mkdir(parents=True)
            self.assertTrue(agent_bench.ensure_claude_workspace_trust(repo, config_path=config))
            written = json.loads(config.read_text(encoding="utf-8"))
            self.assertTrue(written["projects"][str(repo)]["hasTrustDialogAccepted"])

    def test_claude_plan_mirrors_app_hook_set_including_post_tool_use(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            plan = agent_bench.LaunchPlanner(
                profile=agent_bench.load_profiles(ROOT / "profiles")["claude"],
                scenario="approval_then_work",
                run_dir=root,
                resources_dir=None,
            ).plan(
                {
                    "arguments": ["hello"],
                    "environment": {"ZENTTY_REAL_BINARY": "/usr/local/bin/claude", "ZENTTY_CLI_BIN": "/tmp/zentty-bench"},
                }
            )
            arguments = plan["arguments"]
            hooks = json.loads(arguments[arguments.index("--settings") + 1])["hooks"]
            for event in ("PostToolUse", "PostToolUseFailure"):
                self.assertEqual([entry["matcher"] for entry in hooks[event]], [""], event)
            self.assertEqual(
                [entry["matcher"] for entry in hooks["PreToolUse"]],
                ["AskUserQuestion", "Bash|Write|Edit|MultiEdit|NotebookEdit"],
            )
            # Mirror of AgentLaunchBootstrap.claudePlan: the sidebar subagent
            # badge depends on these two hooks being registered per launch.
            for event in ("SubagentStart", "SubagentStop"):
                self.assertEqual([entry["matcher"] for entry in hooks[event]], [""], event)

    def test_claude_plan_pins_swift_hook_plan_events_matchers_and_timeouts(self):
        # Fixture transcribed from AgentLaunchBootstrap.claudePlan
        # (Zentty/AppState/Agent/AgentLaunchBootstrap.swift, the `settingsJSON`
        # literal around line 828, plus claudeSessionStartHookEntries /
        # claudeHookEntries / claudePreToolUseHookEntries). When the two
        # disagree, the Swift plan wins: update this fixture and _plan_claude.
        command = '"/tmp/zentty-bench" ipc agent-event --adapter=claude'

        def entries(matchers, timeout):
            return [{"matcher": matcher, "hooks": [{"type": "command", "command": command, "timeout": timeout}]} for matcher in matchers]

        swift_plan = {
            "SessionStart": entries(["startup", "resume", "clear", "compact"], 10),
            "Stop": entries([""], 10),
            "SessionEnd": entries([""], 1),
            "Notification": entries([""], 10),
            "PermissionRequest": entries([""], 10),
            "UserPromptSubmit": entries([""], 10),
            "PreToolUse": entries(["AskUserQuestion", "Bash|Write|Edit|MultiEdit|NotebookEdit"], 5),
            "PostToolUse": entries([""], 5),
            "PostToolUseFailure": entries([""], 5),
            "PreCompact": entries([""], 10),
            "PostCompact": entries([""], 10),
            "TaskCreated": entries([""], 5),
            "TaskCompleted": entries([""], 5),
            "SubagentStart": entries([""], 5),
            "SubagentStop": entries([""], 5),
        }
        with tempfile.TemporaryDirectory() as tmp:
            plan = agent_bench.LaunchPlanner(
                profile=agent_bench.load_profiles(ROOT / "profiles")["claude"],
                scenario="smoke",
                run_dir=pathlib.Path(tmp),
                resources_dir=None,
            ).plan(
                {
                    "arguments": ["hello"],
                    "environment": {"ZENTTY_REAL_BINARY": "/usr/local/bin/claude", "ZENTTY_CLI_BIN": "/tmp/zentty-bench"},
                }
            )
            arguments = plan["arguments"]
            settings = json.loads(arguments[arguments.index("--settings") + 1])
        self.assertEqual(settings, {"hooks": swift_plan})

    def test_claude_hook_command_carries_launch_routing(self):
        # Transcribed from AgentLaunchBootstrap.claudeHookCommand; the Swift
        # side wins when the two disagree.
        command = agent_bench.claude_hook_command(
            "/tmp/zentty-bench",
            {
                "ZENTTY_INSTANCE_SOCKET": "/tmp/run/zentty.sock",
                "ZENTTY_WORKLANE_ID": "wl-1",
                "ZENTTY_PANE_ID": "pane-b",
                "ZENTTY_PANE_TOKEN": "token-b",
            },
        )
        self.assertEqual(
            command,
            "/usr/bin/env -u ZENTTY_INSTANCE_ID -u ZENTTY_WINDOW_ID"
            ' ZENTTY_INSTANCE_SOCKET="/tmp/run/zentty.sock" ZENTTY_WORKLANE_ID="wl-1"'
            ' ZENTTY_PANE_ID="pane-b" ZENTTY_PANE_TOKEN="token-b"'
            ' "/tmp/zentty-bench" ipc agent-event --adapter=claude',
        )

    def test_claude_background_routing_scenario_is_declared(self):
        profile = agent_bench.load_profiles(agent_bench.BENCH_ROOT / "profiles")["claude"]
        self.assertTrue(profile.expectations["background_routing"].daemon_pane_routing)
        self.assertIn("--bg", profile.launch_args_by_scenario["background_routing"])

    def test_parse_claude_daemon_pids_matches_only_daemon_processes(self):
        ps_output = "\n".join(
            [
                "  101 /Users/me/.local/bin/claude daemon run --origin transient",
                "  102 claude bg-pty-host --bg-pty-host /tmp/x.pty.sock 200 50",
                "  103 claude bg-spare --bg-spare /tmp/x.claim.sock",
                "  104 /Users/me/.local/bin/claude --session-id abc",
                "  105 /Applications/Claude.app/Contents/MacOS/Claude",
                "  106 vim claude daemon run notes.md",
            ]
        )
        self.assertEqual(agent_bench.parse_claude_daemon_pids(ps_output), {101, 102, 103})

    def test_backgrounded_session_ids_reads_ansi_coloured_output(self):
        output = "backgrounded \u00b7 \x1b[36m6e811ae4\x1b[39m\r\n  claude attach 6e811ae4\r\n"
        self.assertEqual(agent_bench.backgrounded_session_ids(output), ["6e811ae4"])

    def test_daemon_routing_violations_flags_the_daemon_starters_identity(self):
        def hook(event, pane, worklane="wl-b", pid=None):
            environment = {"ZENTTY_PANE_ID": pane, "ZENTTY_WORKLANE_ID": worklane}
            if pid:
                environment["ZENTTY_CLAUDE_PID"] = pid
            return agent_bench.TraceRecord(kind="hook", event_name=event, environment=environment)

        def violations(records):
            return agent_bench.daemon_routing_violations(
                records, expected_pane="pane-b", expected_worklane="wl-b", starter_claude_pid="999999"
            )

        self.assertEqual(violations([hook("SessionStart", "pane-b"), hook("Stop", "pane-b")]), [])
        self.assertEqual(violations([]), ["no hook events captured"])
        self.assertEqual(
            violations([hook("SessionStart", "pane-a")]),
            ["SessionStart routed to pane 'pane-a', expected 'pane-b'"],
        )
        self.assertEqual(
            violations([hook("Stop", "pane-b", worklane="wl-a")]),
            ["Stop routed to worklane 'wl-a', expected 'wl-b'"],
        )
        self.assertEqual(
            violations([hook("Stop", "pane-b", pid="999999")]),
            ["Stop kept the daemon starter's ZENTTY_CLAUDE_PID"],
        )

    def test_claude_attach_plan_launches_as_given_and_announces_the_session(self):
        # Transcribed from AgentLaunchBootstrap.claudeAttachPlan.
        with tempfile.TemporaryDirectory() as tmp:
            planner = agent_bench.LaunchPlanner(
                profile=agent_bench.load_profiles(ROOT / "profiles")["claude"],
                scenario="background_routing",
                run_dir=pathlib.Path(tmp),
                resources_dir=None,
            )

            def plan(arguments):
                return planner.plan(
                    {
                        "arguments": arguments,
                        "environment": {"ZENTTY_REAL_BINARY": "/usr/local/bin/claude", "ZENTTY_CLI_BIN": "/tmp/zentty-bench"},
                    }
                )

            attached = plan(["attach", "6E811AE4"])
            self.assertEqual(attached["arguments"], ["attach", "6E811AE4"])
            self.assertEqual(
                attached["preLaunchActions"],
                [
                    {
                        "subcommand": "agent-event",
                        "arguments": ["--adapter=claude"],
                        "standardInput": '{"hook_event_name":"ZenttyAttach","session_id":"6e811ae4"}',
                    }
                ],
            )
            self.assertEqual(plan(["attach"])["preLaunchActions"], [])
            self.assertEqual(plan(["attach", "--help"])["preLaunchActions"], [])

    def test_attach_announcement_violations_checks_pane_session_and_pid(self):
        def announcement(pane="pane-c", session="6e811ae4", pid="4242"):
            environment = {"ZENTTY_PANE_ID": pane, "ZENTTY_WORKLANE_ID": "wl-c"}
            if pid:
                environment["ZENTTY_CLAUDE_PID"] = pid
            return agent_bench.TraceRecord(
                kind="hook",
                event_name="ZenttyAttach",
                standard_input=json.dumps({"hook_event_name": "ZenttyAttach", "session_id": session}),
                environment=environment,
            )

        def violations(records):
            return agent_bench.attach_announcement_violations(
                records, session_id="6e811ae4", expected_pane="pane-c", expected_worklane="wl-c"
            )

        self.assertEqual(violations([announcement()]), [])
        self.assertEqual(violations([]), ["expected one ZenttyAttach from `claude attach`, captured 0"])
        self.assertEqual(violations([announcement(pane="pane-a")]), ["ZenttyAttach came from pane 'pane-a', expected 'pane-c'"])
        self.assertEqual(violations([announcement(session="deadbeef")]), ["ZenttyAttach did not name session 6e811ae4"])
        self.assertEqual(violations([announcement(pid=None)]), ["ZenttyAttach carried no attach client pid"])
        # The announcement comes from the attaching pane by design.
        self.assertEqual(
            agent_bench.daemon_routing_violations(
                [
                    agent_bench.TraceRecord(
                        kind="hook", event_name="Stop", environment={"ZENTTY_PANE_ID": "pane-b", "ZENTTY_WORKLANE_ID": "wl-b"}
                    ),
                    announcement(),
                ],
                expected_pane="pane-b",
                expected_worklane="wl-b",
                starter_claude_pid="999999",
            ),
            [],
        )

    def test_codex_plan_registers_and_trusts_subagent_hooks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            plan = agent_bench.LaunchPlanner(
                profile=agent_bench.load_profiles(ROOT / "profiles")["codex"],
                scenario="subagents",
                run_dir=root,
                resources_dir=None,
            ).plan(
                {
                    "arguments": ["exec", "hello"],
                    "environment": {"ZENTTY_REAL_BINARY": "/usr/local/bin/codex", "ZENTTY_CLI_BIN": "/tmp/zentty-bench"},
                }
            )
            arguments = plan["arguments"]
            self.assertTrue(any(arg.startswith("hooks.SubagentStart=") and "subagent-start" in arg for arg in arguments))
            self.assertTrue(any(arg.startswith("hooks.SubagentStop=") and "subagent-stop" in arg for arg in arguments))
            state = next(arg for arg in arguments if arg.startswith("hooks.state="))
            self.assertIn("config.toml:subagent_start:0:0", state)
            self.assertIn("config.toml:subagent_stop:0:0", state)

    def test_subagent_profiles_require_start_stop_pair_and_payload(self):
        profiles = agent_bench.load_profiles(ROOT / "profiles")
        for name, start, stop in (("claude", "SubagentStart", "SubagentStop"), ("codex", "subagent-start", "subagent-stop"), ("grok", "subagent_start", "subagent_stop")):
            expectation = profiles[name].expectations["subagents"]
            self.assertIn(start, expectation.required_events, name)
            self.assertIn(stop, expectation.required_events, name)
            self.assertTrue(expectation.subagent_payload_required, name)
            self.assertIn("subagents", profiles[name].launch_args_by_scenario, name)

    def test_subagent_trace_extra_resolves_claude_model_from_meta_sidecar(self):
        with tempfile.TemporaryDirectory() as tmp:
            transcript = pathlib.Path(tmp) / "agent-abc.jsonl"
            (pathlib.Path(tmp) / "agent-abc.meta.json").write_text(json.dumps({"agentType": "Explore", "model": "opus"}))
            payload = json.dumps({"hook_event_name": "SubagentStart", "agent_id": "abc", "agent_type": "Explore", "agent_transcript_path": str(transcript)})
            extra = agent_bench.subagent_trace_extra("claude", "SubagentStart", payload)
            self.assertEqual(extra["subagent"]["event"], "start")
            self.assertEqual(extra["subagent"]["agent_type"], "Explore")
            self.assertEqual(extra["subagent"]["model"], "opus")

            transcript.write_text('{"type":"assistant","message":{"model":"claude-sonnet-5"}}\n')
            (pathlib.Path(tmp) / "agent-abc.meta.json").unlink()
            extra = agent_bench.subagent_trace_extra("claude", None, json.dumps({"hook_event_name": "SubagentStop", "agent_id": "abc", "agent_transcript_path": str(transcript)}))
            self.assertEqual(extra["subagent"]["event"], "stop")
            self.assertEqual(extra["subagent"]["model"], "claude-sonnet-5")

    def test_subagent_trace_extra_resolves_codex_model_and_nickname_from_rollout(self):
        with tempfile.TemporaryDirectory() as tmp:
            rollout = pathlib.Path(tmp) / "rollout-x.jsonl"
            rollout.write_text(
                json.dumps({"type": "session_meta", "payload": {"source": {"subagent": {"thread_spawn": {"agent_nickname": "Dirac", "agent_role": "worker"}}}}})
                + "\n"
                + json.dumps({"type": "turn_context", "payload": {"model": "gpt-6-astra"}})
                + "\n"
            )
            extra = agent_bench.subagent_trace_extra("codex", "subagent-start", json.dumps({"agent_type": "worker", "agent_transcript_path": str(rollout)}))
            self.assertEqual(extra["subagent"]["model"], "gpt-6-astra")
            self.assertEqual(extra["subagent"]["nickname"], "Dirac")
            self.assertIsNone(agent_bench.subagent_trace_extra("codex", "pre-tool-use", "{}"))

    def test_subagent_trace_extra_devin_sidekick_tool(self):
        pre = json.dumps(
            {
                "hook_event_name": "PreToolUse",
                "tool_name": "sidekick",
                "tool_use_id": "toolu_01",
                "tool_input": {"message": "list files"},
            }
        )
        extra = agent_bench.subagent_trace_extra("devin", "PreToolUse", pre)
        self.assertEqual(extra["subagent"]["event"], "start")
        self.assertEqual(extra["subagent"]["agent_type"], "sidekick")
        self.assertEqual(extra["subagent"]["nickname"], "Sidekick")
        self.assertEqual(extra["subagent"]["agent_id"], "toolu_01")

        post = json.dumps(
            {
                "hook_event_name": "PostToolUse",
                "tool_name": "sidekick",
                "tool_use_id": "toolu_01",
                "tool_input": {"message": "list files", "block": False},
                "tool_response": {"output": "Sidekick handoff started (agent_id=sidekick)."},
            }
        )
        extra = agent_bench.subagent_trace_extra("devin", "PostToolUse", post)
        self.assertEqual(extra["subagent"]["event"], "stop")
        self.assertEqual(extra["subagent"]["run_agent_id"], "sidekick")

    def test_subagent_payload_validation_explains_what_is_missing(self):
        self.assertEqual(agent_bench.missing_subagent_payload_detail([]), "no SubagentStart hook payload was captured")
        self.assertEqual(
            agent_bench.missing_subagent_payload_detail([{"event": "start", "agent_type": "Explore"}]),
            "SubagentStart captured but no SubagentStop followed",
        )
        self.assertEqual(
            agent_bench.missing_subagent_payload_detail([{"event": "start"}, {"event": "stop"}]),
            "subagent hooks captured but none named an agent type",
        )
        self.assertIsNone(
            agent_bench.missing_subagent_payload_detail(
                [{"event": "start", "agent_type": "Explore"}, {"event": "stop", "model": "claude-opus-5"}]
            )
        )
        # Grok names the subagent type but has no transcript sidecar for the model.
        without_model = [{"event": "start", "agent_type": "general-purpose"}, {"event": "stop"}]
        self.assertIsNotNone(agent_bench.missing_subagent_payload_detail(without_model))
        self.assertIsNone(agent_bench.missing_subagent_payload_detail(without_model, model_required=False))
        self.assertFalse(agent_bench.load_profiles(ROOT / "profiles")["grok"].expectations["subagents"].subagent_model_required)

    def test_claude_async_and_nested_subagent_profiles_pin_upstream_contract(self):
        claude = agent_bench.load_profiles(ROOT / "profiles")["claude"]
        base_flags = claude.launch_args_by_scenario["subagents"][:-1]
        async_expectation = claude.expectations["subagents_async"]
        self.assertEqual(async_expectation.event_order, [["Stop", "SubagentStop"]])
        self.assertTrue(async_expectation.subagent_payload_required)
        self.assertFalse(async_expectation.subagent_nested_required)
        for event in ("SubagentStart", "Stop", "SubagentStop"):
            self.assertIn(event, async_expectation.required_events)
        self.assertEqual(claude.launch_args_by_scenario["subagents_async"][:-1], base_flags)
        self.assertIn("run_in_background", claude.launch_args_by_scenario["subagents_async"][-1])

        nested_expectation = claude.expectations["subagents_nested"]
        self.assertTrue(nested_expectation.subagent_nested_required)
        self.assertTrue(nested_expectation.subagent_payload_required)
        self.assertEqual(nested_expectation.event_order, [])
        # Two starts and two stops are required so the completion predicate
        # keeps the process alive until the nested pair has reported.
        self.assertEqual(nested_expectation.required_events.count("SubagentStart"), 2)
        self.assertEqual(nested_expectation.required_events.count("SubagentStop"), 2)
        self.assertEqual(claude.launch_args_by_scenario["subagents_nested"][:-1], base_flags)
        # Defaults stay off for scenarios that do not opt in.
        self.assertEqual(claude.expectations["subagents"].event_order, [])
        self.assertFalse(claude.expectations["subagents"].subagent_nested_required)

    def test_event_order_passes_when_stop_precedes_subagent_stop(self):
        expectation = agent_bench.ScenarioExpectation(
            name="subagents_async",
            required_events=["SessionStart", "SubagentStart", "Stop", "SubagentStop"],
            event_order=[["Stop", "SubagentStop"]],
        )
        records = [
            agent_bench.TraceRecord(kind="hook", agent="claude", scenario="subagents_async", event_name=event)
            for event in ("SessionStart", "UserPromptSubmit", "SubagentStart", "Stop", "SubagentStop", "Stop")
        ]
        self.assertIsNone(agent_bench.event_order_violation_detail("claude", "subagents_async", expectation, records))
        result = agent_bench.classify_completed_result(
            agent="claude",
            scenario="subagents_async",
            expectation=expectation,
            records=records,
            terminal_observations=[],
            output="DONE",
            skip_patterns=[],
            exit_code=0,
            completed_by_predicate=True,
            strict=True,
        )
        self.assertTrue(result.passed)
        self.assertEqual(result.result_kind, "hook-pass")

    def test_event_order_fails_when_subagent_stops_before_parent_stop(self):
        expectation = agent_bench.ScenarioExpectation(
            name="subagents_async",
            required_events=["SessionStart", "SubagentStart", "Stop", "SubagentStop"],
            event_order=[["Stop", "SubagentStop"]],
        )
        records = [
            agent_bench.TraceRecord(kind="hook", agent="claude", scenario="subagents_async", event_name=event)
            for event in ("SessionStart", "SubagentStart", "SubagentStop", "Stop")
        ]
        detail = agent_bench.event_order_violation_detail("claude", "subagents_async", expectation, records)
        self.assertEqual(detail, "expected Stop before SubagentStop but observed order was: SessionStart, SubagentStart, SubagentStop, Stop")
        result = agent_bench.classify_completed_result(
            agent="claude",
            scenario="subagents_async",
            expectation=expectation,
            records=records,
            terminal_observations=[],
            output="DONE",
            skip_patterns=[],
            exit_code=0,
            completed_by_predicate=True,
            strict=True,
        )
        self.assertFalse(result.passed)
        self.assertEqual(result.result_kind, "hook-order")
        self.assertEqual(result.detail, detail)
        # The timeout path applies the same contract.
        timeout_result = agent_bench.classify_timeout_result(
            agent="claude",
            scenario="subagents_async",
            expectation=expectation,
            records=records,
            terminal_observations=[],
            output="",
            skip_patterns=[],
            timeout=30,
            strict=True,
        )
        self.assertFalse(timeout_result.passed)
        self.assertEqual(timeout_result.result_kind, "hook-order")

    def test_event_order_ignores_records_from_other_scenarios_and_names_missing_events(self):
        expectation = agent_bench.ScenarioExpectation(name="subagents_async", required_events=[], event_order=[["Stop", "SubagentStop"]])
        records = [
            agent_bench.TraceRecord(kind="hook", agent="claude", scenario="subagents", event_name="Stop"),
            agent_bench.TraceRecord(kind="hook", agent="claude", scenario="subagents_async", event_name="SubagentStop"),
        ]
        self.assertEqual(
            agent_bench.event_order_violation_detail("claude", "subagents_async", expectation, records),
            "expected Stop before SubagentStop but Stop was never observed",
        )

    @staticmethod
    def _load_profile_with_event_order(event_order):
        with tempfile.TemporaryDirectory() as tmp:
            profile_path = pathlib.Path(tmp) / "fake.json"
            profile_path.write_text(
                json.dumps(
                    {
                        "name": "fake",
                        "command": "fake",
                        "expectations": {"ordered": {"required_events": [], "event_order": event_order}},
                    }
                ),
                encoding="utf-8",
            )
            return agent_bench.load_profiles(pathlib.Path(tmp))["fake"]

    def test_load_profiles_accepts_well_formed_event_order_pairs(self):
        profile = self._load_profile_with_event_order([["Stop", "SubagentStop"]])
        self.assertEqual(profile.expectations["ordered"].event_order, [["Stop", "SubagentStop"]])

    def test_load_profiles_rejects_flat_event_order_list_naming_the_scenario(self):
        with self.assertRaises(ValueError) as raised:
            self._load_profile_with_event_order(["Stop", "SubagentStop"])
        self.assertIn("fake.json scenario 'ordered'", str(raised.exception))
        self.assertIn("'Stop'", str(raised.exception))

    def test_load_profiles_rejects_event_order_entry_with_non_string_or_wrong_arity(self):
        for bad_entry in (["Stop", 5], ["Stop"], ["Stop", ""], ["Stop", "SubagentStop", "Stop"]):
            with self.subTest(entry=bad_entry), self.assertRaises(ValueError) as raised:
                self._load_profile_with_event_order([bad_entry])
            self.assertIn("scenario 'ordered'", str(raised.exception))
            self.assertIn(repr(bad_entry), str(raised.exception))

    def test_nested_subagent_validation_requires_two_distinct_matched_pairs(self):
        self.assertEqual(
            agent_bench.missing_nested_subagent_detail([{"event": "start", "agent_id": "a"}, {"event": "stop", "agent_id": "a"}]),
            "nested subagents require at least 2 SubagentStart hooks but 1 were captured",
        )
        self.assertEqual(
            agent_bench.missing_nested_subagent_detail(
                [{"event": "start", "agent_id": "a"}, {"event": "start", "agent_id": "b"}, {"event": "stop", "agent_id": "b"}]
            ),
            "nested subagents require at least 2 SubagentStop hooks but 1 were captured",
        )
        self.assertEqual(
            agent_bench.missing_nested_subagent_detail(
                [{"event": "start", "agent_id": "a"}, {"event": "start"}, {"event": "stop", "agent_id": "a"}, {"event": "stop"}]
            ),
            "SubagentStart payload did not carry an agent_id",
        )
        self.assertEqual(
            agent_bench.missing_nested_subagent_detail(
                [{"event": "start", "agent_id": "a"}, {"event": "start", "agent_id": "a"}, {"event": "stop", "agent_id": "a"}, {"event": "stop", "agent_id": "a"}]
            ),
            "SubagentStart hooks did not carry distinct agent ids: a, a",
        )
        self.assertEqual(
            agent_bench.missing_nested_subagent_detail(
                [{"event": "start", "agent_id": "a"}, {"event": "start", "agent_id": "b"}, {"event": "stop", "agent_id": "b"}, {"event": "stop", "agent_id": "zzz"}]
            ),
            "SubagentStop agent_id did not match any SubagentStart: zzz",
        )
        self.assertEqual(
            agent_bench.missing_nested_subagent_detail(
                [{"event": "start", "agent_id": "a"}, {"event": "start", "agent_id": "b"}, {"event": "stop", "agent_id": "a"}, {"event": "stop", "agent_id": "a"}]
            ),
            "SubagentStart without a matching SubagentStop: b",
        )
        self.assertIsNone(
            agent_bench.missing_nested_subagent_detail(
                [{"event": "start", "agent_id": "a"}, {"event": "start", "agent_id": "b"}, {"event": "stop", "agent_id": "b"}, {"event": "stop", "agent_id": "a"}]
            )
        )

    def test_nested_subagent_expectation_classifies_from_trace_records(self):
        expectation = agent_bench.ScenarioExpectation(
            name="subagents_nested",
            required_events=["SubagentStart", "SubagentStart", "SubagentStop", "SubagentStop", "Stop"],
            subagent_nested_required=True,
        )

        def record(event: str, agent_id: str) -> agent_bench.TraceRecord:
            kind = "start" if event == "SubagentStart" else "stop"
            return agent_bench.TraceRecord(
                kind="hook",
                agent="claude",
                scenario="subagents_nested",
                event_name=event,
                extra={"subagent": {"event": kind, "agent_id": agent_id, "agent_type": "Explore", "model": "opus"}},
            )

        stop = agent_bench.TraceRecord(kind="hook", agent="claude", scenario="subagents_nested", event_name="Stop")
        passing = [record("SubagentStart", "outer"), record("SubagentStart", "inner"), record("SubagentStop", "inner"), record("SubagentStop", "outer"), stop]
        result = agent_bench.classify_completed_result(
            agent="claude", scenario="subagents_nested", expectation=expectation, records=passing, terminal_observations=[],
            output="DONE", skip_patterns=[], exit_code=0, completed_by_predicate=True, strict=True,
        )
        self.assertTrue(result.passed, result.detail)

        failing = [record("SubagentStart", "outer"), record("SubagentStart", "outer"), record("SubagentStop", "outer"), record("SubagentStop", "outer"), stop]
        result = agent_bench.classify_completed_result(
            agent="claude", scenario="subagents_nested", expectation=expectation, records=failing, terminal_observations=[],
            output="DONE", skip_patterns=[], exit_code=0, completed_by_predicate=True, strict=True,
        )
        self.assertFalse(result.passed)
        self.assertEqual(result.result_kind, "missing-nested-subagent")
        self.assertEqual(result.detail, "SubagentStart hooks did not carry distinct agent ids: outer, outer")

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
    def test_kimi_help_output_with_plain_config_file_flag_is_legacy(self):
        self.assertFalse(agent_bench.is_modern_kimi_help_output("Usage: kimi --config-file config.toml"))

    def test_kimi_help_output_with_ansi_split_config_file_flag_is_legacy(self):
        help_text = "Usage: kimi \x1b[1;36m-\x1b[0m\x1b[1;36m-config\x1b[0m\x1b[1;36m-file\x1b[0m config.toml"

        self.assertFalse(agent_bench.is_modern_kimi_help_output(help_text))

    def test_kimi_help_output_without_config_file_flag_is_modern(self):
        self.assertTrue(agent_bench.is_modern_kimi_help_output("Usage: kimi-code -p, --prompt <prompt>"))

    def test_kimi_code_session_id_pattern_accepts_optional_session_prefix(self):
        session_id = "0abf9419-c274-464b-aa3e-7946c2153829"

        self.assertTrue(agent_bench.session_id_matches_pattern(session_id, "kimi-code"))
        self.assertTrue(agent_bench.session_id_matches_pattern(f"session_{session_id}", "kimi-code"))
        self.assertFalse(agent_bench.session_id_matches_pattern("session_not-a-uuid", "kimi-code"))
        self.assertFalse(agent_bench.session_id_matches_pattern("not-a-uuid", "kimi-code"))
        self.assertFalse(agent_bench.session_id_matches_pattern(f"prefix_{session_id}", "kimi-code"))

    def test_kimi_legacy_plan_uses_config_file_and_kimi_share_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            share = root / "share"
            share.mkdir()
            (share / "config.toml").write_text('model = "moonshot"\n', encoding="utf-8")
            planner = agent_bench.LaunchPlanner(
                profile=agent_bench.AgentProfile(
                    name="kimi",
                    tool="kimi",
                    command="kimi",
                    real_binary_names=["kimi-cli"],
                    version_args=["--version"],
                    launch_args_by_scenario={},
                    expectations={},
                    kimi_variant="legacy",
                ),
                scenario="smoke",
                run_dir=root,
                resources_dir=None,
            )

            plan = planner._plan_kimi(
                "/usr/bin/kimi",
                ["--prompt", "hello"],
                {"HOME": str(root / "home"), "KIMI_SHARE_DIR": str(share)},
                "/usr/bin/zentty",
            )

            self.assertEqual(plan["arguments"][:2], ["--config-file", plan["arguments"][1]])
            overlay = pathlib.Path(plan["arguments"][1])
            self.assertEqual(plan["arguments"][2:], ["--prompt", "hello"])
            self.assertEqual(plan["setEnvironment"]["ZENTTY_AGENT_TOOL"], "kimi")
            self.assertEqual(plan["setEnvironment"]["ZENTTY_KIMI_VARIANT"], "legacy")
            self.assertIn('model = "moonshot"', overlay.read_text(encoding="utf-8"))

    def test_kimi_modern_plan_installs_hooks_into_default_home_without_overlay(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            home = root / "home"
            source_home = home / ".kimi-code"
            source_home.mkdir(parents=True)
            (source_home / "credentials").mkdir()
            (source_home / "credentials" / "token.json").write_text("{}", encoding="utf-8")
            (source_home / "sessions").mkdir()
            (source_home / "config.toml").write_text('model = "kimi"\n', encoding="utf-8")
            planner = _modern_kimi_launch_planner(root)

            # No KIMI_CODE_HOME -> the default real home; hooks are installed there.
            plan = planner._plan_kimi(
                "/usr/bin/kimi",
                ["-p", "hello"],
                {"HOME": str(home)},
                "/usr/bin/zentty",
            )

            # No overlay home; kimi runs against the real home unchanged.
            self.assertEqual(plan["arguments"], ["-p", "hello"])
            self.assertNotIn("KIMI_CODE_HOME", plan["setEnvironment"])
            self.assertEqual(plan["unsetEnvironment"], [])
            self.assertEqual(plan["setEnvironment"]["ZENTTY_AGENT_TOOL"], "kimi")
            self.assertEqual(plan["setEnvironment"]["ZENTTY_KIMI_VARIANT"], "modern")

            # Real home is untouched (plain dirs); the hook block lands as a
            # marker-delimited managed block in config.toml.
            self.assertFalse((source_home / "credentials").is_symlink())
            self.assertFalse((source_home / "sessions").is_symlink())
            merged = (source_home / "config.toml").read_text(encoding="utf-8")
            self.assertIn('model = "kimi"', merged)
            self.assertIn("[[hooks]]", merged)
            self.assertIn(agent_bench.KIMI_MANAGED_BEGIN_MARKER, merged)
            self.assertFalse((root / "overlays").exists())

    def test_kimi_modern_plan_strips_stale_overlay_home_and_installs_into_default_home(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            home = root / "home"
            (home / ".kimi-code").mkdir(parents=True)
            (home / ".kimi-code" / "config.toml").write_text('model = "kimi"\n', encoding="utf-8")
            planner = _modern_kimi_launch_planner(root)

            stale = f"{home}/Library/Caches/Zentty/ipc-11370-9183AB50/launch/wl_x/pn_y/kimi/home"
            plan = planner._plan_kimi(
                "/usr/bin/kimi",
                ["-p", "hello"],
                {"HOME": str(home), "KIMI_CODE_HOME": stale},
                "/usr/bin/zentty",
            )

            self.assertEqual(plan["unsetEnvironment"], ["KIMI_CODE_HOME"])
            self.assertNotIn("KIMI_CODE_HOME", plan["setEnvironment"])
            merged = (home / ".kimi-code" / "config.toml").read_text(encoding="utf-8")
            self.assertIn("[[hooks]]", merged)

    def test_canonicalize_kimi_session_index_rewrites_stale_overlay_session_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            source_home = pathlib.Path(tmp) / "source-home"
            session_id = "session_a4d78f91-ea80-41e7-91d3-c699197ff442"
            work_dir_hash = "wd_fix-kimi-code-cli_57590bf29904"
            durable = source_home / "sessions" / work_dir_hash / session_id
            durable.mkdir(parents=True)
            overlay_session_dir = (
                f"/Users/peter/Library/Caches/Zentty/ipc-11370/launch/wl_x/pn_y/kimi/home/"
                f"sessions/{work_dir_hash}/{session_id}"
            )
            work_dir = "/Users/peter/Development/Personal/worktrees/fix-kimi-code-cli"
            index_path = _write_kimi_session_index(
                source_home,
                session_id=session_id,
                session_dir=overlay_session_dir,
                work_dir=work_dir,
            )

            agent_bench.canonicalize_kimi_session_index_if_needed(source_home)

            rewritten = json.loads(index_path.read_text(encoding="utf-8").splitlines()[0])
            self.assertEqual(rewritten["sessionId"], session_id)
            self.assertEqual(rewritten["sessionDir"], str(durable.resolve()))
            self.assertEqual(rewritten["workDir"], work_dir)

    def test_canonicalize_kimi_session_index_skips_missing_target_and_preserves_other_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            source_home = pathlib.Path(tmp) / "source-home"
            (source_home / "sessions").mkdir(parents=True)
            session_id = "session_missing-on-disk"
            work_dir_hash = "wd_missing_abcdef123456"
            overlay_session_dir = f"/tmp/overlay/kimi/home/sessions/{work_dir_hash}/{session_id}"
            poisoned = json.dumps(
                {
                    "sessionId": session_id,
                    "sessionDir": overlay_session_dir,
                    "workDir": "/tmp/project",
                }
            )
            original = "\n".join([poisoned, '{"note":"not-a-session"}', "not-json", ""])
            index_path = source_home / "session_index.jsonl"
            index_path.write_text(original, encoding="utf-8")

            agent_bench.canonicalize_kimi_session_index_if_needed(source_home)

            self.assertEqual(index_path.read_text(encoding="utf-8"), original)

    def test_kimi_modern_plan_canonicalizes_poisoned_session_index(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            source_home = root / "source-home"
            source_home.mkdir()
            (source_home / "config.toml").write_text('model = "kimi"\n', encoding="utf-8")
            session_id = "session_ae5ef9dc-a4fe-4cc1-9b18-27823ca399cc"
            work_dir_hash = "wd_fix-kimi-code-cli_57590bf29904"
            durable = source_home / "sessions" / work_dir_hash / session_id
            durable.mkdir(parents=True)
            overlay_session_dir = (
                f"{root}/overlays/old/kimi/home/sessions/{work_dir_hash}/{session_id}"
            )
            index_path = _write_kimi_session_index(
                source_home,
                session_id=session_id,
                session_dir=overlay_session_dir,
            )
            planner = _modern_kimi_launch_planner(root)

            planner._plan_kimi(
                "/usr/bin/kimi",
                ["-p", "hello"],
                {"HOME": str(root / "home"), "KIMI_CODE_HOME": str(source_home)},
                "/usr/bin/zentty",
            )

            rewritten = json.loads(index_path.read_text(encoding="utf-8").splitlines()[0])
            self.assertEqual(rewritten["sessionDir"], str(durable.resolve()))

    def test_resolve_agent_binary_picks_matching_kimi_variant(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            first = root / "first"
            second = root / "second"
            first.mkdir()
            second.mkdir()
            legacy = first / "kimi"
            modern = second / "kimi"
            legacy.write_text("#!/bin/sh\n", encoding="utf-8")
            modern.write_text("#!/bin/sh\n", encoding="utf-8")
            legacy.chmod(0o755)
            modern.chmod(0o755)
            profile = agent_bench.AgentProfile(
                name="kimi-code",
                tool="kimi",
                command="kimi",
                real_binary_names=["kimi"],
                version_args=["--version"],
                launch_args_by_scenario={},
                expectations={},
                kimi_variant="modern",
            )

            resolved, skip = agent_bench.resolve_agent_binary(
                profile,
                os.pathsep.join([str(first), str(second)]),
                variant_probe=lambda path: "modern" if pathlib.Path(path) == modern else "legacy",
            )

        self.assertEqual(resolved, str(modern))
        self.assertIsNone(skip)

    def test_resolve_agent_binary_reports_skip_when_pinned_kimi_variant_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            legacy = bin_dir / "kimi"
            legacy.write_text("#!/bin/sh\n", encoding="utf-8")
            legacy.chmod(0o755)
            profile = agent_bench.AgentProfile(
                name="kimi-code",
                tool="kimi",
                command="kimi",
                real_binary_names=["kimi"],
                version_args=["--version"],
                launch_args_by_scenario={},
                expectations={},
                kimi_variant="modern",
            )

            resolved, skip = agent_bench.resolve_agent_binary(
                profile,
                str(bin_dir),
                variant_probe=lambda _path: "legacy",
            )

        self.assertIsNone(resolved)
        self.assertEqual(skip, "no modern kimi binary found")

    def test_load_profiles_parses_session_identity_requirements(self):
        profile_dir = ROOT / "profiles"
        profiles = agent_bench.load_profiles(profile_dir)
        session_capture = profiles["codex"].expectations["session_capture"]

        self.assertEqual(session_capture.session_identity.session_id_pattern, "codex")
        self.assertTrue(session_capture.session_identity.tracked_pid)

    def test_validation_required_event_accepts_alternatives(self):
        scenario = agent_bench.ScenarioExpectation(
            name="subagents",
            required_events=["PreToolUse:run_subagent|PreToolUse:sidekick", "SessionEnd"],
        )
        observed = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="devin",
                scenario="subagents",
                event_name="PreToolUse",
                standard_input='{"tool_name":"sidekick"}',
            ),
            agent_bench.TraceRecord(kind="hook", agent="devin", scenario="subagents", event_name="SessionEnd"),
        ]

        # Only the second alternative was observed — the requirement passes.
        self.assertTrue(agent_bench.validate_scenario("devin", scenario, observed).passed)

        # Neither alternative observed — the missing list keeps the full a|b form.
        result = agent_bench.validate_scenario("devin", scenario, observed[1:])
        self.assertFalse(result.passed)
        self.assertEqual(result.missing_events, ["PreToolUse:run_subagent|PreToolUse:sidekick"])

        # A plain event without "|" is unaffected.
        plain = agent_bench.ScenarioExpectation(name="subagents", required_events=["SessionEnd"])
        self.assertTrue(agent_bench.validate_scenario("devin", plain, observed).passed)

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

    def test_validation_uses_profile_tool_for_tool_aliased_pid_environment(self):
        session_id = "session_0abf9419-c274-464b-aa3e-7946c2153829"
        scenario = agent_bench.ScenarioExpectation(
            name="session_capture",
            required_events=["SessionStart"],
            session_identity=agent_bench.SessionIdentityExpectation(
                session_id_pattern="kimi-code",
                tracked_pid=True,
            ),
        )
        observed = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="kimi-code",
                scenario="session_capture",
                event_name="SessionStart",
                standard_input=f'{{"hook_event_name":"SessionStart","session_id":"{session_id}"}}',
                environment={"ZENTTY_KIMI_PID": "5925"},
            )
        ]

        result = agent_bench.validate_scenario("kimi-code", scenario, observed, agent_tool="kimi")

        self.assertTrue(result.passed)
        self.assertEqual(result.session_identity_observations[0]["tracked_pid"], 5925)
        self.assertEqual(result.session_identity_observations[0]["tracked_pid_source"], "ZENTTY_KIMI_PID")

    def test_validation_accepts_small_harness_pid_from_underscore_environment_key(self):
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
                agent="small-harness",
                scenario="session_capture",
                event_name="SessionStart",
                standard_input='{"hook_event_name":"SessionStart","session_id":"0943211c-e3cf-4327-9334-cdacb3f4ec29"}',
                environment={"ZENTTY_SMALL_HARNESS_PID": "5925"},
            )
        ]

        result = agent_bench.validate_scenario("small-harness", scenario, observed)

        self.assertTrue(result.passed)
        self.assertEqual(
            result.session_identity_observations[0]["tracked_pid_source"],
            "ZENTTY_SMALL_HARNESS_PID",
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
            [
                {
                    "event": "preToolUse",
                    "tool": "TodoWrite",
                    "raw_tool_name": "TodoWrite",
                    "done": 1,
                    "total": 3,
                    "source": "raw_tool_call",
                    "items": [
                        {"title": "Review logs", "status": "completed"},
                        {"title": "Patch adapter", "status": "in_progress"},
                        {"title": "Run tests", "status": "pending"},
                    ],
                }
            ],
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

        self.assertEqual(observations[-1]["done"], 2)
        self.assertEqual(observations[-1]["total"], 6)
        self.assertEqual(observations[-1]["raw_tool_name"], "TodoWrite")
        self.assertEqual(
            observations[-1]["items"],
            [
                {"title": "Review logs", "status": "completed"},
                {"title": "Run tests", "status": "pending"},
                {"title": "Verify profile", "status": "completed"},
                {"title": "Check resume", "status": "pending"},
                {"title": "Smoke test", "status": "pending"},
                {"title": "Validate AgentEventBridge", "status": "pending"},
            ],
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
            [
                {
                    "event": "afterShellExecution",
                    "tool": "TodoWrite",
                    "raw_tool_name": "TodoWrite",
                    "done": 1,
                    "total": 3,
                    "source": "cursor_transcript",
                }
            ],
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
            {
                "tool": "TodoWrite",
                "done": 1,
                "total": 3,
                "source": "cursor_transcript",
                "items": [
                    {"title": "Review logs", "status": "completed"},
                    {"title": "Patch adapter", "status": "in_progress"},
                    {"title": "Run tests", "status": "pending"},
                ],
            },
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

        self.assertEqual(progress["done"], 2)
        self.assertEqual(progress["total"], 6)
        self.assertEqual(progress["source"], "cursor_transcript")
        self.assertEqual(
            progress["items"],
            [
                {"title": "Review logs", "status": "completed"},
                {"title": "Run tests", "status": "pending"},
                {"title": "Verify profile", "status": "completed"},
                {"title": "Check resume", "status": "pending"},
                {"title": "Smoke test", "status": "pending"},
                {"title": "Validate AgentEventBridge", "status": "pending"},
            ],
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
            [{"event": "task.progress", "tool": "TodoWrite", "raw_tool_name": "TodoWrite", "done": 2, "total": 4, "source": "canonical"}],
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

    def test_normalize_task_status(self):
        self.assertEqual(agent_bench.normalize_task_status("completed"), "done")
        self.assertEqual(agent_bench.normalize_task_status("Complete"), "done")
        self.assertEqual(agent_bench.normalize_task_status("done"), "done")
        self.assertEqual(agent_bench.normalize_task_status("finished"), "done")
        self.assertEqual(agent_bench.normalize_task_status("in_progress"), "in_progress")
        self.assertEqual(agent_bench.normalize_task_status("in-progress"), "in_progress")
        self.assertEqual(agent_bench.normalize_task_status("active"), "in_progress")
        self.assertEqual(agent_bench.normalize_task_status("running"), "in_progress")
        self.assertEqual(agent_bench.normalize_task_status("pending"), "pending")
        self.assertEqual(agent_bench.normalize_task_status("cancelled"), "pending")
        self.assertEqual(agent_bench.normalize_task_status(""), "pending")
        self.assertEqual(agent_bench.normalize_task_status(None), "pending")

    def test_extracts_items_from_todos_list(self):
        records = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="droid",
                scenario="tasks",
                event_name="PreToolUse",
                adapter="droid",
                standard_input=json.dumps(
                    {
                        "hook_event_name": "PreToolUse",
                        "tool_name": "TodoWrite",
                        "tool_input": {
                            "todos": [
                                {"content": "Review directory", "status": "completed"},
                                {"content": "Identify main language", "status": "in_progress"},
                                {"content": "Suggest one improvement", "status": "pending"},
                            ]
                        },
                    }
                ),
            )
        ]

        observations = agent_bench.task_observations_for_records("droid", "tasks", records)

        self.assertEqual(len(observations), 1)
        self.assertEqual(observations[0]["raw_tool_name"], "TodoWrite")
        self.assertEqual(
            observations[0]["items"],
            [
                {"title": "Review directory", "status": "completed"},
                {"title": "Identify main language", "status": "in_progress"},
                {"title": "Suggest one improvement", "status": "pending"},
            ],
        )

    def test_extracts_items_from_update_plan(self):
        records = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="codex",
                scenario="tasks",
                event_name="pre-tool-use",
                adapter="codex",
                standard_input=json.dumps(
                    {
                        "hook_event_name": "PreToolUse",
                        "tool_name": "update_plan",
                        "tool_input": {
                            "plan": [
                                {"step": "Review directory", "status": "completed"},
                                {"step": "Identify main language", "status": "in_progress"},
                                {"step": "Suggest one improvement", "status": "pending"},
                            ]
                        },
                    }
                ),
            )
        ]

        observations = agent_bench.task_observations_for_records("codex", "tasks", records)

        self.assertEqual(len(observations), 1)
        self.assertEqual(observations[0]["raw_tool_name"], "update_plan")
        self.assertEqual(observations[0]["done"], 1)
        self.assertEqual(observations[0]["total"], 3)
        self.assertEqual(
            observations[0]["items"],
            [
                {"title": "Review directory", "status": "completed"},
                {"title": "Identify main language", "status": "in_progress"},
                {"title": "Suggest one improvement", "status": "pending"},
            ],
        )

    def test_aggregates_claude_task_created_and_completed_hooks(self):
        records = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="claude",
                scenario="tasks",
                event_name="TaskCreated",
                adapter="claude",
                standard_input=json.dumps(
                    {
                        "hook_event_name": "TaskCreated",
                        "session_id": "claude-session",
                        "task_id": "1",
                        "task_subject": "Review directory",
                    }
                ),
            ),
            agent_bench.TraceRecord(
                kind="hook",
                agent="claude",
                scenario="tasks",
                event_name="TaskCreated",
                adapter="claude",
                standard_input=json.dumps(
                    {
                        "hook_event_name": "TaskCreated",
                        "session_id": "claude-session",
                        "task_id": "2",
                        "task_subject": "Identify main language",
                    }
                ),
            ),
            agent_bench.TraceRecord(
                kind="hook",
                agent="claude",
                scenario="tasks",
                event_name="TaskCreated",
                adapter="claude",
                standard_input=json.dumps(
                    {
                        "hook_event_name": "TaskCreated",
                        "session_id": "claude-session",
                        "task_id": "3",
                        "task_subject": "Suggest one improvement",
                    }
                ),
            ),
            agent_bench.TraceRecord(
                kind="hook",
                agent="claude",
                scenario="tasks",
                event_name="TaskCompleted",
                adapter="claude",
                standard_input=json.dumps(
                    {
                        "hook_event_name": "TaskCompleted",
                        "session_id": "claude-session",
                        "task_id": "1",
                        "task_subject": "Review directory",
                    }
                ),
            ),
            agent_bench.TraceRecord(
                kind="hook",
                agent="claude",
                scenario="tasks",
                event_name="PreToolUse",
                adapter="claude",
                standard_input=json.dumps(
                    {
                        "hook_event_name": "PreToolUse",
                        "session_id": "claude-session",
                        "tool_name": "TaskUpdate",
                        "tool_input": {"task_id": "2", "status": "in_progress"},
                    }
                ),
            ),
        ]

        observations = agent_bench.task_observations_for_records("claude", "tasks", records)

        self.assertEqual(len(observations), 5)
        final = observations[-1]
        self.assertEqual(final["raw_tool_name"], "TaskUpdate")
        self.assertEqual(final["done"], 1)
        self.assertEqual(final["total"], 3)
        self.assertEqual(
            final["items"],
            [
                {"title": "Review directory", "status": "done"},
                {"title": "Identify main language", "status": "in_progress"},
                {"title": "Suggest one improvement", "status": "pending"},
            ],
        )

    def test_task_update_post_tool_use_joins_task_created_by_id(self):
        # Claude interactive flow: TaskCreated lifecycle hook carries
        # task_id + task_subject; the TaskUpdate tool call only carries
        # tool_input.{taskId,status} and must update the existing item.
        records = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="claude",
                scenario="tasks",
                event_name="TaskCreated",
                adapter="claude",
                standard_input=json.dumps(
                    {
                        "hook_event_name": "TaskCreated",
                        "session_id": "s1",
                        "task_id": "2",
                        "task_subject": "Identify main language",
                    }
                ),
            ),
            agent_bench.TraceRecord(
                kind="hook",
                agent="claude",
                scenario="tasks",
                event_name="PostToolUse",
                adapter="claude",
                standard_input=json.dumps(
                    {
                        "hook_event_name": "PostToolUse",
                        "session_id": "s1",
                        "tool_name": "TaskUpdate",
                        "tool_input": {"taskId": "2", "status": "in_progress"},
                    }
                ),
            ),
        ]

        observations = agent_bench.task_observations_for_records("claude", "tasks", records)

        final = observations[-1]
        self.assertEqual(final["raw_tool_name"], "TaskUpdate")
        self.assertEqual(final["items"], [{"title": "Identify main language", "status": "in_progress"}])

    def test_task_create_tool_call_joins_task_created_by_title(self):
        # The TaskCreate tool_input has no task id; join on the shared
        # title so the session list does not double-count the task.
        records = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="claude",
                scenario="tasks",
                event_name="TaskCreated",
                adapter="claude",
                standard_input=json.dumps(
                    {
                        "hook_event_name": "TaskCreated",
                        "session_id": "s1",
                        "task_id": "1",
                        "task_subject": "Review directory",
                    }
                ),
            ),
            agent_bench.TraceRecord(
                kind="hook",
                agent="claude",
                scenario="tasks",
                event_name="PostToolUse",
                adapter="claude",
                standard_input=json.dumps(
                    {
                        "hook_event_name": "PostToolUse",
                        "session_id": "s1",
                        "tool_name": "TaskCreate",
                        "tool_input": {"subject": "Review directory", "description": "Inspect the repo"},
                        "tool_response": {"task": {"id": "1", "subject": "Review directory", "status": "pending"}},
                    }
                ),
            ),
        ]

        observations = agent_bench.task_observations_for_records("claude", "tasks", records)

        final = observations[-1]
        self.assertEqual(final["total"], 1)
        self.assertEqual(final["items"], [{"title": "Review directory", "status": "pending"}])

    def test_task_update_post_tool_use_reads_tool_response_task_object(self):
        # When TaskUpdate's tool_input carries only the id, the task object in
        # tool_response still supplies title + status.
        records = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="claude",
                scenario="tasks",
                event_name="TaskCreated",
                adapter="claude",
                standard_input=json.dumps(
                    {
                        "hook_event_name": "TaskCreated",
                        "session_id": "s1",
                        "task_id": "1",
                        "task_subject": "Review directory",
                    }
                ),
            ),
            agent_bench.TraceRecord(
                kind="hook",
                agent="claude",
                scenario="tasks",
                event_name="PostToolUse",
                adapter="claude",
                standard_input=json.dumps(
                    {
                        "hook_event_name": "PostToolUse",
                        "session_id": "s1",
                        "tool_name": "TaskUpdate",
                        "tool_input": {"taskId": "1"},
                        "tool_response": {"task": {"id": "1", "subject": "Review directory", "status": "completed"}},
                    }
                ),
            ),
        ]

        observations = agent_bench.task_observations_for_records("claude", "tasks", records)

        final = observations[-1]
        self.assertEqual(final["items"], [{"title": "Review directory", "status": "completed"}])
        self.assertEqual(final["done"], 1)
        self.assertEqual(final["total"], 1)

    def test_expected_task_items_passes_when_titles_and_statuses_match(self):
        expectation = agent_bench.ScenarioExpectation(
            "tasks",
            ["SessionStart", "Stop"],
            expected_task_items=[
                {"title": "Review directory", "status": "completed"},
                {"title": "Identify main language", "status": "in_progress"},
                {"title": "Suggest one improvement", "status": "pending"},
            ],
        )
        result = agent_bench.classify_completed_result(
            agent="droid",
            scenario="tasks",
            expectation=expectation,
            records=[
                agent_bench.TraceRecord(kind="hook", agent="droid", scenario="tasks", event_name="SessionStart"),
                agent_bench.TraceRecord(
                    kind="hook",
                    agent="droid",
                    scenario="tasks",
                    event_name="PreToolUse",
                    standard_input=json.dumps(
                        {
                            "hook_event_name": "PreToolUse",
                            "tool_name": "TodoWrite",
                            "tool_input": {
                                "todos": [
                                    {"content": "Review directory", "status": "completed"},
                                    {"content": "Identify main language", "status": "in_progress"},
                                    {"content": "Suggest one improvement", "status": "pending"},
                                ]
                            },
                        }
                    ),
                ),
                agent_bench.TraceRecord(kind="hook", agent="droid", scenario="tasks", event_name="Stop"),
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

    def test_expected_task_items_fails_when_items_not_captured(self):
        expectation = agent_bench.ScenarioExpectation(
            "tasks",
            ["SessionStart", "Stop"],
            expected_task_items=[
                {"title": "Review directory", "status": "completed"},
            ],
        )
        result = agent_bench.classify_completed_result(
            agent="droid",
            scenario="tasks",
            expectation=expectation,
            records=[
                agent_bench.TraceRecord(kind="hook", agent="droid", scenario="tasks", event_name="SessionStart"),
                agent_bench.TraceRecord(
                    kind="hook",
                    agent="droid",
                    scenario="tasks",
                    event_name="PreToolUse",
                    standard_input=json.dumps(
                        {
                            "hook_event_name": "PreToolUse",
                            "tool_name": "TodoWrite",
                            "tool_input": {
                                "todos": [
                                    {"content": "Review directory", "status": "pending"},
                                    {"content": "Other task", "status": "pending"},
                                    {"content": "Third task", "status": "pending"},
                                ]
                            },
                        }
                    ),
                ),
                agent_bench.TraceRecord(kind="hook", agent="droid", scenario="tasks", event_name="Stop"),
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
        self.assertEqual(result.result_kind, "missing-task-items")
        self.assertEqual(result.detail, "required task items were not captured")

    def test_expected_task_items_fails_when_no_items_on_observation(self):
        expectation = agent_bench.ScenarioExpectation(
            "tasks",
            ["sessionStart", "sessionEnd"],
            expected_task_items=[{"title": "Review directory", "status": "completed"}],
        )
        result = agent_bench.classify_completed_result(
            agent="cursor",
            scenario="tasks",
            expectation=expectation,
            records=[
                agent_bench.TraceRecord(kind="hook", agent="cursor", scenario="tasks", event_name="sessionStart"),
                agent_bench.TraceRecord(
                    kind="hook",
                    agent="cursor",
                    scenario="tasks",
                    event_name="afterShellExecution",
                    extra={"task_progress": {"tool": "TodoWrite", "done": 1, "total": 3, "source": "cursor_transcript"}},
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
        self.assertEqual(result.result_kind, "missing-task-items")

    def test_extracts_items_from_canonical_task_progress(self):
        records = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="grok",
                scenario="tasks",
                event_name="task.progress",
                adapter="grok",
                standard_input=json.dumps(
                    {
                        "event": "task.progress",
                        "progress": {
                            "done": 1,
                            "total": 3,
                            "items": [
                                {"title": "Review directory", "status": "done"},
                                {"title": "Identify main language", "status": "in_progress"},
                                {"title": "Suggest one improvement", "status": "pending"},
                            ],
                        },
                    }
                ),
            )
        ]

        observations = agent_bench.task_observations_for_records("grok", "tasks", records)

        self.assertEqual(len(observations), 1)
        self.assertEqual(observations[0]["done"], 1)
        self.assertEqual(observations[0]["total"], 3)
        self.assertEqual(observations[0]["source"], "canonical")
        self.assertEqual(
            observations[0]["items"],
            [
                {"title": "Review directory", "status": "done"},
                {"title": "Identify main language", "status": "in_progress"},
                {"title": "Suggest one improvement", "status": "pending"},
            ],
        )

    def test_extracts_items_from_trace_extra_task_progress(self):
        records = [
            agent_bench.TraceRecord(
                kind="hook",
                agent="cursor",
                scenario="tasks",
                event_name="afterShellExecution",
                adapter="cursor",
                standard_input=json.dumps({"hook_event_name": "afterShellExecution"}),
                extra={
                    "task_progress": {
                        "tool": "TodoWrite",
                        "done": 1,
                        "total": 3,
                        "source": "cursor_transcript",
                        "items": [
                            {"title": "Review directory", "status": "completed"},
                            {"title": "Identify main language", "status": "in_progress"},
                            {"title": "Suggest one improvement", "status": "pending"},
                        ],
                    }
                },
            )
        ]

        observations = agent_bench.task_observations_for_records("cursor", "tasks", records)

        self.assertEqual(len(observations), 1)
        self.assertEqual(observations[0]["source"], "cursor_transcript")
        self.assertEqual(
            observations[0]["items"],
            [
                {"title": "Review directory", "status": "completed"},
                {"title": "Identify main language", "status": "in_progress"},
                {"title": "Suggest one improvement", "status": "pending"},
            ],
        )

    def test_load_profiles_parses_expected_task_items(self):
        with tempfile.TemporaryDirectory() as tmp:
            profile_path = pathlib.Path(tmp) / "demo.json"
            profile_path.write_text(
                json.dumps(
                    {
                        "name": "demo",
                        "command": "demo",
                        "expectations": {
                            "tasks": {
                                "required_events": ["sessionStart"],
                                "expected_task_items": [
                                    {"title": "Review directory", "status": "completed"},
                                    {"title": "Identify main language", "status": "in_progress"},
                                ],
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )

            profiles = agent_bench.load_profiles(pathlib.Path(tmp))

        self.assertEqual(
            profiles["demo"].expectations["tasks"].expected_task_items,
            [
                {"title": "Review directory", "status": "completed"},
                {"title": "Identify main language", "status": "in_progress"},
            ],
        )

    def test_load_profiles_rejects_malformed_expected_task_items(self):
        for bad_value in (
            "not-a-list",
            {"title": "Review directory"},
            [],
            [{"title": "Review directory"}],
            [{"status": "completed"}],
            [{"title": "", "status": "pending"}],
            [{"title": "Review directory", "status": 1}],
        ):
            with tempfile.TemporaryDirectory() as tmp:
                profile_path = pathlib.Path(tmp) / "demo.json"
                profile_path.write_text(
                    json.dumps(
                        {
                            "name": "demo",
                            "command": "demo",
                            "expectations": {"tasks": {"expected_task_items": bad_value}},
                        }
                    ),
                    encoding="utf-8",
                )

                with self.assertRaises(ValueError, msg=f"expected_task_items={bad_value!r}"):
                    agent_bench.load_profiles(pathlib.Path(tmp))

    def test_load_profiles_parses_environment_by_scenario(self):
        with tempfile.TemporaryDirectory() as tmp:
            profile_path = pathlib.Path(tmp) / "demo.json"
            profile_path.write_text(
                json.dumps(
                    {
                        "name": "demo",
                        "command": "demo",
                        "environment_by_scenario": {"tasks": {"CLAUDE_CODE_ENABLE_TODO_TOOLS": "1"}},
                    }
                ),
                encoding="utf-8",
            )

            profiles = agent_bench.load_profiles(pathlib.Path(tmp))

        self.assertEqual(
            profiles["demo"].environment_by_scenario,
            {"tasks": {"CLAUDE_CODE_ENABLE_TODO_TOOLS": "1"}},
        )

    def test_load_profiles_rejects_malformed_environment_by_scenario(self):
        for bad_value in (
            "not-an-object",
            {"tasks": "not-an-object"},
            {"tasks": {"FLAG": 1}},
            {"tasks": {"": "1"}},
        ):
            with tempfile.TemporaryDirectory() as tmp:
                profile_path = pathlib.Path(tmp) / "demo.json"
                profile_path.write_text(
                    json.dumps(
                        {
                            "name": "demo",
                            "command": "demo",
                            "environment_by_scenario": bad_value,
                        }
                    ),
                    encoding="utf-8",
                )

                with self.assertRaises(ValueError, msg=f"environment_by_scenario={bad_value!r}"):
                    agent_bench.load_profiles(pathlib.Path(tmp))


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

    def test_capture_server_current_agent_selects_tool_alias_profile_for_bootstrap(self):
        with tempfile.TemporaryDirectory() as tmp:
            profiles = {
                "kimi": agent_bench.AgentProfile(
                    name="kimi",
                    tool="kimi",
                    command="kimi",
                    real_binary_names=["kimi"],
                    version_args=["--version"],
                    launch_args_by_scenario={"smoke": []},
                    expectations={"smoke": agent_bench.ScenarioExpectation("smoke", [])},
                    kimi_variant="legacy",
                ),
                "kimi-code": agent_bench.AgentProfile(
                    name="kimi-code",
                    tool="kimi",
                    command="kimi",
                    real_binary_names=["kimi"],
                    version_args=["--version"],
                    launch_args_by_scenario={"smoke": []},
                    expectations={"smoke": agent_bench.ScenarioExpectation("smoke", [])},
                    kimi_variant="modern",
                ),
            }
            recorder = agent_bench.TraceRecorder(pathlib.Path(tmp))
            server = agent_bench.CaptureServer(
                pathlib.Path(tmp) / "bench.sock",
                recorder=recorder,
                profiles=profiles,
                scenario="smoke",
                run_dir=pathlib.Path(tmp),
            )
            server.current_agent = "kimi-code"

            response = server._bootstrap_response(
                {
                    "id": "bootstrap",
                    "kind": "bootstrap",
                    "arguments": ["-p", "hello"],
                    "environment": {
                        "HOME": str(pathlib.Path(tmp) / "home"),
                        "ZENTTY_CLI_BIN": "/usr/bin/zentty",
                        "ZENTTY_REAL_BINARY": "/usr/bin/kimi",
                    },
                    "expectsResponse": True,
                    "tool": "kimi",
                }
            )

        plan = response["result"]["launchPlan"]
        records = recorder.records()
        self.assertTrue(response["ok"])
        self.assertEqual(plan["arguments"], ["-p", "hello"])
        self.assertNotIn("--config-file", plan["arguments"])
        self.assertEqual(plan["setEnvironment"]["ZENTTY_KIMI_VARIANT"], "modern")
        self.assertEqual(records[0].agent, "kimi-code")

    def test_capture_server_current_agent_reattributes_tool_level_hooks(self):
        with tempfile.TemporaryDirectory() as tmp:
            profiles = {
                "kimi": agent_bench.AgentProfile(
                    name="kimi",
                    tool="kimi",
                    command="kimi",
                    real_binary_names=["kimi"],
                    version_args=["--version"],
                    launch_args_by_scenario={"smoke": []},
                    expectations={"smoke": agent_bench.ScenarioExpectation("smoke", [])},
                    kimi_variant="legacy",
                ),
                "kimi-code": agent_bench.AgentProfile(
                    name="kimi-code",
                    tool="kimi",
                    command="kimi",
                    real_binary_names=["kimi"],
                    version_args=["--version"],
                    launch_args_by_scenario={"smoke": []},
                    expectations={"smoke": agent_bench.ScenarioExpectation("smoke", [])},
                    kimi_variant="modern",
                ),
            }
            recorder = agent_bench.TraceRecorder(pathlib.Path(tmp))
            server = agent_bench.CaptureServer(
                pathlib.Path(tmp) / "bench.sock",
                recorder=recorder,
                profiles=profiles,
                scenario="smoke",
            )
            server.current_agent = "kimi-code"

            server._record_ipc(
                {
                    "kind": "ipc",
                    "arguments": ["--adapter=kimi"],
                    "standardInput": '{"hook_event_name":"SessionStart"}',
                    "environment": {},
                    "subcommand": "agent-event",
                }
            )

        records = recorder.records()
        self.assertEqual(records[0].agent, "kimi-code")
        self.assertEqual(records[0].event_name, "SessionStart")


class ProfileTests(unittest.TestCase):
    def test_loads_profiles_for_all_zentty_supported_agents(self):
        profiles = agent_bench.load_profiles(ROOT / "profiles")

        self.assertEqual(
            sorted(profiles),
            [
                "agy",
                "amp",
                "claude",
                "codex",
                "copilot",
                "cursor",
                "devin",
                "droid",
                "gemini",
                "generic-canonical",
                "grok",
                "hermes",
                "kilo",
                "kimi",
                "kimi-code",
                "omp",
                "opencode",
                "opencode-v2",
                "pi",
                "small-harness",
                "vibe",
            ],
        )
        self.assertEqual(sorted(agent_bench.SUPPORTED_AGENTS), sorted(profiles))
        for profile in profiles.values():
            self.assertIn("smoke", profile.expectations)

    def test_devin_subagent_scenarios_accept_run_subagent_or_sidekick(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["devin"]

        for scenario in ("subagents", "subagents_async"):
            events = profile.expectations[scenario].required_events
            self.assertIn("PreToolUse:run_subagent|PreToolUse:sidekick", events, scenario)
            self.assertIn("PostToolUse:run_subagent|PostToolUse:sidekick", events, scenario)

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
        self.assertEqual(profile.expectations["tasks"].expected_task_progress, {"done": 1, "total": 3})

    def test_copilot_approval_profile_drives_interactive_prompt_like_a_person(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["copilot"]

        self.assertEqual(profile.launch_args_by_scenario["approval"][:2], ["--prompt", "Run this exact shell command: printf ZENTTY_AGENT_BENCH_APPROVAL_OK"])
        self.assertIn("--allow-all-paths", profile.launch_args_by_scenario["approval"])
        self.assertNotIn("--allow-all-tools", profile.launch_args_by_scenario["approval"])

    def test_kimi_code_profile_uses_prompt_mode_and_interactive_approval(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["kimi-code"]
        smoke_prompt = "Run this exact shell command: printf ZENTTY_AGENT_BENCH_OK"
        approval_prompt = "Run this exact shell command: printf ZENTTY_AGENT_BENCH_APPROVAL_OK"

        self.assertEqual(profile.launch_args_by_scenario["smoke"], ["-p", smoke_prompt])
        self.assertEqual(profile.launch_args_by_scenario["session_capture"], ["-p", smoke_prompt])
        self.assertEqual(profile.launch_args_by_scenario["approval"], [])
        self.assertEqual(profile.expectations["session_capture"].session_identity.session_id_pattern, "kimi-code")
        self.assertEqual(
            profile.input_by_scenario["approval"],
            [
                {"after": 8, "text": approval_prompt + "\r"},
                {"after": 30, "text": "y\r"},
                {"after": 60, "text": "\u0003"},
            ],
        )

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

    def test_small_harness_profile_uses_managed_one_shot_hooks_and_continue_restore(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["small-harness"]

        self.assertEqual(profile.command, "small-harness")
        self.assertEqual(profile.real_binary_names, ["small-harness"])
        self.assertIn("--print", profile.launch_args_by_scenario["smoke"])
        self.assertIn("--allow-tools", profile.launch_args_by_scenario["auto_approval"])
        self.assertNotIn("--allow-tools", profile.launch_args_by_scenario["approval"])
        self.assertEqual(
            profile.expectations["smoke"].required_events,
            ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"],
        )
        self.assertEqual(
            profile.expectations["restore_launch"].required_bootstrap_arguments,
            [["--continue"]],
        )
        self.assertIn("model '", profile.skip_patterns)

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
            # agy reads its OAuth login from the macOS login keychain under
            # ~/Library/Keychains; the overlay must surface it so agy reuses
            # the user's global Antigravity login instead of starting logged
            # out.
            (real_home / "Library" / "Keychains").mkdir(parents=True)
            (real_home / "Library" / "Keychains" / "login.keychain-db").write_text("x")

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
            # …the login keychain is surfaced as a symlink to the real one so
            # agy reuses the global Antigravity login (auth material only; the
            # agent's conversations/state stay isolated in the fresh
            # overlay antigravity-cli).
            overlay_keychains = overlay_home / "Library" / "Keychains"
            self.assertTrue(overlay_keychains.is_symlink())
            self.assertEqual(
                os.path.realpath(overlay_keychains),
                os.path.realpath(real_home / "Library" / "Keychains"),
            )
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

    def test_agy_plan_without_login_keychain_omits_symlink(self):
        # When the host has no ~/Library/Keychains (not logged in, or a
        # non-macOS runner) the plan must degrade gracefully — no keychain
        # symlink, and no crash — behaving exactly as before the seed.
        profile = agent_bench.load_profiles(ROOT / "profiles")["agy"]
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = pathlib.Path(tmp)
            real_home = run_dir / "real-home"
            (real_home / ".gemini" / "config").mkdir(parents=True)

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
            self.assertFalse((overlay_home / "Library" / "Keychains").exists())
            self.assertFalse((overlay_home / "Library" / "Keychains").is_symlink())

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


class SigningModeTests(unittest.TestCase):
    FIND_IDENTITY_OUTPUT = """
  1) C89AB0992D86540C963777EF2C1D2F37E40AD88E "Apple Distribution: Example University (V8FJHNS4MP)"
  2) 84A5E223A8D636075A5B0698C585D54D9BCA117B "Apple Development: Jane Doe (A4BAMPA583)"
  3) AB3F8610298D19FADC70AC8378BE8FB912F4F5B1 "Developer ID Application: Example BV (25TVW8MSGJ)"
  4) 1111111111111111111111111111111111111111 "Mac Developer: Jane Doe (5V995VZ66W)"
     4 valid identities found
"""

    def test_development_identity_hashes_skip_distribution_and_developer_id(self):
        self.assertEqual(
            agent_bench.parse_development_identity_hashes(self.FIND_IDENTITY_OUTPUT),
            ["84A5E223A8D636075A5B0698C585D54D9BCA117B", "1111111111111111111111111111111111111111"],
        )

    def test_certificate_pems_are_keyed_by_sha1_hash(self):
        output = (
            "SHA-256 hash: AAAA\nSHA-1 hash: " + "A" * 40 + "\nkeychain: \"login\"\n"
            "-----BEGIN CERTIFICATE-----\nfirst\n-----END CERTIFICATE-----\n"
            "SHA-256 hash: BBBB\nSHA-1 hash: " + "B" * 40 + "\n"
            "-----BEGIN CERTIFICATE-----\nsecond\n-----END CERTIFICATE-----\n"
        )

        pems = agent_bench.parse_certificate_pems(output)

        self.assertEqual(set(pems), {"A" * 40, "B" * 40})
        self.assertIn("second", pems["B" * 40])
        self.assertNotIn("second", pems["A" * 40])

    def test_certificate_without_pem_does_not_borrow_the_next_entry(self):
        output = (
            "SHA-1 hash: " + "A" * 40 + "\nkeychain: \"login\"\n"
            "SHA-1 hash: " + "B" * 40 + "\n"
            "-----BEGIN CERTIFICATE-----\nsecond\n-----END CERTIFICATE-----\n"
        )

        self.assertEqual(list(agent_bench.parse_certificate_pems(output)), ["B" * 40])

    def test_subject_team_id_reads_libressl_and_openssl3_formats(self):
        libressl = "subject= /UID=7NUVSU7UDW/CN=Apple Development: Jane Doe (A4BAMPA583)/OU=25TVW8MSGJ/O=Example BV/C=US"
        openssl3 = "subject=UID = 7NUVSU7UDW, CN = Apple Development: Jane Doe (A4BAMPA583), OU = 25TVW8MSGJ, O = Example BV, C = US"

        self.assertEqual(agent_bench.parse_subject_team_id(libressl), "25TVW8MSGJ")
        self.assertEqual(agent_bench.parse_subject_team_id(openssl3), "25TVW8MSGJ")
        self.assertIsNone(agent_bench.parse_subject_team_id("subject= /CN=No Team"))

    def test_auto_signing_falls_back_to_ad_hoc_only_when_identity_is_known_missing(self):
        self.assertEqual(agent_bench.resolve_signing_mode("auto", "25TVW8MSGJ", detector=lambda _: False), "ad-hoc")
        self.assertEqual(agent_bench.resolve_signing_mode("auto", "25TVW8MSGJ", detector=lambda _: True), "team")
        # Keychain inspection failed: keep the default build rather than guess.
        self.assertEqual(agent_bench.resolve_signing_mode("auto", "25TVW8MSGJ", detector=lambda _: None), "team")

    def test_auto_signing_without_team_skips_detection(self):
        def detector(_):
            raise AssertionError("detector should not run without a team")

        self.assertEqual(agent_bench.resolve_signing_mode("auto", "", detector=detector), "team")

    def test_explicit_signing_mode_wins(self):
        def detector(_):
            raise AssertionError("detector should not run for an explicit mode")

        self.assertEqual(agent_bench.resolve_signing_mode("ad-hoc", "25TVW8MSGJ", detector=detector), "ad-hoc")
        self.assertEqual(agent_bench.resolve_signing_mode("team", "25TVW8MSGJ", detector=detector), "team")

    def test_build_passes_ad_hoc_overrides_when_team_identity_is_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = type(
                "Args",
                (),
                {
                    "run_dir": tmp,
                    "app_path": None,
                    "no_build": False,
                    "signing": "auto",
                    "timeout": 30,
                    "strict": False,
                    "agents": "codex",
                    "scenarios": "smoke",
                },
            )()
            calls = []

            def fake_run(command, **kwargs):
                calls.append(command)
                stdout = "DEVELOPMENT_TEAM = 25TVW8MSGJ\nBUILT_PRODUCTS_DIR = /tmp/build\nFULL_PRODUCT_NAME = Zentty.app\n"
                return mock.Mock(stdout=stdout if "-showBuildSettings" in command else "")

            runner = agent_bench.BenchRunner(args)
            try:
                with mock.patch.object(agent_bench.subprocess, "run", side_effect=fake_run), \
                     mock.patch.object(agent_bench, "has_development_identity_for_team", return_value=False), \
                     mock.patch("sys.stderr"):
                    app_path = runner._resolve_app_path()
            finally:
                runner._cleanup_socket_dir()

        self.assertEqual(app_path, pathlib.Path("/tmp/build/Zentty.app"))
        build = next(command for command in calls if "build" in command)
        self.assertEqual(build[-len(agent_bench.AD_HOC_SIGNING_OVERRIDES):], list(agent_bench.AD_HOC_SIGNING_OVERRIDES))


class BenchRunnerExecutionTests(unittest.TestCase):
    def test_variant_pinned_kimi_profile_sets_explicit_real_binary_override(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            app_path = root / "Zentty.app"
            resources = app_path / "Contents" / "Resources"
            zentty = resources / "bin" / "shared" / "zentty"
            zentty.parent.mkdir(parents=True)
            zentty.write_text("#!/bin/sh\n", encoding="utf-8")
            zentty.chmod(0o755)
            wrapper_dir = resources / "bin" / "kimi"
            wrapper_dir.mkdir(parents=True)
            wrapper = wrapper_dir / "kimi"
            wrapper.write_text("#!/bin/sh\n", encoding="utf-8")
            wrapper.chmod(0o755)
            real_command = root / "real" / "kimi-cli"
            real_command.parent.mkdir()
            real_command.write_text("#!/bin/sh\n", encoding="utf-8")
            real_command.chmod(0o755)

            args = type(
                "Args",
                (),
                {
                    "run_dir": str(root / "run"),
                    "app_path": str(app_path),
                    "no_build": True,
                    "timeout": 30,
                    "strict": False,
                    "agents": "kimi",
                    "scenarios": "smoke",
                },
            )()
            runner = agent_bench.BenchRunner(args)
            runner._resolved_app_path = app_path
            runner.profiles = {
                "kimi": agent_bench.AgentProfile(
                    name="kimi",
                    command="kimi",
                    real_binary_names=["kimi", "kimi-cli"],
                    version_args=["--version"],
                    launch_args_by_scenario={"smoke": []},
                    expectations={"smoke": agent_bench.ScenarioExpectation("smoke", [])},
                    tool="kimi",
                    kimi_variant="legacy",
                )
            }
            captured_env = {}

            def fake_run_pty(argv, env, cwd, inputs, timeout, transcript_path, completion_predicate):
                captured_env.update(env)
                return agent_bench.PtyResult(0, False, "", completed_by_predicate=True)

            try:
                with mock.patch.object(agent_bench, "resolve_agent_binary", return_value=(str(real_command), None)), \
                     mock.patch.object(agent_bench, "run_version", return_value="kimi 0.0"), \
                     mock.patch.object(agent_bench, "run_pty", side_effect=fake_run_pty):
                    result = runner._run_agent_scenario(
                        "kimi",
                        "smoke",
                        {"PATH": str(wrapper_dir), "HOME": str(root / "home")},
                    )
            finally:
                runner._cleanup_socket_dir()

        self.assertEqual(result.status, "pass")
        self.assertEqual(captured_env.get("ZENTTY_KIMI_VARIANT"), "legacy")
        self.assertEqual(captured_env.get("ZENTTY_REAL_BINARY"), str(real_command))


class KimiResumeHelperTests(unittest.TestCase):
    def test_seed_kimi_bench_home_symlinks_auth_and_copies_device_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            operator = root / "op"
            (operator / "credentials").mkdir(parents=True)
            (operator / "credentials" / "auth.json").write_text("{}", encoding="utf-8")
            (operator / "oauth").mkdir()
            (operator / "device_id").write_text("dev-1", encoding="utf-8")
            bench = root / "bench"

            self.assertTrue(agent_bench.seed_kimi_bench_home(bench, operator))
            self.assertTrue((bench / "credentials").is_symlink())
            self.assertEqual((bench / "credentials").resolve(), (operator / "credentials").resolve())
            self.assertTrue((bench / "oauth").is_symlink())
            self.assertFalse((bench / "device_id").is_symlink())
            self.assertEqual((bench / "device_id").read_text(encoding="utf-8"), "dev-1")

    def test_seed_kimi_bench_home_reports_missing_auth(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            operator = root / "op"
            operator.mkdir()
            self.assertFalse(agent_bench.seed_kimi_bench_home(root / "bench", operator))

    def test_latest_kimi_session_id_returns_last_entry(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = pathlib.Path(tmp)
            (home / "session_index.jsonl").write_text(
                json.dumps({"sessionId": "session_one"}) + "\n"
                + json.dumps({"id": "session_two"}) + "\n",
                encoding="utf-8",
            )
            self.assertEqual(agent_bench.latest_kimi_session_id(home), "session_two")

    def test_latest_kimi_session_id_none_when_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(agent_bench.latest_kimi_session_id(pathlib.Path(tmp)))

    def test_resume_not_found_in_output_detects_failure(self):
        self.assertTrue(agent_bench.resume_not_found_in_output('Session "session_x" not found'))
        self.assertTrue(agent_bench.resume_not_found_in_output("no such session"))
        self.assertFalse(agent_bench.resume_not_found_in_output("ZENTTY_AGENT_BENCH_OK"))

    def test_resume_not_found_ignores_unrelated_not_found(self):
        # A model mentioning an unrelated missing file must not trip the guard.
        self.assertFalse(agent_bench.resume_not_found_in_output("file not found: foo.txt"))

    def test_resume_detectors_strip_ansi_sequences(self):
        self.assertTrue(
            agent_bench.resume_not_found_in_output('\x1b[31mSession "session_x" not found\x1b[0m')
        )
        self.assertTrue(
            agent_bench.resume_sentinel_in_output("\x1b[32mZENTTY_AGENT_BENCH_OK\x1b[0m")
        )
        self.assertFalse(agent_bench.resume_sentinel_in_output("nothing recalled here"))

    def test_install_kimi_managed_hook_block_is_idempotent(self):
        cfg = 'default_model = "kimi"\n'
        once = agent_bench.install_kimi_managed_hook_block(cfg, "CMD")
        twice = agent_bench.install_kimi_managed_hook_block(once, "CMD")
        self.assertEqual(once, twice)
        self.assertEqual(once.count(agent_bench.KIMI_MANAGED_BEGIN_MARKER), 1)
        self.assertEqual(once.count(agent_bench.KIMI_MANAGED_END_MARKER), 1)
        self.assertIn('default_model = "kimi"', once)
        self.assertIn("[[hooks]]", once)

    def test_kimi_code_profile_defines_resume_roundtrip_scenario(self):
        profile = agent_bench.load_profiles(ROOT / "profiles")["kimi-code"]
        exp = profile.expectations["resume_roundtrip"]
        self.assertTrue(exp.resume_roundtrip)
        # Hooks are absent for the bench-owned custom home, so required_events
        # must be soft/empty or the scenario would fail on missing hook events.
        self.assertEqual(exp.required_events, [])
        self.assertEqual(
            profile.launch_args_by_scenario["resume_roundtrip"],
            ["-p", "Reply with exactly: ZENTTY_AGENT_BENCH_OK"],
        )


class KimiManagedBlockPlanTests(unittest.TestCase):
    def test_modern_kimi_plan_installs_single_managed_block_idempotently(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            home = root / "home"
            (home / ".kimi-code").mkdir(parents=True)
            config_path = home / ".kimi-code" / "config.toml"
            config_path.write_text('default_model = "kimi"\n', encoding="utf-8")
            planner = _modern_kimi_launch_planner(root)

            for _ in range(2):
                planner._plan_kimi("/usr/bin/kimi", ["-p", "hi"], {"HOME": str(home)}, "/usr/bin/zentty")

            config = config_path.read_text(encoding="utf-8")
            self.assertEqual(config.count(agent_bench.KIMI_MANAGED_BEGIN_MARKER), 1)
            self.assertEqual(config.count(agent_bench.KIMI_MANAGED_END_MARKER), 1)
            self.assertIn('default_model = "kimi"', config)
            self.assertIn("[[hooks]]", config)

    def test_modern_kimi_plan_skips_install_for_custom_home(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            custom = root / "custom-kimi"
            custom.mkdir()
            config_path = custom / "config.toml"
            config_path.write_text('default_model = "kimi"\n', encoding="utf-8")
            planner = _modern_kimi_launch_planner(root)

            plan = planner._plan_kimi(
                "/usr/bin/kimi",
                ["-p", "hi"],
                {"HOME": str(root / "home"), "KIMI_CODE_HOME": str(custom)},
                "/usr/bin/zentty",
            )

            # A genuine custom home is NOT modified, and its home is not stripped.
            self.assertEqual(config_path.read_text(encoding="utf-8"), 'default_model = "kimi"\n')
            self.assertEqual(plan["unsetEnvironment"], [])


class KimiResumeRoundtripTests(unittest.TestCase):
    def _profiles(self):
        return {
            "kimi-code": agent_bench.AgentProfile(
                name="kimi-code",
                command="kimi",
                real_binary_names=["kimi"],
                version_args=["--version"],
                launch_args_by_scenario={"resume_roundtrip": ["-p", "Reply with exactly: ZENTTY_AGENT_BENCH_OK"]},
                expectations={
                    "resume_roundtrip": agent_bench.ScenarioExpectation(
                        "resume_roundtrip", [], resume_roundtrip=True
                    )
                },
                tool="kimi",
                kimi_variant="modern",
                skip_patterns=["not authenticated", "sign in"],
            )
        }

    def _build_app(self, root):
        app_path = root / "Zentty.app"
        resources = app_path / "Contents" / "Resources"
        zentty = resources / "bin" / "shared" / "zentty"
        zentty.parent.mkdir(parents=True)
        zentty.write_text("#!/bin/sh\n", encoding="utf-8")
        zentty.chmod(0o755)
        wrapper_dir = resources / "bin" / "kimi"
        wrapper_dir.mkdir(parents=True)
        wrapper = wrapper_dir / "kimi"
        wrapper.write_text("#!/bin/sh\n", encoding="utf-8")
        wrapper.chmod(0o755)
        return app_path, wrapper_dir

    def _operator_home(self, root, with_auth=True):
        home = root / "operator-kimi"
        home.mkdir(parents=True)
        if with_auth:
            (home / "credentials").mkdir()
            (home / "credentials" / "auth.json").write_text("{}", encoding="utf-8")
            (home / "oauth").mkdir()
            (home / "device_id").write_text("dev-123", encoding="utf-8")
        return home

    def _run(self, root, run_pty_impl, with_auth=True):
        app_path, wrapper_dir = self._build_app(root)
        operator_home = self._operator_home(root, with_auth=with_auth)
        real_command = root / "real" / "kimi"
        real_command.parent.mkdir()
        real_command.write_text("#!/bin/sh\n", encoding="utf-8")
        real_command.chmod(0o755)
        args = type(
            "Args",
            (),
            {
                "run_dir": str(root / "run"),
                "app_path": str(app_path),
                "no_build": True,
                "timeout": 30,
                "strict": True,
                "agents": "kimi-code",
                "scenarios": "resume_roundtrip",
            },
        )()
        runner = agent_bench.BenchRunner(args)
        runner._resolved_app_path = app_path
        runner.profiles = self._profiles()
        env = {
            "PATH": str(wrapper_dir),
            "HOME": str(root / "home"),
            "ZENTTY_BENCH_KIMI_SOURCE_HOME": str(operator_home),
        }
        try:
            with mock.patch.object(agent_bench, "resolve_agent_binary", return_value=(str(real_command), None)), \
                 mock.patch.object(agent_bench, "run_pty", side_effect=run_pty_impl):
                return runner._run_resume_roundtrip_scenario("kimi-code", "resume_roundtrip", env)
        finally:
            runner._cleanup_socket_dir()

    def test_resume_roundtrip_passes_when_session_reopens(self):
        session_id = "session_a4d78f91-ea80-41e7-91d3-c699197ff442"
        seen: dict[str, object] = {"command": None, "phase1_cwd": None, "phase2_argv": None, "phase2_cwd": None}

        def fake(argv, env, cwd, inputs, timeout, transcript_path, completion_predicate=None):
            home = pathlib.Path(env["KIMI_CODE_HOME"])
            if "-S" in argv:
                seen["phase2_argv"] = list(argv)
                seen["phase2_cwd"] = cwd
                requested = argv[argv.index("-S") + 1]
                index = home / "session_index.jsonl"
                recorded = index.is_file() and requested in index.read_text(encoding="utf-8")
                # kimi pins sessions to their workdir: only "find" the session
                # when phase 2 runs in the SAME cwd as phase 1.
                same_dir = cwd == seen["phase1_cwd"]
                out = (
                    agent_bench.RESUME_ROUNDTRIP_SENTINEL
                    if (recorded and same_dir)
                    else 'Session "%s" not found' % requested
                )
                return agent_bench.PtyResult(0, False, out)
            seen["command"] = argv[0]
            seen["phase1_cwd"] = cwd
            (home / "session_index.jsonl").write_text(
                json.dumps({"sessionId": session_id, "sessionDir": str(home / "sessions" / "wd" / session_id)}) + "\n",
                encoding="utf-8",
            )
            # Phase 1 output deliberately omits the sentinel so the pass can only
            # come from phase 2 recalling history.
            return agent_bench.PtyResult(0, False, "phase1-ack")

        with tempfile.TemporaryDirectory() as tmp:
            result = self._run(pathlib.Path(tmp), fake)

        self.assertEqual(result.status, "pass", result.detail)
        self.assertEqual(result.result_kind, "resume-pass")
        self.assertIn(f"resumed:{session_id}", result.observed_events)
        # Exact phase-2 argv: a regression to a bogus flag (e.g. --print) fails here.
        self.assertEqual(
            seen["phase2_argv"],
            [seen["command"], "-S", session_id, "--prompt", agent_bench.RESUME_ROUNDTRIP_PROMPT],
        )
        # Both phases must share the workdir (kimi's directory pinning).
        self.assertEqual(seen["phase2_cwd"], seen["phase1_cwd"])

    def test_resume_roundtrip_fails_loudly_when_resume_reports_not_found(self):
        def fake(argv, env, cwd, inputs, timeout, transcript_path, completion_predicate=None):
            home = pathlib.Path(env["KIMI_CODE_HOME"])
            if "-S" in argv:
                # Simulate the overlay regression: recorded session not found.
                return agent_bench.PtyResult(1, False, 'Session "session_x" not found')
            (home / "session_index.jsonl").write_text(
                json.dumps({"sessionId": "session_x"}) + "\n", encoding="utf-8"
            )
            return agent_bench.PtyResult(0, False, "phase1-ack")

        with tempfile.TemporaryDirectory() as tmp:
            result = self._run(pathlib.Path(tmp), fake)

        self.assertEqual(result.status, "fail")
        self.assertEqual(result.result_kind, "resume-not-found")

    def test_resume_roundtrip_fails_when_resume_only_echoes_prompt(self):
        # Guards the false-positive: the phase-2 prompt does not contain the
        # sentinel, so a model that merely echoes the prompt must FAIL.
        def fake(argv, env, cwd, inputs, timeout, transcript_path, completion_predicate=None):
            home = pathlib.Path(env["KIMI_CODE_HOME"])
            if "-S" in argv:
                return agent_bench.PtyResult(0, False, agent_bench.RESUME_ROUNDTRIP_PROMPT)
            (home / "session_index.jsonl").write_text(
                json.dumps({"sessionId": "session_x"}) + "\n", encoding="utf-8"
            )
            return agent_bench.PtyResult(0, False, "phase1-ack")

        with tempfile.TemporaryDirectory() as tmp:
            result = self._run(pathlib.Path(tmp), fake)

        self.assertEqual(result.status, "fail")
        self.assertEqual(result.result_kind, "resume-no-marker")

    def test_resume_roundtrip_fails_when_phase_one_records_no_session(self):
        def fake(argv, env, cwd, inputs, timeout, transcript_path, completion_predicate=None):
            return agent_bench.PtyResult(0, False, "ZENTTY_AGENT_BENCH_OK")

        with tempfile.TemporaryDirectory() as tmp:
            result = self._run(pathlib.Path(tmp), fake)

        self.assertEqual(result.status, "fail")
        self.assertEqual(result.result_kind, "resume-no-session")

    def test_resume_roundtrip_skips_when_auth_absent(self):
        def fake(*args, **kwargs):
            raise AssertionError("run_pty must not run when auth cannot be seeded")

        with tempfile.TemporaryDirectory() as tmp:
            result = self._run(pathlib.Path(tmp), fake, with_auth=False)

        self.assertEqual(result.result_kind, "auth-skip")


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
    def test_devin_config_override_resolves_against_launch_directory(self):
        for relative in (True, False):
            for equals_form in (True, False):
                with self.subTest(relative=relative, equals_form=equals_form), tempfile.TemporaryDirectory() as tmp:
                    root = pathlib.Path(tmp)
                    source = root / "devin.json"
                    original = '{"model": "custom-model"}'
                    source.write_text(original, encoding="utf-8")
                    config_path = "./devin.json" if relative else str(source)
                    arguments = [f"--config={config_path}"] if equals_form else ["--config", config_path]
                    profile = agent_bench.load_profiles(ROOT / "profiles")["devin"]
                    planner = agent_bench.LaunchPlanner(
                        profile=profile, scenario="smoke", run_dir=root / "run", resources_dir=None,
                    )

                    plan = planner._plan_devin(
                        "/usr/bin/devin", [*arguments, "-p", "hello"],
                        {"PWD": str(root)}, "/usr/bin/zentty",
                    )

                    config = json.loads(pathlib.Path(plan["arguments"][1]).read_text())
                    self.assertEqual(config.get("model"), "custom-model")
                    self.assertIn("SessionStart", config["hooks"])
                    self.assertEqual(plan["arguments"][2:], ["-p", "hello"])
                    self.assertEqual(source.read_text(), original)

    def test_devin_config_extraction_preserves_arguments_after_separator(self):
        for prompt in (["--config=example.json"], ["--config", "example.json"]):
            for prefix, expected_source in (([], None), (["--config", "real.json"], "real.json")):
                with self.subTest(prompt=prompt, prefix=prefix):
                    forwarded = ["-p", "--", *prompt]
                    self.assertEqual(
                        agent_bench._extract_devin_config_override([*prefix, *forwarded]),
                        (forwarded, expected_source),
                    )

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

    def test_small_harness_plan_writes_managed_hooks_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            profile = agent_bench.AgentProfile(
                name="small-harness",
                command="small-harness",
                real_binary_names=["small-harness"],
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
                    "arguments": ["--print", "hello"],
                    "environment": {
                        "ZENTTY_REAL_BINARY": "/usr/local/bin/small-harness",
                        "ZENTTY_CLI_BIN": "/tmp/zentty",
                        "ZENTTY_INSTANCE_SOCKET": "/tmp/zentty socket",
                        "ZENTTY_WINDOW_ID": "window-main",
                        "ZENTTY_WORKLANE_ID": "worklane-main",
                        "ZENTTY_PANE_ID": "pane-main",
                        "ZENTTY_PANE_TOKEN": "pane token",
                        "ZENTTY_INSTANCE_ID": "instance-main",
                    },
                }
            )

            hooks_path = pathlib.Path(plan["setEnvironment"]["SMALL_HARNESS_MANAGED_HOOKS_FILE"])
            hooks = json.loads(hooks_path.read_text(encoding="utf-8"))

            self.assertEqual(plan["arguments"], ["--print", "hello"])
            self.assertEqual(plan["setEnvironment"]["ZENTTY_AGENT_TOOL"], "small-harness")
            self.assertIn("SMALL_HARNESS_MANAGED_HOOKS_JSON", plan["unsetEnvironment"])
            self.assertEqual(hooks["source"], "zentty")
            self.assertIn("PlanUpdated", hooks["hooks"])
            self.assertIn("SubagentStart", hooks["hooks"])
            self.assertIn("SubagentStop", hooks["hooks"])
            command = hooks["hooks"]["SessionStart"][0]["hooks"][0]["command"]
            self.assertIn("--adapter=small-harness", command)
            self.assertNotIn("/tmp/zentty socket", command)
            self.assertNotIn("pane token", command)
            self.assertEqual(
                hooks["hooks"]["SessionStart"][0]["hooks"][0]["envVars"],
                [
                    "ZENTTY_INSTANCE_SOCKET",
                    "ZENTTY_WINDOW_ID",
                    "ZENTTY_WORKLANE_ID",
                    "ZENTTY_PANE_ID",
                    "ZENTTY_PANE_TOKEN",
                    "ZENTTY_INSTANCE_ID",
                    "ZENTTY_SMALL_HARNESS_PID",
                ],
            )

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


class ManifestAgentTests(unittest.TestCase):
    def _kilo_manifest(self) -> dict:
        return json.loads(
            (agent_bench.REPO_ROOT / "ZenttyResources" / "agents" / "kilo.json").read_text(encoding="utf-8")
        )

    def _generic_canonical_manifest(self) -> dict:
        return json.loads(
            (ROOT / "fixtures" / "generic-canonical" / "agents" / "generic-canonical.json").read_text(encoding="utf-8")
        )

    def _profile(self, name: str, tool: str, command: str) -> agent_bench.AgentProfile:
        return agent_bench.AgentProfile(
            name=name,
            tool=tool,
            command=command,
            real_binary_names=[command],
            version_args=["--version"],
            launch_args_by_scenario={},
            expectations={},
        )

    def test_manifest_wrapper_script_matches_swift_template(self):
        swift = (agent_bench.REPO_ROOT / "Zentty" / "AppState" / "Agent" / "AgentManifestWrapperMaterializer.swift").read_text(
            encoding="utf-8"
        )
        marker = swift.index("wrapperScript")
        start = swift.index('"""', marker) + 3
        end = swift.index('"""', start)
        lines = swift[start:end].split("\n")
        # Swift strips the closing delimiter's indentation from every line.
        closing_indent = lines[-1]
        body = [line[len(closing_indent):] for line in lines[1:-1]]
        template = "\n".join(body)

        tool_id, binaries, support_dir = "kilo", ["kilo", "kilo-cli"], "/support/dir"
        expected = (
            template
            .replace("\\(toolID)", tool_id)
            .replace('\\(binaries.joined(separator: ":"))', ":".join(binaries))
            .replace("\\(supportDirectory)", support_dir)
        )
        self.assertEqual(
            agent_bench.manifest_wrapper_script(tool_id, binaries, support_dir),
            expected,
        )

    def test_load_agent_manifests_later_dirs_override_bundled(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            resources = root / "resources"
            (resources / "agents").mkdir(parents=True)
            (resources / "agents" / "kilo.json").write_text(
                json.dumps({"id": "kilo", "displayName": "Bundled Kilo"}), encoding="utf-8"
            )
            override = root / "override"
            override.mkdir()
            (override / "kilo.json").write_text(
                json.dumps({"id": "kilo", "displayName": "Override Kilo"}), encoding="utf-8"
            )
            (override / "broken.json").write_text("not json{", encoding="utf-8")

            manifests = agent_bench.load_agent_manifests(resources, [override])

            self.assertEqual(sorted(manifests), ["kilo"])
            self.assertEqual(manifests["kilo"]["displayName"], "Override Kilo")

    def test_manifest_dirs_from_environment_splits_colon_list(self):
        dirs = agent_bench.manifest_dirs_from_environment(
            {"ZENTTY_AGENT_MANIFEST_DIRS": "/a/b:/c/d"}
        )
        self.assertEqual(dirs, [pathlib.Path("/a/b"), pathlib.Path("/c/d")])
        self.assertEqual(agent_bench.manifest_dirs_from_environment({}), [])

    def test_materialize_manifest_wrappers_writes_executable_per_binary(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp) / "agent-wrappers"
            manifests = {
                "kilo": {"id": "kilo", "binaries": ["kilo", "kilo-cli"]},
            }
            directories = agent_bench.materialize_manifest_wrappers(
                manifests, root, pathlib.Path("/support/zentty-agent-wrapper")
            )

            self.assertEqual(directories, {"kilo": root / "kilo"})
            for binary in ("kilo", "kilo-cli"):
                script = root / "kilo" / binary
                self.assertTrue(os.access(script, os.X_OK))
                contents = script.read_text(encoding="utf-8")
                self.assertIn('export ZENTTY_AGENT_TOOL="kilo"', contents)
                self.assertIn('export ZENTTY_AGENT_REAL_BINARIES="kilo:kilo-cli"', contents)
                self.assertIn("zentty-agent-wrapper", contents)

    def test_missing_manifest_wrapper_reports_absent_and_present(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            profile = self._profile("kilo", "kilo", "kilo")

            self.assertIsNotNone(agent_bench.missing_manifest_wrapper(None, profile))
            self.assertIsNotNone(
                agent_bench.missing_manifest_wrapper(root / "nope", profile)
            )

            wrapper_dir = root / "kilo"
            wrapper_dir.mkdir()
            self.assertIsNotNone(
                agent_bench.missing_manifest_wrapper(wrapper_dir, profile)
            )

            script = wrapper_dir / "kilo"
            script.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
            script.chmod(0o755)
            self.assertIsNone(agent_bench.missing_manifest_wrapper(wrapper_dir, profile))

    def test_agent_from_adapter_maps_manifest_display_name(self):
        manifests = {
            "kilo": {"id": "kilo", "displayName": "Kilo Code"},
            "generic-canonical": {"id": "generic-canonical", "displayName": "Bench Canonical Agent"},
        }
        agent = agent_bench.agent_from_adapter(
            adapter=None,
            environment={},
            standard_input='{"version":1,"event":"agent.running","agent":{"name":"Kilo Code"}}',
            manifests=manifests,
        )
        self.assertEqual(agent, "kilo")

        agent = agent_bench.agent_from_adapter(
            adapter=None,
            environment={},
            standard_input='{"version":1,"event":"agent.running","agent":{"name":"Bench Canonical Agent"}}',
            manifests=manifests,
        )
        self.assertEqual(agent, "generic-canonical")

    def test_plan_manifest_opencode_family_mirrors_kilo_overlay(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            resources = root / "resources"
            plugin = resources / "opencode" / "plugins" / "zentty-opencode-zentty.js"
            plugin.parent.mkdir(parents=True)
            plugin.write_text("// plugin\n", encoding="utf-8")

            source = root / "source-config"
            source.mkdir()

            plan = agent_bench.LaunchPlanner(
                profile=self._profile("kilo", "kilo", "kilo"),
                scenario="smoke",
                run_dir=root / "run",
                resources_dir=resources,
                manifests={"kilo": self._kilo_manifest()},
            ).plan(
                {
                    "arguments": ["run", "hi"],
                    "environment": {
                        "ZENTTY_REAL_BINARY": "/usr/local/bin/kilo",
                        "ZENTTY_CLI_BIN": "/tmp/zentty",
                        "KILO_CONFIG_DIR": str(source),
                    },
                }
            )

            set_env = plan["setEnvironment"]
            overlay = pathlib.Path(set_env["KILO_CONFIG_DIR"])
            self.assertEqual(overlay, root / "run" / "overlays" / "smoke" / "kilo" / "config")
            self.assertTrue((overlay / "plugins" / "zentty-opencode-zentty.js").exists())
            self.assertEqual(set_env["KILO_CONFIG"], str(overlay / "kilo.json"))
            self.assertEqual(set_env["ZENTTY_KILO_BASE_CONFIG_DIR"], str(source))
            self.assertEqual(set_env["ZENTTY_AGENT_TOOL"], "kilo")
            self.assertEqual(set_env["ZENTTY_AGENT_CANONICAL_NAME"], "Kilo Code")
            session_start = json.loads(plan["preLaunchActions"][0]["standardInput"])
            self.assertEqual(session_start["event"], "session.start")
            self.assertEqual(session_start["agent"]["name"], "Kilo Code")

    def test_plan_manifest_opencode_family_approval_writes_kilo_permission(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            resources = root / "resources"
            plugin = resources / "opencode" / "plugins" / "zentty-opencode-zentty.js"
            plugin.parent.mkdir(parents=True)
            plugin.write_text("// plugin\n", encoding="utf-8")

            source = root / "source-config"
            source.mkdir()
            (source / "kilo.json").write_text('{"autoupdate":true}\n', encoding="utf-8")

            plan = agent_bench.LaunchPlanner(
                profile=self._profile("kilo", "kilo", "kilo"),
                scenario="approval",
                run_dir=root / "run",
                resources_dir=resources,
                manifests={"kilo": self._kilo_manifest()},
            ).plan(
                {
                    "arguments": [],
                    "environment": {
                        "ZENTTY_CLI_BIN": "/tmp/zentty",
                        "KILO_CONFIG_DIR": str(source),
                    },
                }
            )

            overlay = pathlib.Path(plan["setEnvironment"]["KILO_CONFIG_DIR"])
            merged = json.loads((overlay / "kilo.json").read_text(encoding="utf-8"))
            self.assertTrue(merged["autoupdate"])
            self.assertEqual(merged["permission"]["bash"], "ask")

    def test_plan_manifest_canonical_expands_clibin_and_prelaunches(self):
        plan = agent_bench.LaunchPlanner(
            profile=self._profile("generic-canonical", "generic-canonical", "zentty-bench-agent"),
            scenario="smoke",
            run_dir=pathlib.Path(tempfile.mkdtemp()),
            resources_dir=None,
            manifests={"generic-canonical": self._generic_canonical_manifest()},
        ).plan(
            {
                "arguments": ["printf", "hi"],
                "environment": {"ZENTTY_CLI_BIN": "/app/bin/zentty"},
            }
        )

        self.assertEqual(plan["arguments"], ["printf", "hi"])
        self.assertEqual(plan["setEnvironment"]["ZENTTY_AGENT_TOOL"], "generic-canonical")
        self.assertEqual(
            plan["setEnvironment"]["ZENTTY_AGENT_CANONICAL_NAME"], "Bench Canonical Agent"
        )
        self.assertEqual(
            plan["setEnvironment"]["BENCH_AGENT_EVENT_COMMAND"],
            "/app/bin/zentty ipc agent-event",
        )
        session_start = json.loads(plan["preLaunchActions"][0]["standardInput"])
        self.assertEqual(session_start["agent"]["name"], "Bench Canonical Agent")

    def test_plan_manifest_canonical_without_cli_bin_degrades_to_direct(self):
        plan = agent_bench.LaunchPlanner(
            profile=self._profile("generic-canonical", "generic-canonical", "zentty-bench-agent"),
            scenario="smoke",
            run_dir=pathlib.Path(tempfile.mkdtemp()),
            resources_dir=None,
            manifests={"generic-canonical": self._generic_canonical_manifest()},
        ).plan({"arguments": ["--version"], "environment": {}})

        self.assertEqual(plan["arguments"], ["--version"])
        self.assertEqual(plan["preLaunchActions"], [])
        self.assertNotIn("BENCH_AGENT_EVENT_COMMAND", plan["setEnvironment"])

    def test_unknown_tool_without_manifest_falls_back_to_direct_plan(self):
        plan = agent_bench.LaunchPlanner(
            profile=self._profile("mystery", "mystery", "mystery"),
            scenario="smoke",
            run_dir=pathlib.Path(tempfile.mkdtemp()),
            resources_dir=None,
            manifests={},
        ).plan({"arguments": [], "environment": {"ZENTTY_CLI_BIN": "/x"}})

        self.assertEqual(plan["setEnvironment"], {"ZENTTY_AGENT_TOOL": "mystery"})


if __name__ == "__main__":
    unittest.main()
