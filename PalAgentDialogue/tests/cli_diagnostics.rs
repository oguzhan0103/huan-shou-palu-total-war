use std::{
    fs,
    io::{Read, Write},
    net::TcpListener,
    path::PathBuf,
    process::Command,
    thread,
    time::Duration,
};

fn binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_pal-agent-dialogue"))
}

fn pack() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("character-packs")
        .join("example-minimal.json")
}

fn spawn_ollama_stub(model_content: &str) -> (String, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind Ollama stub");
    let address = listener.local_addr().expect("stub address");
    let model_content = model_content.to_string();
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept diagnostic request");
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .expect("read timeout");
        let mut request = Vec::new();
        let mut buffer = [0u8; 4096];
        loop {
            let read = stream.read(&mut buffer).expect("read request");
            if read == 0 {
                break;
            }
            request.extend_from_slice(&buffer[..read]);
            let header_end = request
                .windows(4)
                .position(|window| window == b"\r\n\r\n")
                .map(|index| index + 4);
            if let Some(header_end) = header_end {
                let headers = String::from_utf8_lossy(&request[..header_end]);
                let content_length = headers
                    .lines()
                    .find_map(|line| {
                        line.strip_prefix("content-length: ")
                            .or_else(|| line.strip_prefix("Content-Length: "))
                    })
                    .and_then(|value| value.trim().parse::<usize>().ok())
                    .unwrap_or(0);
                if request.len() >= header_end + content_length {
                    break;
                }
            }
        }
        let request_text = String::from_utf8_lossy(&request);
        assert!(request_text.starts_with("POST /api/chat HTTP/1.1"));
        assert!(request_text.contains("\"stream\":false"));
        assert!(request_text.contains("\"format\""));

        let escaped = serde_json::to_string(&model_content).expect("escape model content");
        let body = format!(r#"{{"message":{{"content":{escaped}}}}}"#);
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        )
        .expect("write response");
    });
    (format!("http://{address}"), handle)
}

#[test]
fn doctor_validates_configuration_and_queue_without_provider_request() {
    let temp = tempfile::tempdir().expect("tempdir");
    let output = Command::new(binary())
        .arg("doctor")
        .arg(pack())
        .arg(temp.path().join("bridge"))
        .env("PAL_AGENT_PROVIDER", "ollama")
        .env("PAL_AGENT_MODEL", "diagnostic-model")
        .env("PAL_AGENT_OLLAMA_BASE_URL", "http://127.0.0.1:11434")
        .output()
        .expect("run doctor");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("DOCTOR_OK"));
    assert!(stdout.contains("queueDirectories=6"));
    assert!(stdout.contains("foregroundGateEnforced=true"));
    for directory in [
        "inbox",
        "processing",
        "outbox",
        "failed",
        "archive",
        "memory",
    ] {
        assert!(temp.path().join("bridge").join(directory).is_dir());
    }
}

#[test]
fn provider_check_calls_ollama_and_accepts_only_strict_authority_free_json() {
    let valid = r#"{"dialogue":"provider ready","proposedChoice":null,"resultTags":[]}"#;
    let (base_url, server) = spawn_ollama_stub(valid);
    let output = Command::new(binary())
        .arg("provider-check")
        .env("PAL_AGENT_PROVIDER", "ollama")
        .env("PAL_AGENT_MODEL", "diagnostic-model")
        .env("PAL_AGENT_OLLAMA_BASE_URL", base_url)
        .env("PAL_AGENT_TIMEOUT_SECONDS", "10")
        .output()
        .expect("run provider check");
    server.join().expect("join Ollama stub");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("PROVIDER_CHECK_OK provider=ollama"));
    assert!(stdout.contains("strictJson=true authorityFields=false"));
}

#[test]
fn provider_check_rejects_authority_fields() {
    let invalid = r#"{"dialogue":"bad","proposedChoice":null,"resultTags":[],"affinityDelta":99}"#;
    let (base_url, server) = spawn_ollama_stub(invalid);
    let output = Command::new(binary())
        .arg("provider-check")
        .env("PAL_AGENT_PROVIDER", "ollama")
        .env("PAL_AGENT_MODEL", "diagnostic-model")
        .env("PAL_AGENT_OLLAMA_BASE_URL", base_url)
        .env("PAL_AGENT_TIMEOUT_SECONDS", "10")
        .output()
        .expect("run rejected provider check");
    server.join().expect("join Ollama stub");
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("strict JSON boundary"));
}

#[test]
fn doctor_does_not_create_queue_outside_the_requested_bridge_root() {
    let temp = tempfile::tempdir().expect("tempdir");
    let bridge = temp.path().join("requested").join("bridge");
    let output = Command::new(binary())
        .arg("doctor")
        .arg(pack())
        .arg(&bridge)
        .env("PAL_AGENT_PROVIDER", "ollama")
        .env("PAL_AGENT_OLLAMA_BASE_URL", "http://127.0.0.1:11434")
        .output()
        .expect("run doctor");
    assert!(output.status.success());
    assert!(bridge.join("inbox").is_dir());
    assert_eq!(fs::read_dir(temp.path()).expect("temp root").count(), 1);
}
