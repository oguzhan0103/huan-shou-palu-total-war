use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

pub const SCHEMA_VERSION: &str = "1.0.0";
pub const MAX_DIALOGUE_CHARS: usize = 4_000;
pub const MAX_PLAYER_TEXT_CHARS: usize = 8_000;
pub const MAX_CONTEXT_KEYS: usize = 64;
pub const MAX_ALLOWED_CHOICES: usize = 32;
pub const MAX_ALLOWED_RESULT_TAGS: usize = 64;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ContentOrigin {
    LocalizationKeysOnly,
    UserAuthored,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CharacterPack {
    pub schema_version: String,
    pub pack_id: String,
    pub version: String,
    pub content_license: String,
    pub characters: Vec<CharacterDefinition>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CharacterDefinition {
    pub character_id: String,
    pub display_name_key: String,
    pub persona_key: String,
    pub content_origin: ContentOrigin,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub persona_text: Option<String>,
    #[serde(default)]
    pub knowledge_keys: Vec<String>,
    #[serde(default)]
    pub allowed_result_tags: Vec<String>,
    #[serde(default)]
    pub default_choices: Vec<ChoiceDefinition>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ChoiceDefinition {
    pub choice_id: String,
    pub text_key: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BridgeRequest {
    pub schema_version: String,
    pub request_id: String,
    pub created_at: DateTime<Utc>,
    pub character_id: String,
    pub session_id: String,
    pub world_key: String,
    pub player_key: String,
    pub locale: String,
    pub player_text: String,
    #[serde(default)]
    pub context_keys: Vec<String>,
    #[serde(default)]
    pub allowed_choices: Vec<ChoiceDefinition>,
    #[serde(default)]
    pub allowed_result_tags: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ModelReply {
    pub dialogue: String,
    #[serde(deserialize_with = "deserialize_required_option")]
    pub proposed_choice: Option<String>,
    pub result_tags: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BridgeResponse {
    pub schema_version: String,
    pub request_id: String,
    pub created_at: DateTime<Utc>,
    pub character_id: String,
    pub provider: String,
    pub dialogue: String,
    #[serde(deserialize_with = "deserialize_required_option")]
    pub proposed_choice: Option<String>,
    pub result_tags: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FailedRequestReport {
    pub schema_version: String,
    pub request_file: String,
    pub failed_at: DateTime<Utc>,
    pub error_code: String,
    pub retryable: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MemoryDocument {
    pub schema_version: String,
    pub profile_hash: String,
    pub turns: Vec<MemoryTurn>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MemoryTurn {
    pub request_id: String,
    pub session_id: String,
    pub created_at: DateTime<Utc>,
    pub player_text: String,
    pub dialogue: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub proposed_choice: Option<String>,
    pub result_tags: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct ProviderPrompt {
    pub system: String,
    pub user: String,
}

pub fn is_safe_id(value: &str) -> bool {
    let length = value.chars().count();
    (1..=128).contains(&length)
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "._-".contains(character))
}

pub fn is_safe_key(value: &str) -> bool {
    let length = value.chars().count();
    (1..=256).contains(&length)
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "._:/-".contains(character))
}

pub fn stable_unique(values: impl IntoIterator<Item = String>) -> Vec<String> {
    let mut unique = BTreeMap::new();
    for value in values {
        unique.entry(value.clone()).or_insert(value);
    }
    unique.into_values().collect()
}

fn deserialize_required_option<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Option::<String>::deserialize(deserializer)
}
