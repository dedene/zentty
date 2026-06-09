use std::fs;

use zentty_core::agent::AgentTool;
use zentty_core::layout::{PaneColumnId, PaneId};
use zentty_core::restore::{
    AgentLaunchSnapshot, AgentResumeCommandBuilder, ClosedPaneAgentSnapshot, ClosedPaneCwdResolver,
    ClosedPaneEntry, ClosedPaneRestoreCommand, ClosedPaneRestoreCommandResolver, ClosedPaneStack,
    PaneRestoreDraft, PaneRestoreDraftKind,
};

#[test]
fn closed_pane_stack_returns_most_recent_non_expired_entry() {
    let mut stack = ClosedPaneStack::default();
    let first = make_entry(1, 10_000.0);
    let second = make_entry(2, 10_001.0);

    stack.push(first.clone(), 10_000.0);
    stack.push(second.clone(), 10_001.0);

    assert_eq!(
        stack.pop_latest(10_002.0).map(|entry| entry.id),
        Some(second.id)
    );
    assert_eq!(
        stack.pop_latest(10_002.0).map(|entry| entry.id),
        Some(first.id)
    );
    assert_eq!(stack.pop_latest(10_002.0), None);
}

#[test]
fn closed_pane_stack_applies_capacity_and_expiry_like_swift() {
    let mut capped = ClosedPaneStack::new(3, ClosedPaneStack::DEFAULT_EXPIRY_SECONDS);
    for index in 0..4 {
        capped.push(make_entry(index, index as f64), 0.0);
    }

    assert_eq!(capped.count(), 3);
    let titles: Vec<_> = (0..3)
        .filter_map(|_| capped.pop_latest(10.0))
        .map(|entry| entry.title)
        .collect();
    assert_eq!(titles, ["title-3", "title-2", "title-1"]);

    let mut expiring = ClosedPaneStack::new(5, 60.0 * 60.0);
    expiring.push(make_entry(1, 0.0), 0.0);
    expiring.push(make_entry(2, 60.0 * 30.0), 60.0 * 30.0);

    assert_eq!(
        expiring.pop_latest(60.0 * 70.0).map(|entry| entry.id),
        Some("entry-2".to_string())
    );
    assert_eq!(expiring.pop_latest(60.0 * 70.0), None);
}

#[test]
fn closed_pane_stack_peek_ignores_stale_entries_without_mutating() {
    let mut stack = ClosedPaneStack::new(5, 100.0);
    stack.push(make_entry(1, 0.0), 0.0);
    stack.push(make_entry(2, 50.0), 50.0);

    assert_eq!(
        stack.peek(110.0).map(|entry| entry.title.as_str()),
        Some("title-2")
    );
    stack.prune(110.0);

    assert_eq!(stack.count(), 1);
    assert_eq!(
        stack.peek(110.0).map(|entry| entry.title.as_str()),
        Some("title-2")
    );
}

#[test]
fn restore_command_resolver_matches_agent_and_replay_rules() {
    let claude = make_entry_with_agent(
        Some(ClosedPaneAgentSnapshot {
            tool: AgentTool::ClaudeCode,
            tool_display_name: "Claude Code".to_string(),
            session_id: Some("237d8c32-2a27-4850-8da8-3a110f13682c".to_string()),
            working_directory: Some("/tmp/project".to_string()),
            agent_launch_snapshot: None,
        }),
        None,
        None,
    );
    assert_eq!(
        ClosedPaneRestoreCommandResolver::resolve(&claude),
        ClosedPaneRestoreCommand::AgentResume {
            command: "claude --resume 237d8c32-2a27-4850-8da8-3a110f13682c".to_string(),
            tool: AgentTool::ClaudeCode,
            session_id: Some("237d8c32-2a27-4850-8da8-3a110f13682c".to_string()),
        }
    );

    let invalid_claude = make_entry_with_agent(
        Some(ClosedPaneAgentSnapshot {
            tool: AgentTool::ClaudeCode,
            tool_display_name: "Claude Code".to_string(),
            session_id: Some("not-a-uuid".to_string()),
            working_directory: None,
            agent_launch_snapshot: None,
        }),
        Some("claude".to_string()),
        None,
    );
    assert_eq!(
        ClosedPaneRestoreCommandResolver::resolve(&invalid_claude),
        ClosedPaneRestoreCommand::ReplayCommand("claude".to_string())
    );

    let gemini = make_entry_with_agent(
        Some(ClosedPaneAgentSnapshot {
            tool: AgentTool::Gemini,
            tool_display_name: "Gemini".to_string(),
            session_id: None,
            working_directory: None,
            agent_launch_snapshot: None,
        }),
        None,
        None,
    );
    assert_eq!(
        ClosedPaneRestoreCommandResolver::resolve(&gemini),
        ClosedPaneRestoreCommand::AgentResume {
            command: "gemini --resume".to_string(),
            tool: AgentTool::Gemini,
            session_id: None,
        }
    );

    let native = make_entry_with_agent(None, Some("vim README.md".to_string()), None);
    assert_eq!(
        ClosedPaneRestoreCommandResolver::resolve(&native),
        ClosedPaneRestoreCommand::ReplayCommand("vim README.md".to_string())
    );

    let command = make_entry_with_agent(None, None, Some("npm run dev".to_string()));
    assert_eq!(
        ClosedPaneRestoreCommandResolver::resolve(&command),
        ClosedPaneRestoreCommand::ReplayCommand("npm run dev".to_string())
    );

    assert_eq!(
        ClosedPaneRestoreCommandResolver::resolve(&make_entry_with_agent(None, None, None)),
        ClosedPaneRestoreCommand::PlainShell
    );
}

#[test]
fn agent_resume_command_builder_matches_swift_security_matrix() {
    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Amp,
            "Amp",
            "T-ZenttyBenchRestore",
            Some("/tmp/project"),
            None,
        )),
        Some("amp threads continue T-ZenttyBenchRestore".to_string())
    );
    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Amp,
            "Amp",
            "T-ZenttyBenchRestore",
            Some("/tmp/project"),
            Some(AgentLaunchSnapshot::new(vec![
                "--mode",
                "smart",
                "--effort",
                "high",
                "--settings-file",
                "/tmp/amp settings.json",
            ])),
        )),
        Some(
            "amp threads continue --mode smart --effort high --settings-file '/tmp/amp settings.json' T-ZenttyBenchRestore"
                .to_string()
        )
    );
    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Amp,
            "Amp",
            "T-safe; rm -rf /",
            Some("/tmp/project"),
            None,
        )),
        None
    );
    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Amp,
            "Amp",
            "T-ZenttyBenchRestore",
            Some("/tmp/project"),
            Some(AgentLaunchSnapshot::new(vec!["--execute=echo hi"])),
        )),
        None
    );

    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::ClaudeCode,
            "Claude Code",
            "237d8c32-2a27-4850-8da8-3a110f13682c",
            Some("/tmp/project"),
            None,
        )),
        Some("claude --resume 237d8c32-2a27-4850-8da8-3a110f13682c".to_string())
    );
    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::ClaudeCode,
            "Claude Code",
            "cli-pane-management",
            Some("/tmp/project"),
            None,
        )),
        None
    );

    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Codex,
            "Codex",
            "add-faq-section-landing",
            Some("/tmp/project"),
            None,
        )),
        Some("codex resume add-faq-section-landing".to_string())
    );
    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Codex,
            "Codex",
            "session; rm -rf /",
            Some("/tmp/project"),
            None,
        )),
        None
    );

    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::OpenCode,
            "OpenCode",
            "ses_28352bf9bffep9wfuql3YqyHlr",
            Some("/tmp/project"),
            None,
        )),
        Some("opencode --session ses_28352bf9bffep9wfuql3YqyHlr".to_string())
    );
    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::OpenCode,
            "OpenCode",
            "ses_bad; rm -rf /",
            Some("/tmp/project"),
            None,
        )),
        None
    );

    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Copilot,
            "Copilot",
            "0cb916db-26aa-40f2-86b5-1ba81b225fd2",
            Some("/tmp/project"),
            None,
        )),
        Some("copilot --resume=0cb916db-26aa-40f2-86b5-1ba81b225fd2".to_string())
    );
    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Cursor,
            "Cursor",
            "0CB916DB-26AA-40F2-86B5-1BA81B225FD2",
            Some("/tmp/project"),
            None,
        )),
        Some("cursor-agent --resume=0cb916db-26aa-40f2-86b5-1ba81b225fd2".to_string())
    );
    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Kimi,
            "Kimi",
            "0cb916db-26aa-40f2-86b5-1ba81b225fd2",
            Some("/tmp/project"),
            None,
        )),
        Some("kimi -r 0cb916db-26aa-40f2-86b5-1ba81b225fd2".to_string())
    );

    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Grok,
            "Grok",
            "0CB916DB-26AA-40F2-86B5-1BA81B225FD2",
            Some("/tmp/project"),
            None,
        )),
        Some("grok --resume 0cb916db-26aa-40f2-86b5-1ba81b225fd2".to_string())
    );
    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Grok,
            "Grok",
            "abc;rm -rf /",
            Some("/tmp/project"),
            None,
        )),
        Some("grok --resume".to_string())
    );
    assert_eq!(
        AgentResumeCommandBuilder::command(draft(AgentTool::Grok, "Grok", "", None, None)),
        None
    );

    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Gemini,
            "Gemini",
            "",
            Some("/tmp/project"),
            None,
        )),
        Some("gemini --resume".to_string())
    );
    assert_eq!(
        AgentResumeCommandBuilder::command(draft(AgentTool::Gemini, "Gemini", "", None, None)),
        None
    );
    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Pi,
            "Pi",
            "",
            Some("/tmp/project"),
            None,
        )),
        Some("pi -c".to_string())
    );

    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Agy,
            "agy",
            "conversation-123",
            Some("/tmp/project"),
            None,
        )),
        Some("agy --conversation conversation-123".to_string())
    );
    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Agy,
            "agy",
            "",
            Some("/tmp/project"),
            None
        )),
        Some("agy --continue".to_string())
    );
    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Agy,
            "agy",
            "zentty-placeholder-cbec30aa-f6c2-4b1c-aa7f-f6569c2e0c1d",
            Some("/tmp/project"),
            None,
        )),
        Some("agy --continue".to_string())
    );
    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Agy,
            "agy",
            "sess; rm -rf /",
            Some("/tmp/project"),
            None,
        )),
        None
    );

    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Hermes,
            "Hermes Agent",
            "hermes-session-123",
            Some("/tmp/project"),
            Some(AgentLaunchSnapshot::new(vec![
                "--tui",
                "--model",
                "anthropic/claude-sonnet-4.6",
            ])),
        )),
        Some(
            "hermes --tui --model anthropic/claude-sonnet-4.6 --resume hermes-session-123"
                .to_string()
        )
    );
    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Hermes,
            "Hermes Agent",
            "hermes-session-123",
            Some("/tmp/project"),
            Some(
                AgentLaunchSnapshot::new(vec![
                    "chat",
                    "--tui",
                    "--resume",
                    "old-session",
                    "--model",
                    "anthropic/claude-sonnet-4.6",
                ])
                .with_environment("HERMES_HOME", "/tmp/hermes profile")
            ),
        )),
        Some(
            "env HERMES_HOME='/tmp/hermes profile' hermes --tui --model anthropic/claude-sonnet-4.6 --resume hermes-session-123"
                .to_string()
        )
    );
    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Hermes,
            "Hermes Agent",
            "hermes-session-123",
            Some("/tmp/project"),
            Some(AgentLaunchSnapshot::new(vec!["--oneshot", "fix this"])),
        )),
        None
    );
    assert_eq!(
        AgentResumeCommandBuilder::command(draft(
            AgentTool::Hermes,
            "Hermes Agent",
            "session; rm -rf /",
            Some("/tmp/project"),
            None,
        )),
        None
    );
}

#[test]
fn cwd_resolver_uses_existing_path_or_first_existing_ancestor() {
    let root = std::env::temp_dir().join(format!("zentty-restore-rust-{}", std::process::id()));
    let parent = root.join("parent");
    fs::create_dir_all(&parent).expect("temporary parent should be created");
    let missing = parent.join("does-not-exist").join("feature-x");

    let existing =
        ClosedPaneCwdResolver::resolve(Some(parent.to_string_lossy().as_ref()), "/home/user");
    assert_eq!(existing.path, parent.to_string_lossy());
    assert!(!existing.original_missing);

    let ancestor =
        ClosedPaneCwdResolver::resolve(Some(missing.to_string_lossy().as_ref()), "/home/user");
    assert_eq!(ancestor.path, parent.to_string_lossy());
    assert!(ancestor.original_missing);

    let fallback = ClosedPaneCwdResolver::resolve(Some("   "), "/home/user");
    assert_eq!(fallback.path, "/home/user");
    assert!(fallback.original_missing);

    fs::remove_dir_all(root).ok();
}

fn make_entry(id_seed: i32, closed_at: f64) -> ClosedPaneEntry {
    ClosedPaneEntry {
        id: format!("entry-{id_seed}"),
        closed_at,
        original_pane_id: PaneId::from(format!("pn_{id_seed}")),
        original_worklane_id: format!("wl_{id_seed}"),
        original_column_id: PaneColumnId::from(format!("col_{id_seed}")),
        original_column_index: 0,
        original_pane_index: 0,
        original_column_width: 600.0,
        original_height_in_column: None,
        title: format!("title-{id_seed}"),
        working_directory: Some(format!("/tmp/{id_seed}")),
        original_native_command: None,
        original_command: None,
        agent_snapshot: None,
        scrollback_text: None,
    }
}

fn make_entry_with_agent(
    agent_snapshot: Option<ClosedPaneAgentSnapshot>,
    native_command: Option<String>,
    command: Option<String>,
) -> ClosedPaneEntry {
    ClosedPaneEntry {
        agent_snapshot,
        original_native_command: native_command,
        original_command: command,
        ..make_entry(10, 0.0)
    }
}

fn draft(
    tool: AgentTool,
    tool_name: &str,
    session_id: &str,
    working_directory: Option<&str>,
    agent_launch_snapshot: Option<AgentLaunchSnapshot>,
) -> PaneRestoreDraft {
    PaneRestoreDraft {
        pane_id: format!("pane-{}", tool_name.to_lowercase()),
        kind: PaneRestoreDraftKind::AgentResume,
        tool,
        tool_name: tool_name.to_string(),
        session_id: session_id.to_string(),
        working_directory: working_directory.map(str::to_string),
        tracked_pid: 4242,
        agent_launch_snapshot,
    }
}
