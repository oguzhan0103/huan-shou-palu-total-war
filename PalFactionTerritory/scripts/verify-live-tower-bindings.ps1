param(
    [string]$LogPath = "E:\SteamLibrary\steamapps\common\Palworld\Pal\Binaries\Win64\ue4ss\UE4SS.log"
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$verifier = Join-Path $projectRoot 'tools\verify_live_tower_bindings.py'

python $verifier --log $LogPath
exit $LASTEXITCODE
