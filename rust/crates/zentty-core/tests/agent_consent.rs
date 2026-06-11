use std::collections::BTreeSet;

use zentty_core::agent::{
    AgentBootstrapTool, AgentIntegrationClass, AgentIntegrationConsent, AgentIntegrationDecision,
    AgentIntegrationGate, AgentIntegrationState,
};

#[test]
fn consent_groups_cover_every_bootstrap_tool_once() {
    let all_tools: BTreeSet<_> = AgentBootstrapTool::all().iter().copied().collect();
    let grouped_tools: BTreeSet<_> = AgentIntegrationConsent::all_tools()
        .iter()
        .copied()
        .collect();

    assert_eq!(grouped_tools, all_tools);
    assert_eq!(
        AgentIntegrationConsent::all_tools().len(),
        AgentBootstrapTool::all().len()
    );

    for tool in AgentIntegrationConsent::persistent_tools() {
        assert_eq!(tool.integration_class(), AgentIntegrationClass::Persistent);
    }
    for tool in AgentIntegrationConsent::ephemeral_tools() {
        assert_eq!(tool.integration_class(), AgentIntegrationClass::Ephemeral);
    }
}

#[test]
fn integration_defaults_match_swift_consent_policy() {
    assert_eq!(
        AgentBootstrapTool::Grok.default_integration_state(),
        AgentIntegrationState::Ask
    );
    assert_eq!(
        AgentBootstrapTool::Agy.default_integration_state(),
        AgentIntegrationState::Ask
    );
    assert_eq!(
        AgentBootstrapTool::Amp.default_integration_state(),
        AgentIntegrationState::Ask
    );
    assert_eq!(
        AgentBootstrapTool::Claude.default_integration_state(),
        AgentIntegrationState::On
    );
    assert_eq!(
        AgentBootstrapTool::Kimi.default_integration_state(),
        AgentIntegrationState::On
    );
    assert_eq!(
        AgentBootstrapTool::Copilot.default_integration_state(),
        AgentIntegrationState::On
    );
}

#[test]
fn consent_gate_matrix_matches_swift_behavior() {
    assert_eq!(
        AgentIntegrationConsent::effective_state(AgentBootstrapTool::Grok, None),
        AgentIntegrationState::Ask
    );
    assert_eq!(
        AgentIntegrationConsent::effective_state(
            AgentBootstrapTool::Grok,
            Some(AgentIntegrationState::On)
        ),
        AgentIntegrationState::On
    );
    assert_eq!(
        AgentIntegrationConsent::effective_state(AgentBootstrapTool::Claude, None),
        AgentIntegrationState::On
    );

    assert_eq!(
        AgentIntegrationConsent::gate(AgentBootstrapTool::Agy, None, false),
        AgentIntegrationGate::NeedsConsent
    );
    assert_eq!(
        AgentIntegrationConsent::gate(AgentBootstrapTool::Agy, None, true),
        AgentIntegrationGate::SuppressedByRestore
    );
    assert_eq!(
        AgentIntegrationConsent::gate(
            AgentBootstrapTool::Agy,
            Some(AgentIntegrationState::On),
            false
        ),
        AgentIntegrationGate::Proceed
    );
    assert_eq!(
        AgentIntegrationConsent::gate(
            AgentBootstrapTool::Agy,
            Some(AgentIntegrationState::On),
            true
        ),
        AgentIntegrationGate::Proceed
    );
    assert_eq!(
        AgentIntegrationConsent::gate(
            AgentBootstrapTool::Grok,
            Some(AgentIntegrationState::Off),
            true
        ),
        AgentIntegrationGate::Off
    );
    assert_eq!(
        AgentIntegrationConsent::gate(AgentBootstrapTool::Codex, None, true),
        AgentIntegrationGate::Proceed
    );
    assert_eq!(
        AgentIntegrationConsent::gate(
            AgentBootstrapTool::Claude,
            Some(AgentIntegrationState::Ask),
            false
        ),
        AgentIntegrationGate::Proceed
    );
}

#[test]
fn consent_decisions_have_the_same_immediate_mapping_as_swift() {
    assert_eq!(
        AgentIntegrationGate::Proceed.immediate_decision(),
        Some(AgentIntegrationDecision::Proceed)
    );
    assert_eq!(
        AgentIntegrationGate::Off.immediate_decision(),
        Some(AgentIntegrationDecision::Off)
    );
    assert_eq!(
        AgentIntegrationGate::SuppressedByRestore.immediate_decision(),
        Some(AgentIntegrationDecision::SuppressedByRestore)
    );
    assert_eq!(
        AgentIntegrationGate::NeedsConsent.immediate_decision(),
        None
    );

    assert_eq!(
        AgentIntegrationConsent::decision_for_consent_answer(AgentIntegrationState::On),
        AgentIntegrationDecision::Proceed
    );
    assert_eq!(
        AgentIntegrationConsent::decision_for_consent_answer(AgentIntegrationState::Off),
        AgentIntegrationDecision::Off
    );
    assert_eq!(
        AgentIntegrationConsent::decision_for_consent_answer(AgentIntegrationState::Ask),
        AgentIntegrationDecision::Off
    );
}

#[test]
fn agent_display_names_and_wrapped_command_detection_match_swift() {
    assert_eq!(
        AgentBootstrapTool::Claude.integration_display_name(),
        "Claude Code"
    );
    assert_eq!(
        AgentBootstrapTool::Agy.integration_display_name(),
        "Antigravity"
    );
    assert_eq!(
        AgentBootstrapTool::Opencode.integration_display_name(),
        "OpenCode"
    );

    assert_eq!(
        AgentBootstrapTool::wrapped_agent("grok"),
        Some(AgentBootstrapTool::Grok)
    );
    assert_eq!(
        AgentBootstrapTool::wrapped_agent("claude --resume abc"),
        Some(AgentBootstrapTool::Claude)
    );
    assert_eq!(
        AgentBootstrapTool::wrapped_agent("/usr/local/bin/agy"),
        Some(AgentBootstrapTool::Agy)
    );
    assert_eq!(
        AgentBootstrapTool::wrapped_agent("cursor-agent"),
        Some(AgentBootstrapTool::Cursor)
    );
    assert_eq!(AgentBootstrapTool::wrapped_agent("vim"), None);
    assert_eq!(AgentBootstrapTool::wrapped_agent(""), None);

    assert_eq!(
        AgentBootstrapTool::wrapped_agent(
            "env HERMES_HOME='/tmp/hermes profile' hermes --resume hermes-session-123"
        ),
        Some(AgentBootstrapTool::Hermes)
    );
    assert_eq!(
        AgentBootstrapTool::wrapped_agent(
            "/usr/bin/env HERMES_HOME='/tmp/hermes profile' hermes --resume hermes-session-123"
        ),
        Some(AgentBootstrapTool::Hermes)
    );
    assert_eq!(
        AgentBootstrapTool::wrapped_agent("env FOO=bar vim notes.txt"),
        None
    );
}
