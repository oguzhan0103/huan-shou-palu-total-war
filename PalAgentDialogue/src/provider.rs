use std::{collections::VecDeque, fmt, sync::Mutex, time::Duration};

use async_trait::async_trait;
use reqwest::{Client, StatusCode, Url};
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::domain::{ModelReply, ProviderPrompt, MAX_DIALOGUE_CHARS};

const MAX_PROVIDER_RESPONSE_BYTES: usize = 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProviderKind {
    Ollama,
    OpenAiCompatible,
}

#[derive(Clone)]
pub struct Secret(String);

impl Secret {
    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("Secret(<redacted>)")
    }
}

#[derive(Clone)]
pub struct ProviderConfig {
    pub kind: ProviderKind,
    pub base_url: Url,
    pub model: String,
    pub timeout: Duration,
    pub api_key: Option<Secret>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderSummary {
    pub provider: String,
    pub base_url: String,
    pub model: String,
    pub timeout_seconds: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderCheckReport {
    pub provider: String,
    pub model: String,
    pub dialogue_chars: usize,
    pub strict_json: bool,
    pub authority_fields: bool,
}

impl fmt::Debug for ProviderConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ProviderConfig")
            .field("kind", &self.kind)
            .field("base_url", &self.base_url)
            .field("model", &self.model)
            .field("timeout", &self.timeout)
            .field("api_key", &self.api_key.as_ref().map(|_| "<redacted>"))
            .finish()
    }
}

impl ProviderConfig {
    pub fn from_env() -> Result<Self, ProviderError> {
        let provider = std::env::var("PAL_AGENT_PROVIDER").unwrap_or_else(|_| "ollama".into());
        let kind = match provider.trim().to_ascii_lowercase().as_str() {
            "ollama" => ProviderKind::Ollama,
            "openai-compatible" | "openai_compatible" => ProviderKind::OpenAiCompatible,
            _ => return Err(ProviderError::InvalidConfig("unknown provider".into())),
        };
        let base_url = match kind {
            ProviderKind::Ollama => std::env::var("PAL_AGENT_OLLAMA_BASE_URL")
                .unwrap_or_else(|_| "http://127.0.0.1:11434".into()),
            ProviderKind::OpenAiCompatible => std::env::var("PAL_AGENT_OPENAI_BASE_URL")
                .unwrap_or_else(|_| "http://127.0.0.1:1234/v1".into()),
        };
        let base_url = validate_base_url(&base_url)?;
        if kind == ProviderKind::Ollama
            && !base_url
                .host_str()
                .is_some_and(|host| matches!(host, "127.0.0.1" | "localhost" | "::1"))
            && std::env::var("PAL_AGENT_ALLOW_REMOTE_OLLAMA").as_deref() != Ok("1")
        {
            return Err(ProviderError::InvalidConfig(
                "remote Ollama is disabled unless PAL_AGENT_ALLOW_REMOTE_OLLAMA=1".into(),
            ));
        }
        let model = std::env::var("PAL_AGENT_MODEL").unwrap_or_else(|_| "qwen3:8b".into());
        if model.trim().is_empty() || model.chars().count() > 256 {
            return Err(ProviderError::InvalidConfig("invalid model name".into()));
        }
        let timeout_seconds = std::env::var("PAL_AGENT_TIMEOUT_SECONDS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(90)
            .clamp(10, 600);
        let api_key = std::env::var("PAL_AGENT_OPENAI_API_KEY")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .map(Secret);

        Ok(Self {
            kind,
            base_url,
            model,
            timeout: Duration::from_secs(timeout_seconds),
            api_key,
        })
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ProviderError {
    #[error("invalid provider configuration: {0}")]
    InvalidConfig(String),
    #[error("provider request failed")]
    Request(#[source] reqwest::Error),
    #[error("provider returned HTTP {0}")]
    Http(StatusCode),
    #[error("provider response exceeds 1 MiB")]
    ResponseTooLarge,
    #[error("provider response is malformed")]
    MalformedResponse,
    #[error("provider response contains no dialogue payload")]
    MissingContent,
    #[error("provider diagnostic reply violates the strict JSON boundary: {0}")]
    DiagnosticReplyInvalid(String),
    #[error("mock provider has no queued reply")]
    MockExhausted,
}

#[async_trait]
pub trait DialogueProvider: Send + Sync {
    fn label(&self) -> &str;
    async fn complete(&self, prompt: &ProviderPrompt) -> Result<String, ProviderError>;
}

pub struct HttpProvider {
    config: ProviderConfig,
    client: Client,
}

impl HttpProvider {
    pub fn new(config: ProviderConfig) -> Result<Self, ProviderError> {
        let client = Client::builder()
            .timeout(config.timeout)
            .build()
            .map_err(ProviderError::Request)?;
        Ok(Self { config, client })
    }

    pub fn summary(&self) -> ProviderSummary {
        ProviderSummary {
            provider: self.label().into(),
            base_url: self.config.base_url.as_str().into(),
            model: self.config.model.clone(),
            timeout_seconds: self.config.timeout.as_secs(),
        }
    }

    /// Performs one explicit provider request without reading or claiming any
    /// bridge file. This is a configuration diagnostic, not a foreground-gate
    /// bypass for production dialogue processing.
    pub async fn provider_check(&self) -> Result<ProviderCheckReport, ProviderError> {
        let raw = self
            .complete(&ProviderPrompt {
                system: concat!(
                    "This is a connectivity diagnostic. Return exactly one JSON object with ",
                    "dialogue, proposedChoice, and resultTags. dialogue must be a short ",
                    "non-empty acknowledgement. proposedChoice must be null and resultTags ",
                    "must be an empty array. Do not return markdown or any other field."
                )
                .into(),
                user: "Reply with the strict diagnostic JSON now.".into(),
            })
            .await?;
        let reply: ModelReply = serde_json::from_str(raw.trim()).map_err(|_| {
            ProviderError::DiagnosticReplyInvalid("response is not the whitelisted object".into())
        })?;
        let dialogue_chars = reply.dialogue.trim().chars().count();
        if dialogue_chars == 0 || dialogue_chars > MAX_DIALOGUE_CHARS {
            return Err(ProviderError::DiagnosticReplyInvalid(
                "dialogue is empty or too long".into(),
            ));
        }
        if reply.proposed_choice.is_some() || !reply.result_tags.is_empty() {
            return Err(ProviderError::DiagnosticReplyInvalid(
                "diagnostic reply proposed authority-bearing values".into(),
            ));
        }
        Ok(ProviderCheckReport {
            provider: self.label().into(),
            model: self.config.model.clone(),
            dialogue_chars,
            strict_json: true,
            authority_fields: false,
        })
    }

    async fn checked_bytes(&self, response: reqwest::Response) -> Result<Vec<u8>, ProviderError> {
        if !response.status().is_success() {
            return Err(ProviderError::Http(response.status()));
        }
        if response
            .content_length()
            .is_some_and(|length| length > MAX_PROVIDER_RESPONSE_BYTES as u64)
        {
            return Err(ProviderError::ResponseTooLarge);
        }
        let bytes = response.bytes().await.map_err(ProviderError::Request)?;
        if bytes.len() > MAX_PROVIDER_RESPONSE_BYTES {
            return Err(ProviderError::ResponseTooLarge);
        }
        Ok(bytes.to_vec())
    }
}

#[derive(Deserialize)]
struct OllamaResponse {
    message: OllamaMessage,
}

#[derive(Deserialize)]
struct OllamaMessage {
    content: String,
}

#[derive(Deserialize)]
struct OpenAiResponse {
    choices: Vec<OpenAiChoice>,
}

#[derive(Deserialize)]
struct OpenAiChoice {
    message: OpenAiMessage,
}

#[derive(Deserialize)]
struct OpenAiMessage {
    content: Option<String>,
}

#[async_trait]
impl DialogueProvider for HttpProvider {
    fn label(&self) -> &str {
        match self.config.kind {
            ProviderKind::Ollama => "ollama",
            ProviderKind::OpenAiCompatible => "openai-compatible",
        }
    }

    async fn complete(&self, prompt: &ProviderPrompt) -> Result<String, ProviderError> {
        let messages = json!([
            {"role": "system", "content": prompt.system},
            {"role": "user", "content": prompt.user}
        ]);
        match self.config.kind {
            ProviderKind::Ollama => {
                let endpoint = join_endpoint(&self.config.base_url, "api/chat")?;
                let response = self
                    .client
                    .post(endpoint)
                    .json(&json!({
                        "model": self.config.model,
                        "messages": messages,
                        "stream": false,
                        "format": reply_schema(),
                        "options": {"temperature": 0.55}
                    }))
                    .send()
                    .await
                    .map_err(ProviderError::Request)?;
                let bytes = self.checked_bytes(response).await?;
                let payload: OllamaResponse =
                    serde_json::from_slice(&bytes).map_err(|_| ProviderError::MalformedResponse)?;
                non_empty(payload.message.content)
            }
            ProviderKind::OpenAiCompatible => {
                let endpoint = join_endpoint(&self.config.base_url, "chat/completions")?;
                let mut request = self.client.post(endpoint).json(&json!({
                    "model": self.config.model,
                    "messages": messages,
                    "response_format": {"type": "json_object"},
                    "temperature": 0.55
                }));
                if let Some(secret) = &self.config.api_key {
                    request = request.bearer_auth(secret.expose());
                }
                let response = request.send().await.map_err(ProviderError::Request)?;
                let bytes = self.checked_bytes(response).await?;
                let payload: OpenAiResponse =
                    serde_json::from_slice(&bytes).map_err(|_| ProviderError::MalformedResponse)?;
                payload
                    .choices
                    .into_iter()
                    .next()
                    .and_then(|choice| choice.message.content)
                    .map(non_empty)
                    .unwrap_or(Err(ProviderError::MissingContent))
            }
        }
    }
}

pub struct MockProvider {
    replies: Mutex<VecDeque<String>>,
    calls: Mutex<usize>,
}

impl MockProvider {
    pub fn new(replies: impl IntoIterator<Item = String>) -> Self {
        Self {
            replies: Mutex::new(replies.into_iter().collect()),
            calls: Mutex::new(0),
        }
    }

    pub fn call_count(&self) -> usize {
        *self.calls.lock().expect("mock provider call lock")
    }
}

#[async_trait]
impl DialogueProvider for MockProvider {
    fn label(&self) -> &str {
        "mock"
    }

    async fn complete(&self, _prompt: &ProviderPrompt) -> Result<String, ProviderError> {
        *self.calls.lock().expect("mock provider call lock") += 1;
        self.replies
            .lock()
            .expect("mock provider reply lock")
            .pop_front()
            .ok_or(ProviderError::MockExhausted)
    }
}

fn validate_base_url(value: &str) -> Result<Url, ProviderError> {
    let url = Url::parse(value.trim())
        .map_err(|_| ProviderError::InvalidConfig("base URL is invalid".into()))?;
    if !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(ProviderError::InvalidConfig(
            "base URL must be HTTP(S) and cannot contain credentials, query parameters, or fragments"
                .into(),
        ));
    }
    let loopback = url
        .host_str()
        .is_some_and(|host| matches!(host, "127.0.0.1" | "localhost" | "::1"));
    if url.scheme() == "http" && !loopback {
        return Err(ProviderError::InvalidConfig(
            "non-loopback provider URLs must use HTTPS".into(),
        ));
    }
    Ok(url)
}

fn join_endpoint(base: &Url, operation: &str) -> Result<Url, ProviderError> {
    let mut normalized = base.as_str().trim_end_matches('/').to_string();
    if operation == "api/chat" && normalized.ends_with("/api") {
        normalized.truncate(normalized.len() - 4);
    }
    Url::parse(&format!("{normalized}/{operation}"))
        .map_err(|_| ProviderError::InvalidConfig("cannot build provider endpoint".into()))
}

fn non_empty(content: String) -> Result<String, ProviderError> {
    if content.trim().is_empty() {
        Err(ProviderError::MissingContent)
    } else {
        Ok(content)
    }
}

fn reply_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "properties": {
            "dialogue": {"type": "string", "minLength": 1, "maxLength": 4000},
            "proposedChoice": {"type": ["string", "null"]},
            "resultTags": {"type": "array", "items": {"type": "string"}, "maxItems": 64}
        },
        "required": ["dialogue", "proposedChoice", "resultTags"],
        "additionalProperties": false
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secret_debug_output_is_redacted() {
        let secret = Secret("do-not-print-this".into());
        assert_eq!(format!("{secret:?}"), "Secret(<redacted>)");
    }

    #[test]
    fn rejects_credentials_in_base_url() {
        assert!(validate_base_url("https://user:secret@example.invalid/v1").is_err());
    }

    #[test]
    fn rejects_query_parameters_that_might_disclose_secrets() {
        assert!(validate_base_url("https://example.invalid/v1?api_key=secret").is_err());
    }

    #[test]
    fn requires_https_for_non_loopback_providers() {
        assert!(validate_base_url("http://models.example.invalid/v1").is_err());
        assert!(validate_base_url("https://models.example.invalid/v1").is_ok());
        assert!(validate_base_url("http://127.0.0.1:1234/v1").is_ok());
    }

    #[test]
    fn joins_ollama_endpoint_without_duplicate_api() {
        let base = Url::parse("http://127.0.0.1:11434/api/").expect("url");
        assert_eq!(
            join_endpoint(&base, "api/chat").expect("endpoint").as_str(),
            "http://127.0.0.1:11434/api/chat"
        );
    }
}
