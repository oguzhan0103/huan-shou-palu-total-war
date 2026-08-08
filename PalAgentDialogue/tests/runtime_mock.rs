use std::{fs, path::Path};

use chrono::Utc;
use pal_agent_dialogue::{
    domain::{CharacterDefinition, ChoiceDefinition, ContentOrigin, SCHEMA_VERSION},
    foreground::{ForegroundError, ForegroundGate},
    AgentRuntime, BridgePaths, BridgeRequest, BridgeResponse, CharacterPack, MockProvider,
    ProcessOutcome,
};

#[derive(Clone, Copy)]
struct FixedForeground(bool);

impl ForegroundGate for FixedForeground {
    fn game_is_foreground(&self) -> Result<bool, ForegroundError> {
        Ok(self.0)
    }
}

fn pack() -> CharacterPack {
    CharacterPack {
        schema_version: SCHEMA_VERSION.into(),
        pack_id: "test.pack".into(),
        version: "1.0.0".into(),
        content_license: "MIT".into(),
        characters: vec![CharacterDefinition {
            character_id: "test_npc".into(),
            display_name_key: "test.npc.name".into(),
            persona_key: "test.npc.persona".into(),
            content_origin: ContentOrigin::LocalizationKeysOnly,
            persona_text: None,
            knowledge_keys: vec!["test.context.met_before".into()],
            allowed_result_tags: vec!["heard_player".into()],
            default_choices: vec![ChoiceDefinition {
                choice_id: "continue".into(),
                text_key: "test.choice.continue".into(),
            }],
        }],
    }
}

fn request(request_id: &str) -> BridgeRequest {
    BridgeRequest {
        schema_version: SCHEMA_VERSION.into(),
        request_id: request_id.into(),
        created_at: Utc::now(),
        character_id: "test_npc".into(),
        session_id: "session-1".into(),
        world_key: "world-local".into(),
        player_key: "player-local".into(),
        locale: "zh-CN".into(),
        player_text: "我们再谈谈。".into(),
        context_keys: vec!["test.context.met_before".into()],
        allowed_choices: vec![ChoiceDefinition {
            choice_id: "continue".into(),
            text_key: "test.choice.continue".into(),
        }],
        allowed_result_tags: vec!["heard_player".into()],
    }
}

fn write_request(bridge: &BridgePaths, request: &BridgeRequest) {
    fs::write(
        bridge.inbox.join(format!("{}.json", request.request_id)),
        serde_json::to_vec_pretty(request).expect("request JSON"),
    )
    .expect("write request");
}

fn count_json(path: &Path) -> usize {
    fs::read_dir(path)
        .expect("read directory")
        .filter_map(Result::ok)
        .filter(|entry| {
            entry
                .path()
                .extension()
                .is_some_and(|value| value == "json")
        })
        .count()
}

#[tokio::test]
async fn mock_provider_writes_strict_outbox_and_long_term_memory() {
    let temp = tempfile::tempdir().expect("tempdir");
    let bridge = BridgePaths::new(temp.path().join("bridge")).expect("bridge");
    let provider = MockProvider::new([r#"{"dialogue":"我记得我们的约定。","proposedChoice":"continue","resultTags":["heard_player"]}"#.to_string()]);
    let runtime = AgentRuntime::new(pack(), provider, FixedForeground(true), bridge.clone())
        .expect("runtime");
    write_request(&bridge, &request("request-1"));

    assert_eq!(
        runtime.process_next().await.expect("process"),
        ProcessOutcome::Completed {
            request_id: "request-1".into()
        }
    );
    let response: BridgeResponse =
        serde_json::from_slice(&fs::read(bridge.outbox.join("request-1.json")).expect("response"))
            .expect("response JSON");
    assert_eq!(response.dialogue, "我记得我们的约定。");
    assert_eq!(response.proposed_choice.as_deref(), Some("continue"));
    assert_eq!(response.result_tags, ["heard_player"]);
    assert_eq!(count_json(&bridge.memory.join("profiles")), 1);
    assert_eq!(count_json(&bridge.archive), 1);
}

#[tokio::test]
async fn foreground_gate_leaves_requests_untouched() {
    let temp = tempfile::tempdir().expect("tempdir");
    let bridge = BridgePaths::new(temp.path().join("bridge")).expect("bridge");
    let runtime = AgentRuntime::new(
        pack(),
        MockProvider::new(Vec::<String>::new()),
        FixedForeground(false),
        bridge.clone(),
    )
    .expect("runtime");
    write_request(&bridge, &request("request-foreground"));

    assert_eq!(
        runtime.process_next().await.expect("process"),
        ProcessOutcome::GameNotForeground
    );
    assert!(bridge.inbox.join("request-foreground.json").is_file());
    assert_eq!(count_json(&bridge.outbox), 0);
}

#[tokio::test]
async fn authority_field_is_rejected_and_never_reaches_outbox() {
    let temp = tempfile::tempdir().expect("tempdir");
    let bridge = BridgePaths::new(temp.path().join("bridge")).expect("bridge");
    let provider = MockProvider::new([
        r#"{"dialogue":"错误回复","proposedChoice":null,"resultTags":[],"affinityDelta":999}"#
            .to_string(),
    ]);
    let runtime = AgentRuntime::new(pack(), provider, FixedForeground(true), bridge.clone())
        .expect("runtime");
    write_request(&bridge, &request("request-rejected"));

    assert_eq!(
        runtime.process_next().await.expect("process"),
        ProcessOutcome::Failed {
            error_code: "model-output-rejected".into(),
            retryable: true
        }
    );
    assert_eq!(count_json(&bridge.outbox), 0);
    assert_eq!(count_json(&bridge.failed), 2);
    assert_eq!(count_json(&bridge.memory.join("profiles")), 0);
}

#[tokio::test]
async fn existing_response_makes_delivery_idempotent_without_provider_call() {
    let temp = tempfile::tempdir().expect("tempdir");
    let bridge = BridgePaths::new(temp.path().join("bridge")).expect("bridge");
    fs::write(bridge.outbox.join("request-duplicate.json"), b"{}").expect("existing response");
    let runtime = AgentRuntime::new(
        pack(),
        MockProvider::new(Vec::<String>::new()),
        FixedForeground(true),
        bridge.clone(),
    )
    .expect("runtime");
    write_request(&bridge, &request("request-duplicate"));

    assert_eq!(
        runtime.process_next().await.expect("process"),
        ProcessOutcome::Duplicate {
            request_id: "request-duplicate".into()
        }
    );
    assert_eq!(count_json(&bridge.archive), 1);
    assert_eq!(count_json(&bridge.failed), 0);
}

#[tokio::test]
async fn oversized_request_is_quarantined_instead_of_blocking_the_inbox() {
    let temp = tempfile::tempdir().expect("tempdir");
    let bridge = BridgePaths::new(temp.path().join("bridge")).expect("bridge");
    fs::write(bridge.inbox.join("oversized.json"), vec![b'x'; 257 * 1024])
        .expect("oversized request");
    let runtime = AgentRuntime::new(
        pack(),
        MockProvider::new(Vec::<String>::new()),
        FixedForeground(true),
        bridge.clone(),
    )
    .expect("runtime");

    assert_eq!(
        runtime.process_next().await.expect("process"),
        ProcessOutcome::Failed {
            error_code: "request-contract-invalid".into(),
            retryable: false
        }
    );
    assert_eq!(count_json(&bridge.inbox), 0);
    assert_eq!(count_json(&bridge.failed), 2);
}
