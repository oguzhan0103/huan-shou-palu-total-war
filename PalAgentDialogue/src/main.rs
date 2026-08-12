use std::{path::PathBuf, process::ExitCode, time::Duration};

use pal_agent_dialogue::{
    load_character_pack, process_is_running, AgentRuntime, BridgePaths, ForegroundGate,
    HttpProvider, ProcessOutcome, ProviderConfig, SystemForegroundGate,
};

#[tokio::main]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("pal-agent-dialogue: {error}");
            ExitCode::FAILURE
        }
    }
}

async fn run() -> Result<(), String> {
    let arguments = std::env::args().skip(1).collect::<Vec<_>>();
    match arguments.as_slice() {
        [command, pack] if command == "validate-pack" => {
            let pack = load_character_pack(&PathBuf::from(pack)).map_err(|error| error.to_string())?;
            println!(
                "VALID packId={} version={} characters={}",
                pack.pack_id,
                pack.version,
                pack.characters.len()
            );
            Ok(())
        }
        [command, pack_path, bridge_root] if command == "doctor" => {
            let pack = load_character_pack(&PathBuf::from(pack_path))
                .map_err(|error| error.to_string())?;
            let bridge = BridgePaths::new(PathBuf::from(bridge_root))
                .map_err(|error| error.to_string())?;
            let provider_config =
                ProviderConfig::from_env().map_err(|error| error.to_string())?;
            let provider =
                HttpProvider::new(provider_config).map_err(|error| error.to_string())?;
            let (foreground, foreground_observer) =
                match SystemForegroundGate.game_is_foreground() {
                    Ok(value) => (value.to_string(), "ready".to_string()),
                    Err(error) => ("unknown".into(), format!("unavailable:{error}")),
                };
            let summary = provider.summary();
            println!(
                "DOCTOR_OK packId={} characters={} provider={} model={} baseUrl={} timeoutSeconds={} bridgeRoot={} queueDirectories=6 foregroundGateEnforced=true gameForeground={} foregroundObserver={}",
                pack.pack_id,
                pack.characters.len(),
                summary.provider,
                summary.model,
                summary.base_url,
                summary.timeout_seconds,
                bridge.root.display(),
                foreground,
                foreground_observer
            );
            Ok(())
        }
        [command] if command == "provider-check" => {
            let provider_config =
                ProviderConfig::from_env().map_err(|error| error.to_string())?;
            let provider =
                HttpProvider::new(provider_config).map_err(|error| error.to_string())?;
            let report = provider
                .provider_check()
                .await
                .map_err(|error| error.to_string())?;
            println!(
                "PROVIDER_CHECK_OK provider={} model={} dialogueChars={} strictJson={} authorityFields={}",
                report.provider,
                report.model,
                report.dialogue_chars,
                report.strict_json,
                report.authority_fields
            );
            Ok(())
        }
        [command, pack_path, bridge_root]
            if command == "run" || command == "process-once" =>
        {
            let pack = load_character_pack(&PathBuf::from(pack_path))
                .map_err(|error| error.to_string())?;
            let bridge = BridgePaths::new(PathBuf::from(bridge_root))
                .map_err(|error| error.to_string())?;
            let provider_config =
                ProviderConfig::from_env().map_err(|error| error.to_string())?;
            let provider =
                HttpProvider::new(provider_config).map_err(|error| error.to_string())?;
            let runtime = AgentRuntime::new(pack, provider, SystemForegroundGate, bridge)
                .map_err(|error| error.to_string())?;

            if command == "process-once" {
                println!("{:?}", runtime.process_next().await?);
                return Ok(());
            }

            println!(
                "PalAgentDialogue running; requests are consumed only while Palworld-Win64-Shipping.exe is foreground."
            );
            loop {
                match runtime.process_next().await {
                    Ok(ProcessOutcome::Completed { request_id }) => {
                        println!("completed requestId={request_id}")
                    }
                    Ok(ProcessOutcome::Failed {
                        error_code,
                        retryable,
                    }) => eprintln!("failed code={error_code} retryable={retryable}"),
                    Ok(ProcessOutcome::Duplicate { request_id }) => {
                        println!("duplicate requestId={request_id}")
                    }
                    Ok(ProcessOutcome::GameNotForeground | ProcessOutcome::Idle) => {}
                    Err(error) => eprintln!("runtime-error: {error}"),
                }
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
        }
        [command, pack_path, bridge_root, owner_pid]
            if command == "run-owned" =>
        {
            let owner_pid = owner_pid
                .parse::<u32>()
                .map_err(|_| "owner PID must be a positive integer".to_string())?;
            if owner_pid == 0 {
                return Err("owner PID must be a positive integer".into());
            }
            let pack = load_character_pack(&PathBuf::from(pack_path))
                .map_err(|error| error.to_string())?;
            let bridge = BridgePaths::new(PathBuf::from(bridge_root))
                .map_err(|error| error.to_string())?;
            let provider_config =
                ProviderConfig::from_env().map_err(|error| error.to_string())?;
            let provider =
                HttpProvider::new(provider_config).map_err(|error| error.to_string())?;
            let runtime = AgentRuntime::new(pack, provider, SystemForegroundGate, bridge)
                .map_err(|error| error.to_string())?;

            println!(
                "PalAgentDialogue running ownerPid={owner_pid}; requests are consumed only while Palworld-Win64-Shipping.exe is foreground."
            );
            while process_is_running(owner_pid).map_err(|error| error.to_string())? {
                match runtime.process_next().await {
                    Ok(ProcessOutcome::Completed { request_id }) => {
                        println!("completed requestId={request_id}")
                    }
                    Ok(ProcessOutcome::Failed {
                        error_code,
                        retryable,
                    }) => eprintln!("failed code={error_code} retryable={retryable}"),
                    Ok(ProcessOutcome::Duplicate { request_id }) => {
                        println!("duplicate requestId={request_id}")
                    }
                    Ok(ProcessOutcome::GameNotForeground | ProcessOutcome::Idle) => {}
                    Err(error) => eprintln!("runtime-error: {error}"),
                }
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
            println!("owner-exited pid={owner_pid}; stopping Agent runtime");
            Ok(())
        }
        _ => Err(
            "usage: pal-agent-dialogue validate-pack <pack.json> | doctor <pack.json> <bridge-root> | provider-check | run|process-once <pack.json> <bridge-root> | run-owned <pack.json> <bridge-root> <owner-pid>"
                .into(),
        ),
    }
}
