use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

use time::OffsetDateTime;

use crate::command_palette::{DetectedServer, DetectedServerConfidence, DetectedServerSource};
use crate::server_detection::ServerUrlNormalizer;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ServerPortRule {
    pub lower_bound: u16,
    pub upper_bound: u16,
}

impl ServerPortRule {
    pub fn new(lower_bound: u16, upper_bound: u16) -> Option<Self> {
        (lower_bound > 0 && lower_bound <= upper_bound).then_some(Self {
            lower_bound,
            upper_bound,
        })
    }

    pub fn parse(raw_value: &str) -> Option<Self> {
        let trimmed = raw_value.trim();
        if trimmed.is_empty() {
            return None;
        }

        if let Ok(port) = trimmed.parse::<u16>() {
            return Self::new(port, port);
        }

        let parts = trimmed.split('-').collect::<Vec<_>>();
        if parts.len() != 2 {
            return None;
        }
        let lower = parts[0].trim().parse::<u16>().ok()?;
        let upper = parts[1].trim().parse::<u16>().ok()?;
        Self::new(lower, upper)
    }

    pub fn contains(&self, port: u16) -> bool {
        (self.lower_bound..=self.upper_bound).contains(&port)
    }

    pub fn canonical_string(&self) -> String {
        if self.lower_bound == self.upper_bound {
            self.lower_bound.to_string()
        } else {
            format!("{}-{}", self.lower_bound, self.upper_bound)
        }
    }

    pub fn normalize(raw_values: &[String]) -> Vec<Self> {
        Self::merge(raw_values.iter().filter_map(|value| Self::parse(value)))
    }

    pub fn canonical_strings(raw_values: &[String]) -> Vec<String> {
        Self::normalize(raw_values)
            .iter()
            .map(Self::canonical_string)
            .collect()
    }

    pub fn adding_port(port: u16, raw_values: &[String]) -> Vec<String> {
        let mut values = raw_values.to_vec();
        values.push(port.to_string());
        Self::canonical_strings(&values)
    }

    pub fn removing_port(port: u16, raw_values: &[String]) -> Vec<String> {
        let split = Self::normalize(raw_values)
            .into_iter()
            .flat_map(|rule| {
                if !rule.contains(port) {
                    return vec![rule];
                }
                [
                    Self::new(rule.lower_bound, port.saturating_sub(1)),
                    port.checked_add(1)
                        .and_then(|lower| Self::new(lower, rule.upper_bound)),
                ]
                .into_iter()
                .flatten()
                .collect()
            })
            .collect::<Vec<_>>();
        Self::merge(split)
            .iter()
            .map(Self::canonical_string)
            .collect()
    }

    fn merge(rules: impl IntoIterator<Item = Self>) -> Vec<Self> {
        let mut rules = rules.into_iter().collect::<Vec<_>>();
        rules.sort();

        let mut merged: Vec<Self> = Vec::new();
        for rule in rules {
            let Some(last) = merged.last_mut() else {
                merged.push(rule);
                continue;
            };
            let adjacent_or_overlapping =
                u32::from(rule.lower_bound) <= u32::from(last.upper_bound) + 1;
            if adjacent_or_overlapping {
                last.upper_bound = last.upper_bound.max(rule.upper_bound);
            } else {
                merged.push(rule);
            }
        }
        merged
    }
}

impl Ord for ServerPortRule {
    fn cmp(&self, other: &Self) -> Ordering {
        self.lower_bound
            .cmp(&other.lower_bound)
            .then_with(|| self.upper_bound.cmp(&other.upper_bound))
    }
}

impl PartialOrd for ServerPortRule {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[derive(Clone, Debug, Default)]
pub struct ServerRegistry {
    records_by_key: HashMap<ServerRecordKey, DetectedServer>,
}

impl ServerRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn from_records(records: impl IntoIterator<Item = DetectedServer>) -> Self {
        let mut registry = Self::new();
        for server in records {
            registry.upsert(server);
        }
        registry
    }

    pub fn into_records(self) -> Vec<DetectedServer> {
        let mut records = self.records_by_key.into_values().collect::<Vec<_>>();
        records.sort_by(server_record_order);
        records
    }

    pub fn upsert(&mut self, server: DetectedServer) {
        let key = ServerRecordKey::from(&server);
        let server = preserving_first_seen(server, self.records_by_key.get(&key));
        self.records_by_key.insert(key, server);
    }

    pub fn replace_source(
        &mut self,
        source: DetectedServerSource,
        worklane_id: &str,
        servers: impl IntoIterator<Item = DetectedServer>,
    ) {
        let previous = self.records_by_key.clone();
        self.records_by_key
            .retain(|key, _| key.worklane_id != worklane_id || key.source != source);

        for server in servers {
            let key = ServerRecordKey::from(&server);
            let server = preserving_first_seen(server, previous.get(&key));
            self.records_by_key.insert(key, server);
        }
    }

    pub fn clear_worklane_pane(&mut self, worklane_id: &str, pane_id: &str) {
        self.records_by_key.retain(|key, _| {
            key.worklane_id != worklane_id || key.pane_id.as_deref() != Some(pane_id)
        });
    }

    pub fn clear_worklane(&mut self, worklane_id: &str) {
        self.records_by_key
            .retain(|key, _| key.worklane_id != worklane_id);
    }

    pub fn clear_source(
        &mut self,
        source: DetectedServerSource,
        worklane_id: &str,
        pane_id: Option<&str>,
    ) {
        self.records_by_key.retain(|key, _| {
            if key.worklane_id != worklane_id || key.source != source {
                return true;
            }
            pane_id.is_some_and(|pane_id| key.pane_id.as_deref() != Some(pane_id))
        });
    }

    pub fn servers_in(&self, worklane_id: &str) -> Vec<DetectedServer> {
        let mut by_origin: HashMap<&str, Vec<&DetectedServer>> = HashMap::new();
        for server in self
            .records_by_key
            .values()
            .filter(|server| server.worklane_id == worklane_id)
        {
            by_origin
                .entry(server.origin.as_str())
                .or_default()
                .push(server);
        }

        let mut merged = by_origin
            .into_values()
            .filter_map(merged_server)
            .collect::<Vec<_>>();
        merged.sort_by(|lhs, rhs| {
            rhs.updated_at
                .cmp(&lhs.updated_at)
                .then_with(|| lhs.origin.cmp(&rhs.origin))
        });
        merged
    }

    pub fn server_matching(
        &self,
        raw_origin_or_url: &str,
        worklane_id: &str,
    ) -> Option<DetectedServer> {
        let origin = ServerUrlNormalizer::normalize(raw_origin_or_url)
            .map(|candidate| candidate.origin)
            .unwrap_or_else(|_| raw_origin_or_url.to_string());
        self.servers_in(worklane_id)
            .into_iter()
            .find(|server| server.origin == origin)
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct ServerRecordKey {
    worklane_id: String,
    origin: String,
    source: DetectedServerSource,
    pane_id: Option<String>,
}

impl From<&DetectedServer> for ServerRecordKey {
    fn from(server: &DetectedServer) -> Self {
        Self {
            worklane_id: server.worklane_id.clone(),
            origin: server.origin.clone(),
            source: server.source,
            pane_id: server.pane_id.clone(),
        }
    }
}

fn preserving_first_seen(
    mut server: DetectedServer,
    previous: Option<&DetectedServer>,
) -> DetectedServer {
    if let Some(previous) = previous {
        server.first_seen_at = previous.first_seen_at.min(server.first_seen_at);
    }
    server
}

fn merged_server(records: Vec<&DetectedServer>) -> Option<DetectedServer> {
    let winner = records
        .iter()
        .max_by(|lhs, rhs| server_record_order(lhs, rhs))?;
    let mut merged = (*winner).clone();
    merged.id = format!("{}|{}", merged.worklane_id, merged.origin);
    merged.ports = merged_ports(&records);
    if let Some(first_seen_at) = records.iter().map(|server| server.first_seen_at).min() {
        merged.first_seen_at = first_seen_at;
    }
    Some(merged)
}

fn merged_ports(records: &[&DetectedServer]) -> Vec<u16> {
    let mut ports = records
        .iter()
        .flat_map(|server| server.ports.iter().copied().chain(server_port(server)))
        .collect::<Vec<_>>();
    ports.sort_unstable();
    ports.dedup();
    ports
}

fn server_port(server: &DetectedServer) -> Option<u16> {
    ServerUrlNormalizer::normalize(&server.origin)
        .map(|candidate| candidate.port)
        .ok()
}

fn server_record_order(lhs: &DetectedServer, rhs: &DetectedServer) -> Ordering {
    source_priority(lhs.source)
        .cmp(&source_priority(rhs.source))
        .then_with(|| lhs.updated_at.cmp(&rhs.updated_at))
        .then_with(|| rhs.origin.cmp(&lhs.origin))
}

fn source_priority(source: DetectedServerSource) -> u8 {
    match source {
        DetectedServerSource::Manual => 4,
        DetectedServerSource::Watch => 3,
        DetectedServerSource::Docker => 2,
        DetectedServerSource::Scanner => 1,
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum ServerRelevanceTier {
    Primary,
    Shown,
    Hidden,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub enum ServerRelevanceReason {
    SessionSelected,
    IgnoredPort(u16),
    Manual,
    RunningPane,
    FocusedPane,
    Source(DetectedServerSource),
    Confidence(DetectedServerConfidence),
    Fresh,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RankedServer {
    pub server: DetectedServer,
    pub tier: ServerRelevanceTier,
    pub score: i32,
    pub reasons: HashSet<ServerRelevanceReason>,
}

#[derive(Clone, Debug)]
pub struct ServerRelevanceContext {
    pub focused_pane_id: Option<String>,
    pub running_pane_ids: HashSet<String>,
    pub ignored_port_rules: Vec<ServerPortRule>,
    pub session_selected_origin: Option<String>,
    pub now: OffsetDateTime,
}

impl Default for ServerRelevanceContext {
    fn default() -> Self {
        Self {
            focused_pane_id: None,
            running_pane_ids: HashSet::new(),
            ignored_port_rules: Vec::new(),
            session_selected_origin: None,
            now: OffsetDateTime::UNIX_EPOCH,
        }
    }
}

pub struct ServerRelevance;

impl ServerRelevance {
    pub const FRESH_WINDOW_SECONDS: i64 = 60;

    pub fn rank(servers: &[DetectedServer], context: &ServerRelevanceContext) -> Vec<RankedServer> {
        let mut visible = Vec::new();
        let mut hidden = Vec::new();

        for server in servers {
            let port = server_port(server).or_else(|| server.ports.first().copied());
            if server.source != DetectedServerSource::Manual
                && port.is_some_and(|port| {
                    context
                        .ignored_port_rules
                        .iter()
                        .any(|rule| rule.contains(port))
                })
            {
                hidden.push(RankedServer {
                    server: server.clone(),
                    tier: ServerRelevanceTier::Hidden,
                    score: 0,
                    reasons: port
                        .map(ServerRelevanceReason::IgnoredPort)
                        .into_iter()
                        .collect(),
                });
                continue;
            }

            visible.push(scored_server(server, context));
        }

        visible.sort_by(|lhs, rhs| {
            rhs.score
                .cmp(&lhs.score)
                .then_with(|| lhs.server.origin.cmp(&rhs.server.origin))
        });
        visible
            .into_iter()
            .enumerate()
            .map(|(index, mut server)| {
                server.tier = if index == 0 {
                    ServerRelevanceTier::Primary
                } else {
                    ServerRelevanceTier::Shown
                };
                server
            })
            .chain(hidden)
            .collect()
    }
}

fn scored_server(server: &DetectedServer, context: &ServerRelevanceContext) -> RankedServer {
    let mut score = 0;
    let mut reasons = HashSet::new();

    if context
        .session_selected_origin
        .as_deref()
        .is_some_and(|origin| origin == server.origin)
    {
        score += 1000;
        reasons.insert(ServerRelevanceReason::SessionSelected);
    }
    if server
        .pane_id
        .as_deref()
        .is_some_and(|pane_id| context.focused_pane_id.as_deref() == Some(pane_id))
    {
        score += 200;
        reasons.insert(ServerRelevanceReason::FocusedPane);
    }
    if server
        .pane_id
        .as_ref()
        .is_some_and(|pane_id| context.running_pane_ids.contains(pane_id))
    {
        score += 150;
        reasons.insert(ServerRelevanceReason::RunningPane);
    }

    score += relevance_source_score(server.source);
    reasons.insert(ServerRelevanceReason::Source(server.source));
    if server.source == DetectedServerSource::Manual {
        reasons.insert(ServerRelevanceReason::Manual);
    }

    score += confidence_score(server.confidence);
    reasons.insert(ServerRelevanceReason::Confidence(server.confidence));

    if (context.now - server.first_seen_at).whole_seconds() <= ServerRelevance::FRESH_WINDOW_SECONDS
    {
        score += 5;
        reasons.insert(ServerRelevanceReason::Fresh);
    }

    RankedServer {
        server: server.clone(),
        tier: ServerRelevanceTier::Shown,
        score,
        reasons,
    }
}

fn relevance_source_score(source: DetectedServerSource) -> i32 {
    match source {
        DetectedServerSource::Manual => 80,
        DetectedServerSource::Watch => 60,
        DetectedServerSource::Docker => 40,
        DetectedServerSource::Scanner => 0,
    }
}

fn confidence_score(confidence: DetectedServerConfidence) -> i32 {
    match confidence {
        DetectedServerConfidence::Explicit => 30,
        DetectedServerConfidence::Pid => 20,
        DetectedServerConfidence::Cwd => 10,
        DetectedServerConfidence::Worklane => 0,
    }
}
