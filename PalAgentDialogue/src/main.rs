use std::{path::PathBuf, process::ExitCode, time::Duration};

use pal_agent_dialogue::{
    load_character_pack, AgentRuntime, BridgePaths, HttpProvider, ProcessOutcome, ProviderConfig,
    SystemForegroundGate,
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
        _ => Err(
            "usage: pal-agent-dialogue validate-pack <pack.json> | run|process-once <pack.json> <bridge-root>"
                .into(),
        ),
    }
}
