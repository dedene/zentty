use zentty_core::server_detection::{
    ServerOutputUrlDetector, ServerUrlNormalizeError, ServerUrlNormalizer,
};

#[test]
fn server_url_normalizer_matches_swift_local_and_private_host_rules() {
    let result = ServerUrlNormalizer::normalize("3000").expect("port should normalize");
    assert_eq!(result.url, "http://localhost:3000/");
    assert_eq!(result.origin, "http://localhost:3000");
    assert_eq!(result.display, "localhost:3000");
    assert_eq!(result.port, 3000);

    let result = ServerUrlNormalizer::normalize("localhost:5173").expect("host should normalize");
    assert_eq!(result.url, "http://localhost:5173/");
    assert_eq!(result.origin, "http://localhost:5173");

    let result = ServerUrlNormalizer::normalize("http://127.0.0.1:8080/docs?q=1#top")
        .expect("loopback URL should normalize");
    assert_eq!(result.url, "http://localhost:8080/docs?q=1#top");
    assert_eq!(result.origin, "http://localhost:8080");
    assert_eq!(result.display, "localhost:8080");

    let result =
        ServerUrlNormalizer::normalize("http://0.0.0.0:5173/").expect("wildcard should normalize");
    assert_eq!(result.url, "http://localhost:5173/");
    assert_eq!(result.origin, "http://localhost:5173");

    let result = ServerUrlNormalizer::normalize("http://[::]:5173/")
        .expect("IPv6 wildcard should normalize");
    assert_eq!(result.url, "http://localhost:5173/");
    assert_eq!(result.origin, "http://localhost:5173");

    let result = ServerUrlNormalizer::normalize("http://[::1]:8080/")
        .expect("IPv6 loopback should normalize");
    assert_eq!(result.url, "http://localhost:8080/");
    assert_eq!(result.origin, "http://localhost:8080");
    assert_eq!(result.display, "localhost:8080");

    let result = ServerUrlNormalizer::normalize("http://192.168.1.20:4173/")
        .expect("private LAN URL should normalize");
    assert_eq!(result.url, "http://192.168.1.20:4173/");
    assert_eq!(result.origin, "http://192.168.1.20:4173");

    let result =
        ServerUrlNormalizer::normalize("my-app.local:8080").expect(".local host should normalize");
    assert_eq!(result.url, "http://my-app.local:8080/");
    assert_eq!(result.origin, "http://my-app.local:8080");
}

#[test]
fn server_url_normalizer_rejects_public_hosts_and_invalid_shapes_like_swift() {
    assert_eq!(
        ServerUrlNormalizer::normalize("https://example.com:443"),
        Err(ServerUrlNormalizeError::UnsupportedHost(
            "example.com".to_string()
        ))
    );
    assert_eq!(
        ServerUrlNormalizer::normalize("https://example.com"),
        Err(ServerUrlNormalizeError::UnsupportedHost(
            "example.com".to_string()
        ))
    );
    assert_eq!(
        ServerUrlNormalizer::normalize("http://localhost"),
        Err(ServerUrlNormalizeError::MissingPort)
    );
    assert_eq!(
        ServerUrlNormalizer::normalize("file://localhost:3000"),
        Err(ServerUrlNormalizeError::UnsupportedScheme(
            "file".to_string()
        ))
    );
}

#[test]
fn server_output_detector_matches_swift_dev_server_output_rules() {
    let detections = ServerOutputUrlDetector::detect("Local: http://localhost:5173/");
    assert_eq!(origins(&detections), vec!["http://localhost:5173"]);
    assert_eq!(detections[0].url, "http://localhost:5173/");

    let detections = ServerOutputUrlDetector::detect("Network: http://192.168.1.20:5173/");
    assert_eq!(origins(&detections), vec!["http://192.168.1.20:5173"]);

    let detections = ServerOutputUrlDetector::detect(
        "Docs: https://example.com:443 Local: http://localhost:3000/",
    );
    assert_eq!(origins(&detections), vec!["http://localhost:3000"]);

    let detections = ServerOutputUrlDetector::detect(
        "Local: http://localhost:5173/\nNetwork: http://192.168.1.20:5173/",
    );
    assert_eq!(
        origins(&detections),
        vec!["http://localhost:5173", "http://192.168.1.20:5173"]
    );

    let detections = ServerOutputUrlDetector::detect("Ready at http://127.0.0.1:8080/docs?q=1#top");
    assert_eq!(detections[0].origin, "http://localhost:8080");
    assert_eq!(detections[0].url, "http://localhost:8080/docs?q=1#top");

    let detections = ServerOutputUrlDetector::detect("Open (http://localhost:3000/).");
    assert_eq!(detections[0].url, "http://localhost:3000/");
}

fn origins(candidates: &[zentty_core::server_detection::ServerUrlCandidate]) -> Vec<&str> {
    candidates
        .iter()
        .map(|candidate| candidate.origin.as_str())
        .collect()
}
