$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$verifier = Join-Path $projectRoot 'tools\verify_core.py'
$nativeTextVerifier = Join-Path $projectRoot 'tools\verify_native_text_bindings.py'

python $verifier
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

python $nativeTextVerifier
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
