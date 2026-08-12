pub mod bridge;
pub mod domain;
pub mod foreground;
pub mod memory;
pub mod pack;
pub mod provider;
pub mod runtime;

pub use bridge::BridgePaths;
pub use domain::{BridgeRequest, BridgeResponse, CharacterPack, ModelReply};
pub use foreground::{
    process_is_running, ForegroundGate, SystemForegroundGate, TARGET_GAME_EXECUTABLE,
};
pub use memory::MemoryStore;
pub use pack::load_character_pack;
pub use provider::{
    DialogueProvider, HttpProvider, MockProvider, ProviderCheckReport, ProviderConfig,
    ProviderSummary,
};
pub use runtime::{AgentRuntime, ProcessOutcome};
