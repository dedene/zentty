use zentty_core::agent::{AgentInteractionClassifier, AgentInteractionKind, AgentTool};

#[test]
fn agent_interaction_classifier_recognizes_attention_notifications() {
    let cases = [
        (
            "Approval requested: npm publish",
            AgentInteractionKind::Approval,
        ),
        (
            "Codex wants to edit Sources/App.swift",
            AgentInteractionKind::Approval,
        ),
        (
            "Question requested: Choose deployment target",
            AgentInteractionKind::Decision,
        ),
        ("Questions requested: 2", AgentInteractionKind::Decision),
        (
            "Plan mode prompt: Implement this plan?",
            AgentInteractionKind::Approval,
        ),
        ("What should Codex do next?", AgentInteractionKind::Question),
        ("Action required", AgentInteractionKind::Approval),
    ];

    for (message, kind) in cases {
        assert!(AgentInteractionClassifier::requires_human_input(Some(
            message
        )));
        assert_eq!(
            AgentInteractionClassifier::interaction_kind(Some(message)),
            Some(kind)
        );
    }
}

#[test]
fn agent_tool_resolution_matches_hook_and_metadata_rules() {
    assert_eq!(AgentTool::resolve(Some("amp")), Some(AgentTool::Amp));
    assert_eq!(
        AgentTool::resolve(Some("amp - Greeting")),
        Some(AgentTool::Amp)
    );
    assert_eq!(
        AgentTool::resolve(Some("feature/amp")),
        Some(AgentTool::Custom("feature/amp".to_string()))
    );
    assert_eq!(
        AgentTool::resolve_known(Some("/Users/peter/Development/worktrees/feature/amp")),
        None
    );

    assert_eq!(
        AgentTool::resolve(Some("copilot")),
        Some(AgentTool::Copilot)
    );
    assert_eq!(AgentTool::resolve_known(Some("copilot")), None);
    assert_eq!(
        AgentTool::resolve(Some("opencode")),
        Some(AgentTool::OpenCode)
    );

    assert_eq!(
        AgentTool::resolve(Some("π - myproject")),
        Some(AgentTool::Pi)
    );
    assert_eq!(
        AgentTool::resolve(Some("⠋ π - myproject")),
        Some(AgentTool::Pi)
    );
    assert_eq!(
        AgentTool::resolve(Some("pip")),
        Some(AgentTool::Custom("pip".to_string()))
    );
    assert_eq!(AgentTool::resolve_known(Some("python pi.py")), None);
}
