use std::{fs, path::PathBuf};

use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::domain::{MemoryDocument, MemoryTurn, SCHEMA_VERSION};

const MAX_ACTIVE_TURNS: usize = 2_000;
const ARCHIVE_BATCH_SIZE: usize = 1_000;
const MAX_PROMPT_TURNS: usize = 20;

#[derive(Debug, thiserror::Error)]
pub enum MemoryError {
    #[error("cannot create local memory directory")]
    CreateDirectory(#[source] std::io::Error),
    #[error("cannot read local memory")]
    Read(#[source] std::io::Error),
    #[error("local memory JSON is invalid")]
    Decode(#[source] serde_json::Error),
    #[error("local memory profile does not match its filename")]
    ProfileMismatch,
    #[error("cannot encode local memory")]
    Encode(#[source] serde_json::Error),
    #[error("cannot write local memory")]
    Write(#[source] std::io::Error),
}

#[derive(Debug, Clone)]
pub struct MemoryStore {
    root: PathBuf,
}

impl MemoryStore {
    pub fn new(root: PathBuf) -> Result<Self, MemoryError> {
        fs::create_dir_all(root.join("profiles")).map_err(MemoryError::CreateDirectory)?;
        fs::create_dir_all(root.join("archives")).map_err(MemoryError::CreateDirectory)?;
        Ok(Self { root })
    }

    pub fn profile_hash(
        pack_id: &str,
        character_id: &str,
        world_key: &str,
        player_key: &str,
    ) -> String {
        let mut hasher = Sha256::new();
        for part in [pack_id, character_id, world_key, player_key] {
            hasher.update((part.len() as u64).to_be_bytes());
            hasher.update(part.as_bytes());
        }
        format!("{:x}", hasher.finalize())
    }

    pub fn recent_turns(&self, profile_hash: &str) -> Result<Vec<MemoryTurn>, MemoryError> {
        let document = self.load(profile_hash)?;
        let start = document.turns.len().saturating_sub(MAX_PROMPT_TURNS);
        Ok(document.turns[start..].to_vec())
    }

    pub fn append(&self, profile_hash: &str, turn: MemoryTurn) -> Result<(), MemoryError> {
        let mut document = self.load(profile_hash)?;
        if document
            .turns
            .iter()
            .any(|item| item.request_id == turn.request_id)
        {
            return Ok(());
        }
        document.turns.push(turn);
        if document.turns.len() > MAX_ACTIVE_TURNS {
            let archived = document
                .turns
                .drain(..ARCHIVE_BATCH_SIZE)
                .collect::<Vec<_>>();
            let archive = MemoryDocument {
                schema_version: SCHEMA_VERSION.into(),
                profile_hash: profile_hash.into(),
                turns: archived,
            };
            let archive_path = self.root.join("archives").join(format!(
                "{}-{}.json",
                profile_hash,
                Uuid::new_v4()
            ));
            write_json_atomic(&archive_path, &archive)?;
        }
        write_json_atomic(&self.profile_path(profile_hash), &document)
    }

    fn load(&self, profile_hash: &str) -> Result<MemoryDocument, MemoryError> {
        let path = self.profile_path(profile_hash);
        if !path.exists() {
            return Ok(MemoryDocument {
                schema_version: SCHEMA_VERSION.into(),
                profile_hash: profile_hash.into(),
                turns: vec![],
            });
        }
        let bytes = fs::read(path).map_err(MemoryError::Read)?;
        let document: MemoryDocument =
            serde_json::from_slice(&bytes).map_err(MemoryError::Decode)?;
        if document.schema_version != SCHEMA_VERSION || document.profile_hash != profile_hash {
            return Err(MemoryError::ProfileMismatch);
        }
        Ok(document)
    }

    fn profile_path(&self, profile_hash: &str) -> PathBuf {
        self.root
            .join("profiles")
            .join(format!("{profile_hash}.json"))
    }
}

pub(crate) fn write_json_atomic<T: serde::Serialize>(
    path: &std::path::Path,
    value: &T,
) -> Result<(), MemoryError> {
    let parent = path.parent().ok_or_else(|| {
        MemoryError::Write(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "path has no parent",
        ))
    })?;
    fs::create_dir_all(parent).map_err(MemoryError::CreateDirectory)?;
    let bytes = serde_json::to_vec_pretty(value).map_err(MemoryError::Encode)?;
    let temporary = parent.join(format!(".pal-agent-{}.tmp", Uuid::new_v4()));
    fs::write(&temporary, bytes).map_err(MemoryError::Write)?;
    if path.exists() {
        let backup = parent.join(format!(".pal-agent-{}.bak", Uuid::new_v4()));
        fs::rename(path, &backup).map_err(MemoryError::Write)?;
        if let Err(error) = fs::rename(&temporary, path) {
            let _ = fs::rename(&backup, path);
            let _ = fs::remove_file(&temporary);
            return Err(MemoryError::Write(error));
        }
        let _ = fs::remove_file(backup);
    } else {
        fs::rename(&temporary, path).map_err(MemoryError::Write)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use chrono::Utc;

    use super::*;

    #[test]
    fn profile_names_are_hashes_not_player_identifiers() {
        let hash = MemoryStore::profile_hash("pack", "npc", "world-secret", "player-secret");
        assert_eq!(hash.len(), 64);
        assert!(!hash.contains("secret"));
    }

    #[test]
    fn persists_and_deduplicates_turns() {
        let root = tempfile::tempdir().expect("tempdir");
        let store = MemoryStore::new(root.path().to_path_buf()).expect("store");
        let turn = MemoryTurn {
            request_id: "request-1".into(),
            session_id: "session-1".into(),
            created_at: Utc::now(),
            player_text: "hello".into(),
            dialogue: "welcome".into(),
            proposed_choice: None,
            result_tags: vec![],
        };
        store.append("profile", turn.clone()).expect("append");
        store.append("profile", turn).expect("duplicate append");
        assert_eq!(store.recent_turns("profile").expect("turns").len(), 1);
    }
}
