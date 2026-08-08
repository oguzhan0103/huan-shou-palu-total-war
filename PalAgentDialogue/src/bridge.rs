use std::{ffi::OsString, fs, path::PathBuf};

use chrono::Utc;
use uuid::Uuid;

use crate::{
    domain::{BridgeRequest, BridgeResponse, FailedRequestReport, SCHEMA_VERSION},
    memory::write_json_atomic,
};

const MAX_REQUEST_BYTES: u64 = 256 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum BridgeError {
    #[error("cannot create bridge directory")]
    CreateDirectory(#[source] std::io::Error),
    #[error("cannot enumerate bridge inbox")]
    Enumerate(#[source] std::io::Error),
    #[error("cannot inspect bridge request")]
    Metadata(#[source] std::io::Error),
    #[error("bridge request exceeds 256 KiB")]
    RequestTooLarge,
    #[error("cannot claim bridge request")]
    Claim(#[source] std::io::Error),
    #[error("cannot read bridge request")]
    Read(#[source] std::io::Error),
    #[error("bridge request JSON is invalid")]
    Decode(#[source] serde_json::Error),
    #[error("cannot write bridge response")]
    Write(#[source] crate::memory::MemoryError),
    #[error("cannot archive bridge request")]
    Archive(#[source] std::io::Error),
}

#[derive(Debug, Clone)]
pub struct BridgePaths {
    pub root: PathBuf,
    pub inbox: PathBuf,
    pub processing: PathBuf,
    pub outbox: PathBuf,
    pub failed: PathBuf,
    pub archive: PathBuf,
    pub memory: PathBuf,
}

#[derive(Debug, Clone)]
pub struct ClaimedRequest {
    pub original_file_name: OsString,
    pub path: PathBuf,
}

impl BridgePaths {
    pub fn new(root: PathBuf) -> Result<Self, BridgeError> {
        let paths = Self {
            inbox: root.join("inbox"),
            processing: root.join("processing"),
            outbox: root.join("outbox"),
            failed: root.join("failed"),
            archive: root.join("archive"),
            memory: root.join("memory"),
            root,
        };
        for path in [
            &paths.inbox,
            &paths.processing,
            &paths.outbox,
            &paths.failed,
            &paths.archive,
            &paths.memory,
        ] {
            fs::create_dir_all(path).map_err(BridgeError::CreateDirectory)?;
        }
        Ok(paths)
    }

    pub fn claim_next(&self) -> Result<Option<ClaimedRequest>, BridgeError> {
        let mut entries = fs::read_dir(&self.inbox)
            .map_err(BridgeError::Enumerate)?
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .path()
                    .extension()
                    .is_some_and(|extension| extension.eq_ignore_ascii_case("json"))
            })
            .collect::<Vec<_>>();
        entries.sort_by_key(|entry| entry.file_name());
        let Some(entry) = entries.into_iter().next() else {
            return Ok(None);
        };
        let metadata = entry.metadata().map_err(BridgeError::Metadata)?;
        if !metadata.is_file() {
            return Ok(None);
        }
        let original_file_name = entry.file_name();
        let claimed_name = format!(
            "{}-{}.processing.json",
            original_file_name
                .to_string_lossy()
                .trim_end_matches(".json"),
            Uuid::new_v4()
        );
        let claimed_path = self.processing.join(claimed_name);
        fs::rename(entry.path(), &claimed_path).map_err(BridgeError::Claim)?;
        Ok(Some(ClaimedRequest {
            original_file_name,
            path: claimed_path,
        }))
    }

    pub fn read_request(&self, claimed: &ClaimedRequest) -> Result<BridgeRequest, BridgeError> {
        let metadata = fs::metadata(&claimed.path).map_err(BridgeError::Metadata)?;
        if metadata.len() > MAX_REQUEST_BYTES {
            return Err(BridgeError::RequestTooLarge);
        }
        let bytes = fs::read(&claimed.path).map_err(BridgeError::Read)?;
        serde_json::from_slice(&bytes).map_err(BridgeError::Decode)
    }

    pub fn response_exists(&self, request_id: &str) -> bool {
        self.outbox.join(format!("{request_id}.json")).is_file()
    }

    pub fn write_response(&self, response: &BridgeResponse) -> Result<(), BridgeError> {
        let path = self.outbox.join(format!("{}.json", response.request_id));
        write_json_atomic(&path, response).map_err(BridgeError::Write)
    }

    pub fn archive_request(&self, claimed: &ClaimedRequest) -> Result<(), BridgeError> {
        let file_stem = claimed
            .original_file_name
            .to_string_lossy()
            .trim_end_matches(".json")
            .to_string();
        let destination = self
            .archive
            .join(format!("{}-{}.json", file_stem, Uuid::new_v4()));
        fs::rename(&claimed.path, destination).map_err(BridgeError::Archive)
    }

    pub fn fail_request(
        &self,
        claimed: &ClaimedRequest,
        error_code: &str,
        retryable: bool,
    ) -> Result<(), BridgeError> {
        let id = Uuid::new_v4();
        let stem = claimed
            .original_file_name
            .to_string_lossy()
            .trim_end_matches(".json")
            .to_string();
        let request_destination = self.failed.join(format!("{stem}-{id}.request.json"));
        fs::rename(&claimed.path, request_destination).map_err(BridgeError::Archive)?;
        let report = FailedRequestReport {
            schema_version: SCHEMA_VERSION.into(),
            request_file: claimed.original_file_name.to_string_lossy().into_owned(),
            failed_at: Utc::now(),
            error_code: error_code.into(),
            retryable,
        };
        write_json_atomic(
            &self.failed.join(format!("{stem}-{id}.error.json")),
            &report,
        )
        .map_err(BridgeError::Write)
    }
}
