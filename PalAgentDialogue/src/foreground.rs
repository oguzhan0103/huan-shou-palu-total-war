use std::path::Path;

pub const TARGET_GAME_EXECUTABLE: &str = "Palworld-Win64-Shipping.exe";

#[derive(Debug, thiserror::Error)]
pub enum ForegroundError {
    #[error("foreground-process observation is only supported on Windows")]
    UnsupportedPlatform,
    #[error("cannot query the foreground process")]
    QueryFailed,
}

pub trait ForegroundGate: Send + Sync {
    fn game_is_foreground(&self) -> Result<bool, ForegroundError>;
}

#[derive(Debug, Default, Clone, Copy)]
pub struct SystemForegroundGate;

impl ForegroundGate for SystemForegroundGate {
    fn game_is_foreground(&self) -> Result<bool, ForegroundError> {
        Ok(foreground_executable()?
            .as_deref()
            .is_some_and(matches_game_executable))
    }
}

pub fn matches_game_executable(executable: &str) -> bool {
    Path::new(executable)
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.eq_ignore_ascii_case(TARGET_GAME_EXECUTABLE))
}

#[cfg(target_os = "windows")]
fn foreground_executable() -> Result<Option<String>, ForegroundError> {
    use std::{ffi::OsString, os::windows::ffi::OsStringExt};

    use windows_sys::Win32::{
        Foundation::CloseHandle,
        System::Threading::{
            OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION,
        },
        UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId},
    };

    unsafe {
        let window = GetForegroundWindow();
        if window.is_null() {
            return Ok(None);
        }
        let mut process_id = 0u32;
        GetWindowThreadProcessId(window, &mut process_id);
        if process_id == 0 {
            return Err(ForegroundError::QueryFailed);
        }
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, process_id);
        if process.is_null() {
            return Err(ForegroundError::QueryFailed);
        }
        let mut buffer = vec![0u16; 32_768];
        let mut length = buffer.len() as u32;
        let queried = QueryFullProcessImageNameW(process, 0, buffer.as_mut_ptr(), &mut length);
        CloseHandle(process);
        if queried == 0 || length == 0 {
            return Err(ForegroundError::QueryFailed);
        }
        let path = OsString::from_wide(&buffer[..length as usize]);
        Ok(Some(path.to_string_lossy().into_owned()))
    }
}

#[cfg(target_os = "windows")]
pub fn process_is_running(process_id: u32) -> Result<bool, ForegroundError> {
    use windows_sys::Win32::{
        Foundation::{CloseHandle, WAIT_OBJECT_0, WAIT_TIMEOUT},
        System::Threading::{OpenProcess, WaitForSingleObject, PROCESS_SYNCHRONIZE},
    };

    unsafe {
        let process = OpenProcess(PROCESS_SYNCHRONIZE, 0, process_id);
        if process.is_null() {
            return Ok(false);
        }
        let wait = WaitForSingleObject(process, 0);
        CloseHandle(process);
        match wait {
            WAIT_TIMEOUT => Ok(true),
            WAIT_OBJECT_0 => Ok(false),
            _ => Err(ForegroundError::QueryFailed),
        }
    }
}

#[cfg(not(target_os = "windows"))]
pub fn process_is_running(_process_id: u32) -> Result<bool, ForegroundError> {
    Err(ForegroundError::UnsupportedPlatform)
}

#[cfg(not(target_os = "windows"))]
fn foreground_executable() -> Result<Option<String>, ForegroundError> {
    Err(ForegroundError::UnsupportedPlatform)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "windows")]
    #[test]
    fn observes_the_current_process_as_running() {
        assert!(process_is_running(std::process::id()).expect("observe current process"));
    }

    #[test]
    fn matches_only_the_exact_palworld_shipping_executable() {
        assert!(matches_game_executable(TARGET_GAME_EXECUTABLE));
        assert!(matches_game_executable(
            r"C:\Games\Palworld\Pal\Binaries\Win64\PALWORLD-WIN64-SHIPPING.EXE"
        ));
        assert!(!matches_game_executable("Palworld.exe"));
        assert!(!matches_game_executable(
            "Palworld-Win64-Shipping-helper.exe"
        ));
        assert!(!matches_game_executable("steam.exe"));
    }
}
