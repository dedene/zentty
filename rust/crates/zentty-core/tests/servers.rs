use std::collections::HashSet;

use time::{Duration, OffsetDateTime};
use zentty_core::command_palette::{
    DetectedServer, DetectedServerConfidence, DetectedServerSource,
};
use zentty_core::server_detection::ServerUrlNormalizer;
use zentty_core::servers::{
    RankedServer, ServerPortRule, ServerRegistry, ServerRelevance, ServerRelevanceContext,
    ServerRelevanceReason, ServerRelevanceTier,
};

#[test]
fn server_port_rules_match_swift_parse_normalize_and_editing_rules() {
    assert_eq!(
        ServerPortRule::parse("9229"),
        ServerPortRule::new(9229, 9229)
    );
    assert_eq!(
        ServerPortRule::parse(" 3000 - 3002 "),
        ServerPortRule::new(3000, 3002)
    );
    assert_eq!(ServerPortRule::parse("0"), None);
    assert_eq!(ServerPortRule::parse("70000"), None);
    assert_eq!(ServerPortRule::parse("5000-4000"), None);
    assert_eq!(
        ServerPortRule::canonical_strings(&strings(["3000-3005", "3004-3008", "9229"])),
        strings(["3000-3008", "9229"])
    );
    assert_eq!(
        ServerPortRule::adding_port(3001, &strings(["3000", "3002"])),
        strings(["3000-3002"])
    );
    assert_eq!(
        ServerPortRule::removing_port(3001, &strings(["3000-3002"])),
        strings(["3000", "3002"])
    );
}

#[test]
fn server_registry_merges_sources_and_preserves_first_seen_like_swift() {
    let mut registry = ServerRegistry::new();

    registry.upsert(server(
        "http://localhost:5173/",
        "worklane-main",
        DetectedServerSource::Scanner,
        Some("pane-a"),
        40,
        40,
        DetectedServerConfidence::Pid,
    ));
    registry.upsert(server(
        "http://localhost:5173/app",
        "worklane-main",
        DetectedServerSource::Manual,
        Some("pane-a"),
        20,
        20,
        DetectedServerConfidence::Explicit,
    ));

    let merged = registry.servers_in("worklane-main");
    assert_eq!(merged.len(), 1);
    assert_eq!(merged[0].source, DetectedServerSource::Manual);
    assert_eq!(merged[0].url, "http://localhost:5173/app");
    assert_eq!(merged[0].ports, vec![5173]);
    assert_eq!(merged[0].first_seen_at, date(20));

    registry.replace_source(
        DetectedServerSource::Scanner,
        "worklane-main",
        [server(
            "http://localhost:3000/",
            "worklane-main",
            DetectedServerSource::Scanner,
            Some("pane-b"),
            50,
            50,
            DetectedServerConfidence::Pid,
        )],
    );

    let origins = registry
        .servers_in("worklane-main")
        .into_iter()
        .map(|server| server.origin)
        .collect::<Vec<_>>();
    assert_eq!(
        origins,
        vec![
            "http://localhost:3000".to_string(),
            "http://localhost:5173".to_string()
        ]
    );
    assert_eq!(
        registry
            .server_matching("localhost:5173/docs?q=1", "worklane-main")
            .map(|server| server.origin),
        Some("http://localhost:5173".to_string())
    );
}

#[test]
fn server_registry_clear_source_preserves_manual_pin_for_same_origin() {
    let mut registry = ServerRegistry::new();
    registry.upsert(server(
        "http://localhost:5173/",
        "worklane-main",
        DetectedServerSource::Scanner,
        Some("pane-a"),
        10,
        10,
        DetectedServerConfidence::Pid,
    ));
    registry.upsert(server(
        "http://localhost:5173/pinned",
        "worklane-main",
        DetectedServerSource::Manual,
        Some("pane-a"),
        20,
        20,
        DetectedServerConfidence::Explicit,
    ));

    registry.clear_source(DetectedServerSource::Scanner, "worklane-main", None);

    let servers = registry.servers_in("worklane-main");
    assert_eq!(servers.len(), 1);
    assert_eq!(servers[0].source, DetectedServerSource::Manual);
    assert_eq!(servers[0].url, "http://localhost:5173/pinned");
}

#[test]
fn server_registry_replace_source_preserves_first_seen_for_surviving_records() {
    let mut registry = ServerRegistry::new();
    registry.replace_source(
        DetectedServerSource::Scanner,
        "worklane-main",
        [server(
            "http://localhost:5173/",
            "worklane-main",
            DetectedServerSource::Scanner,
            Some("pane-a"),
            10,
            10,
            DetectedServerConfidence::Pid,
        )],
    );
    registry.replace_source(
        DetectedServerSource::Scanner,
        "worklane-main",
        [server(
            "http://localhost:5173/",
            "worklane-main",
            DetectedServerSource::Scanner,
            Some("pane-a"),
            50,
            50,
            DetectedServerConfidence::Pid,
        )],
    );

    let merged = registry.servers_in("worklane-main");
    assert_eq!(merged[0].first_seen_at, date(10));
    assert_eq!(merged[0].updated_at, date(50));
}

#[test]
fn server_relevance_matches_swift_primary_hidden_and_freshness_rules() {
    let ranked = ServerRelevance::rank(
        &[
            server(
                "http://localhost:9229/",
                "worklane-main",
                DetectedServerSource::Scanner,
                Some("pane-a"),
                0,
                0,
                DetectedServerConfidence::Pid,
            ),
            server(
                "http://localhost:5173/",
                "worklane-main",
                DetectedServerSource::Scanner,
                Some("pane-a"),
                9_970,
                9_970,
                DetectedServerConfidence::Pid,
            ),
            server(
                "http://localhost:3000/",
                "worklane-main",
                DetectedServerSource::Watch,
                Some("pane-b"),
                9_880,
                9_880,
                DetectedServerConfidence::Pid,
            ),
        ],
        &ServerRelevanceContext {
            focused_pane_id: Some("pane-a".to_string()),
            running_pane_ids: HashSet::from(["pane-a".to_string()]),
            ignored_port_rules: vec![ServerPortRule::new(9229, 9229).unwrap()],
            session_selected_origin: None,
            now: date(10_000),
        },
    );

    assert_eq!(primary(&ranked).server.origin, "http://localhost:5173");
    assert!(
        primary(&ranked)
            .reasons
            .contains(&ServerRelevanceReason::FocusedPane)
    );
    assert!(
        primary(&ranked)
            .reasons
            .contains(&ServerRelevanceReason::RunningPane)
    );
    assert!(
        primary(&ranked)
            .reasons
            .contains(&ServerRelevanceReason::Fresh)
    );
    assert_eq!(
        ranked
            .iter()
            .find(|entry| entry.server.origin == "http://localhost:9229")
            .map(|entry| entry.tier),
        Some(ServerRelevanceTier::Hidden)
    );
}

#[test]
fn server_relevance_session_selected_server_wins_even_when_idle() {
    let ranked = ServerRelevance::rank(
        &[
            server(
                "http://localhost:3000/",
                "worklane-main",
                DetectedServerSource::Manual,
                Some("pane-a"),
                0,
                0,
                DetectedServerConfidence::Explicit,
            ),
            server(
                "http://localhost:5173/",
                "worklane-main",
                DetectedServerSource::Scanner,
                None,
                0,
                0,
                DetectedServerConfidence::Pid,
            ),
        ],
        &ServerRelevanceContext {
            focused_pane_id: Some("pane-a".to_string()),
            running_pane_ids: HashSet::from(["pane-a".to_string()]),
            ignored_port_rules: Vec::new(),
            session_selected_origin: Some("http://localhost:5173".to_string()),
            now: date(10_000),
        },
    );

    assert_eq!(primary(&ranked).server.origin, "http://localhost:5173");
    assert!(
        primary(&ranked)
            .reasons
            .contains(&ServerRelevanceReason::SessionSelected)
    );
}

fn server(
    raw_url: &str,
    worklane_id: &str,
    source: DetectedServerSource,
    pane_id: Option<&str>,
    updated_at_seconds: i64,
    first_seen_at_seconds: i64,
    confidence: DetectedServerConfidence,
) -> DetectedServer {
    let candidate = ServerUrlNormalizer::normalize(raw_url).expect("server URL should normalize");
    DetectedServer::new(
        format!(
            "{}-{}-{}-{}",
            worklane_id,
            source.raw_value(),
            candidate.origin,
            pane_id.unwrap_or("worklane")
        ),
        candidate.origin,
        candidate.url,
        candidate.display,
    )
    .with_metadata(
        worklane_id,
        pane_id.map(str::to_string),
        source,
        confidence,
        date(updated_at_seconds),
    )
    .with_first_seen_at(date(first_seen_at_seconds))
}

fn primary(ranked: &[RankedServer]) -> &RankedServer {
    ranked
        .iter()
        .find(|entry| entry.tier == ServerRelevanceTier::Primary)
        .expect("ranked servers should include primary")
}

fn date(seconds: i64) -> OffsetDateTime {
    OffsetDateTime::UNIX_EPOCH + Duration::seconds(seconds)
}

fn strings<const N: usize>(values: [&str; N]) -> Vec<String> {
    values.iter().map(|value| value.to_string()).collect()
}
