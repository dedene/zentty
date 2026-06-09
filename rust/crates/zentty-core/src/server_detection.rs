use std::collections::HashSet;

use regex::Regex;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ServerUrlCandidate {
    pub url: String,
    pub origin: String,
    pub display: String,
    pub port: u16,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ServerUrlNormalizeError {
    EmptyInput,
    InvalidUrl(String),
    MissingHost,
    MissingPort,
    InvalidPort(String),
    UnsupportedScheme(String),
    UnsupportedHost(String),
}

pub struct ServerUrlNormalizer;

impl ServerUrlNormalizer {
    pub fn normalize(raw_value: &str) -> Result<ServerUrlCandidate, ServerUrlNormalizeError> {
        let trimmed = raw_value.trim();
        if trimmed.is_empty() {
            return Err(ServerUrlNormalizeError::EmptyInput);
        }

        let normalized = normalized_url_string(trimmed)?;
        let (scheme, rest) = split_scheme(&normalized);
        let scheme = scheme.to_ascii_lowercase();
        if !matches!(scheme.as_str(), "http" | "https") {
            return Err(ServerUrlNormalizeError::UnsupportedScheme(scheme));
        }

        let (authority, suffix) = split_authority(rest)?;
        let (raw_host, raw_port) = split_host_port(authority);
        if raw_host.is_empty() {
            return Err(ServerUrlNormalizeError::MissingHost);
        }

        let host = normalized_host(raw_host);
        if !is_supported_host(&host) {
            return Err(ServerUrlNormalizeError::UnsupportedHost(
                raw_host.to_string(),
            ));
        }

        let raw_port = raw_port.ok_or(ServerUrlNormalizeError::MissingPort)?;
        let port = parse_port(raw_port)?;
        let origin_host = origin_host(&host);
        let suffix = normalized_suffix(suffix);
        let origin = format!("{scheme}://{origin_host}:{port}");

        Ok(ServerUrlCandidate {
            url: format!("{origin}{suffix}"),
            origin,
            display: format!("{}:{port}", display_host(&host)),
            port,
        })
    }
}

pub struct ServerOutputUrlDetector;

impl ServerOutputUrlDetector {
    pub fn detect(text: &str) -> Vec<ServerUrlCandidate> {
        let regex = Regex::new(r#"https?://[^\s<>"']+"#).expect("server URL regex should compile");
        let mut seen_origins = HashSet::new();
        let mut candidates = regex
            .find_iter(text)
            .filter_map(|url_match| {
                let raw_url = trim_trailing_punctuation(url_match.as_str());
                ServerUrlNormalizer::normalize(&raw_url).ok()
            })
            .filter(|candidate| seen_origins.insert(candidate.origin.clone()))
            .collect::<Vec<_>>();

        candidates.sort_by(|lhs, rhs| {
            lhs.port
                .cmp(&rhs.port)
                .then(host_preference_rank(lhs).cmp(&host_preference_rank(rhs)))
                .then(lhs.origin.cmp(&rhs.origin))
        });
        candidates
    }
}

fn normalized_url_string(raw_value: &str) -> Result<String, ServerUrlNormalizeError> {
    if raw_value.chars().all(|ch| ch.is_ascii_digit()) {
        let port = parse_port(raw_value)?;
        return Ok(format!("http://localhost:{port}/"));
    }

    if raw_value.contains("://") {
        Ok(raw_value.to_string())
    } else {
        Ok(format!("http://{raw_value}"))
    }
}

fn split_scheme(value: &str) -> (String, &str) {
    match value.split_once("://") {
        Some((scheme, rest)) => (scheme.to_string(), rest),
        None => ("http".to_string(), value),
    }
}

fn split_authority(value: &str) -> Result<(&str, &str), ServerUrlNormalizeError> {
    if value.is_empty() {
        return Err(ServerUrlNormalizeError::MissingHost);
    }
    let index = value.find(['/', '?', '#']).unwrap_or(value.len());
    Ok((&value[..index], &value[index..]))
}

fn split_host_port(authority: &str) -> (&str, Option<&str>) {
    let authority = authority
        .rsplit_once('@')
        .map(|(_, host_port)| host_port)
        .unwrap_or(authority);

    if let Some(remainder) = authority.strip_prefix('[') {
        let Some(end_index) = remainder.find(']') else {
            return (authority, None);
        };
        let host = &remainder[..end_index];
        let after_host = &remainder[end_index + 1..];
        return (host, after_host.strip_prefix(':'));
    }

    match authority.rsplit_once(':') {
        Some((host, port)) => (host, Some(port)),
        None => (authority, None),
    }
}

fn normalized_host(host: &str) -> String {
    let lowercased = host.trim_matches(['[', ']']).to_ascii_lowercase();
    match lowercased.as_str() {
        "0.0.0.0" | "::" | "::1" | "127.0.0.1" | "" => "localhost".to_string(),
        _ => lowercased,
    }
}

fn is_supported_host(host: &str) -> bool {
    host == "localhost"
        || host.ends_with(".local")
        || is_supported_ipv4(host)
        || is_supported_ipv6(host)
}

fn is_supported_ipv4(host: &str) -> bool {
    let octets = host
        .split('.')
        .map(|part| part.parse::<u8>())
        .collect::<Result<Vec<_>, _>>();
    let Ok(octets) = octets else {
        return false;
    };
    if octets.len() != 4 {
        return false;
    }

    matches!(octets[0], 10 | 127)
        || (octets[0] == 172 && (16..=31).contains(&octets[1]))
        || (octets[0] == 192 && octets[1] == 168)
        || (octets[0] == 169 && octets[1] == 254)
}

fn is_supported_ipv6(host: &str) -> bool {
    let lowercased = host.to_ascii_lowercase();
    lowercased.starts_with("fc") || lowercased.starts_with("fd") || lowercased.starts_with("fe80:")
}

fn parse_port(raw_port: &str) -> Result<u16, ServerUrlNormalizeError> {
    let port = raw_port
        .parse::<u16>()
        .map_err(|_| ServerUrlNormalizeError::InvalidPort(raw_port.to_string()))?;
    if port == 0 {
        return Err(ServerUrlNormalizeError::InvalidPort(raw_port.to_string()));
    }
    Ok(port)
}

fn normalized_suffix(suffix: &str) -> String {
    if suffix.is_empty() {
        "/".to_string()
    } else if suffix.starts_with(['?', '#']) {
        format!("/{suffix}")
    } else {
        suffix.to_string()
    }
}

fn origin_host(host: &str) -> String {
    if host.contains(':') {
        format!("[{host}]")
    } else {
        host.to_string()
    }
}

fn display_host(host: &str) -> String {
    origin_host(host)
}

fn trim_trailing_punctuation(raw_url: &str) -> String {
    raw_url
        .trim_end_matches(['.', ',', ';', ':', ')', ']', '}'])
        .to_string()
}

fn host_preference_rank(candidate: &ServerUrlCandidate) -> u8 {
    let host = display_host_from_candidate(candidate);
    if matches!(host.as_str(), "localhost" | "127.0.0.1" | "::1") {
        0
    } else if host.starts_with("127.") {
        1
    } else {
        2
    }
}

fn display_host_from_candidate(candidate: &ServerUrlCandidate) -> String {
    if let Some(remainder) = candidate.display.strip_prefix('[') {
        return remainder
            .split_once(']')
            .map(|(host, _)| host.to_string())
            .unwrap_or_else(|| candidate.display.clone());
    }
    candidate
        .display
        .rsplit_once(':')
        .map(|(host, _)| host.to_string())
        .unwrap_or_else(|| candidate.display.clone())
}
