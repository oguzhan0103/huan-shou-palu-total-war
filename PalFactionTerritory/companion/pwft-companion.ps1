[CmdletBinding()]
param(
    [string]$StateDir = "",
    [ValidateRange(1024, 65535)]
    [int]$Port = 32145,
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"
$CompanionRoot = $PSScriptRoot
$ActiveFileName = "pwft-companion-active-v1.json"
$AgentOperatorStatusFileName = "pwft-agent-operator-status-v1.json"
$AgentOperatorInputFileName = "pwft-agent-operator-input-v1.json"
$OperatorTokenBytes = [byte[]]::new(32)
$OperatorTokenRng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try { $OperatorTokenRng.GetBytes($OperatorTokenBytes) }
finally { $OperatorTokenRng.Dispose() }
$OperatorToken = ([BitConverter]::ToString($OperatorTokenBytes)).Replace("-", "").ToLowerInvariant()
$AgentRuntimeProcess = $null

function Resolve-StateDirectory {
    param([string]$Requested)

    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $Explicit = [System.IO.Path]::GetFullPath($Requested)
        if (-not (Test-Path -LiteralPath $Explicit -PathType Container)) {
            throw "Explicit PalFactionTerritory0/State directory was not found: $Explicit"
        }
        return $Explicit
    }
    $Candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:PWFT_STATE_DIR)) {
        $Candidates.Add($env:PWFT_STATE_DIR)
    }
    $Candidates.Add((Join-Path $CompanionRoot "..\Mods\PalFactionTerritory0\State"))
    $Candidates.Add((Join-Path $CompanionRoot "..\mod0\ue4ss\PalFactionTerritory0\State"))
    $Candidates.Add("E:\SteamLibrary\steamapps\common\Palworld\Pal\Binaries\Win64\ue4ss\Mods\PalFactionTerritory0\State")
    $Candidates.Add("C:\Program Files (x86)\Steam\steamapps\common\Palworld\Pal\Binaries\Win64\ue4ss\Mods\PalFactionTerritory0\State")

    $Existing = @()
    foreach ($Candidate in $Candidates) {
        try {
            $Resolved = [System.IO.Path]::GetFullPath($Candidate)
        }
        catch {
            continue
        }
        if (Test-Path -LiteralPath $Resolved -PathType Container) {
            $Existing += $Resolved
            if (Test-Path -LiteralPath (Join-Path $Resolved $ActiveFileName) -PathType Leaf) {
                return $Resolved
            }
        }
    }
    if ($Existing.Count -gt 0) {
        return $Existing[0]
    }
    throw "PalFactionTerritory0/State was not found. Pass -StateDir explicitly."
}

function Write-JsonResponse {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [object]$Payload
    )
    $Json = $Payload | ConvertTo-Json -Depth 30 -Compress
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = "application/json; charset=utf-8"
    $Context.Response.Headers["Cache-Control"] = "no-store"
    $Context.Response.ContentLength64 = $Bytes.Length
    $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Context.Response.Close()
}

function Read-ActiveState {
    param([string]$Root)
    $ActivePath = Join-Path $Root $ActiveFileName
    if (-not (Test-Path -LiteralPath $ActivePath -PathType Leaf)) {
        return [ordered]@{
            ok = $false
            reason = "waiting-for-game-profile"
            stateDirectory = $Root
        }
    }
    try {
        $Active = Get-Content -LiteralPath $ActivePath -Raw -Encoding utf8 |
            ConvertFrom-Json
        $StateLeaf = [System.IO.Path]::GetFileName([string]$Active.stateFile)
        if ($StateLeaf -ne [string]$Active.stateFile) {
            throw "active state filename is unsafe"
        }
        $StatePath = Join-Path $Root $StateLeaf
        if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
            return [ordered]@{
                ok = $false
                reason = "state-snapshot-not-ready"
                active = $Active
                stateDirectory = $Root
            }
        }
        $State = Get-Content -LiteralPath $StatePath -Raw -Encoding utf8 |
            ConvertFrom-Json
        return [ordered]@{
            ok = $true
            active = $Active
            state = $State
            stateDirectory = $Root
        }
    }
    catch {
        return [ordered]@{
            ok = $false
            reason = "state-read-failed"
            detail = $_.Exception.Message
            stateDirectory = $Root
        }
    }
}

function Read-TransactionEvents {
    param([string]$Root)
    $ActiveState = Read-ActiveState -Root $Root
    if (-not $ActiveState.ok) {
        return [ordered]@{
            ok = $false
            reason = $ActiveState.reason
            events = @()
        }
    }
    $EventsLeaf = [System.IO.Path]::GetFileName([string]$ActiveState.active.eventsFile)
    if ($EventsLeaf -ne [string]$ActiveState.active.eventsFile) {
        return [ordered]@{ ok = $false; reason = "events-filename-unsafe"; events = @() }
    }
    $EventsPath = Join-Path $Root $EventsLeaf
    if (-not (Test-Path -LiteralPath $EventsPath -PathType Leaf)) {
        return [ordered]@{ ok = $true; events = @() }
    }
    $Events = @()
    foreach ($Line in @(Get-Content -LiteralPath $EventsPath -Encoding utf8 -Tail 250)) {
        if ([string]::IsNullOrWhiteSpace($Line)) { continue }
        try {
            $Events += $Line | ConvertFrom-Json
        }
        catch {
            # A partially flushed last line is ignored until the next refresh.
        }
    }
    return [ordered]@{ ok = $true; events = $Events }
}

function Read-AgentOperatorStatus {
    param([string]$Root)
    $StatusPath = Join-Path $Root $AgentOperatorStatusFileName
    if (-not (Test-Path -LiteralPath $StatusPath -PathType Leaf)) {
        return [ordered]@{
            ok = $false
            reason = "waiting-for-agent-operator"
            canSubmit = $false
        }
    }
    try {
        $Info = Get-Item -LiteralPath $StatusPath
        if ($Info.Length -gt 65536) {
            throw "agent operator status exceeds 64 KiB"
        }
        $Status = Get-Content -LiteralPath $StatusPath -Raw -Encoding utf8 |
            ConvertFrom-Json
        return [ordered]@{
            ok = $true
            status = $Status
        }
    }
    catch {
        return [ordered]@{
            ok = $false
            reason = "agent-operator-status-read-failed"
            detail = $_.Exception.Message
            canSubmit = $false
        }
    }
}

function Write-AgentOperatorCommand {
    param(
        [System.Net.HttpListenerContext]$Context,
        [string]$Root
    )
    $AllowedOrigin = "http://127.0.0.1:$Port"
    if ($Context.Request.RemoteEndPoint -eq $null -or
        -not [System.Net.IPAddress]::IsLoopback($Context.Request.RemoteEndPoint.Address)) {
        return [ordered]@{ StatusCode = 403; Payload = @{ ok = $false; reason = "loopback-only" } }
    }
    if ($Context.Request.Headers["Origin"] -ne $AllowedOrigin -or
        $Context.Request.Headers["X-PWFT-Operator-Token"] -ne $OperatorToken) {
        return [ordered]@{ StatusCode = 403; Payload = @{ ok = $false; reason = "operator-origin-or-token-invalid" } }
    }
    if ($Context.Request.ContentType -notlike "application/json*") {
        return [ordered]@{ StatusCode = 415; Payload = @{ ok = $false; reason = "json-required" } }
    }
    if ($Context.Request.ContentLength64 -gt 32768) {
        return [ordered]@{ StatusCode = 413; Payload = @{ ok = $false; reason = "request-too-large" } }
    }
    try {
        $Reader = [System.IO.StreamReader]::new(
            $Context.Request.InputStream,
            [System.Text.UTF8Encoding]::new($false, $true),
            $true,
            4096,
            $false
        )
        try { $BodyText = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
        if ([System.Text.Encoding]::UTF8.GetByteCount($BodyText) -gt 32768) {
            throw "request body exceeds 32 KiB"
        }
        $Body = $BodyText | ConvertFrom-Json
        $PlayerText = [string]$Body.playerText
        $TextElements = [System.Globalization.StringInfo]::new($PlayerText).LengthInTextElements
        if ([string]::IsNullOrWhiteSpace($PlayerText) -or $TextElements -gt 8000) {
            return [ordered]@{ StatusCode = 400; Payload = @{ ok = $false; reason = "player-text-invalid" } }
        }
        $AgentStatus = Read-AgentOperatorStatus -Root $Root
        if (-not $AgentStatus.ok -or -not [bool]$AgentStatus.status.canSubmit -or
            [string]::IsNullOrWhiteSpace([string]$AgentStatus.status.activePresentationId)) {
            return [ordered]@{ StatusCode = 409; Payload = @{ ok = $false; reason = "no-active-agent-dialogue" } }
        }
        $Command = [ordered]@{
            schemaVersion = "1.0.0"
            commandId = "operator-" + [Guid]::NewGuid().ToString("N")
            createdAtEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            action = "submit-agent-text"
            presentationId = [string]$AgentStatus.status.activePresentationId
            playerText = $PlayerText
        }
        $CommandJson = $Command | ConvertTo-Json -Depth 8 -Compress
        $TargetPath = Join-Path $Root $AgentOperatorInputFileName
        $TemporaryPath = "$TargetPath.tmp-$([Guid]::NewGuid().ToString('N'))"
        $BackupPath = "$TargetPath.bak-$([Guid]::NewGuid().ToString('N'))"
        [System.IO.File]::WriteAllText(
            $TemporaryPath,
            $CommandJson,
            [System.Text.UTF8Encoding]::new($false)
        )
        try {
            if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
                [System.IO.File]::Replace(
                    $TemporaryPath,
                    $TargetPath,
                    $BackupPath
                )
            }
            else {
                [System.IO.File]::Move($TemporaryPath, $TargetPath)
            }
        }
        finally {
            if (Test-Path -LiteralPath $TemporaryPath -PathType Leaf) {
                Remove-Item -LiteralPath $TemporaryPath -Force
            }
            if (Test-Path -LiteralPath $BackupPath -PathType Leaf) {
                Remove-Item -LiteralPath $BackupPath -Force
            }
        }
        return [ordered]@{
            StatusCode = 202
            Payload = @{
                ok = $true
                reason = "agent-text-command-queued"
                commandId = $Command.commandId
                presentationId = $Command.presentationId
                directStateMutation = $false
            }
        }
    }
    catch {
        return [ordered]@{
            StatusCode = 400
            Payload = @{
                ok = $false
                reason = "agent-command-invalid"
                detail = $_.Exception.Message
            }
        }
    }
}

function Start-LocalAgentRuntime {
    param([string]$StateRoot)
    $RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $CompanionRoot "..\.."))
    $Executable = Join-Path $RepositoryRoot "PalAgentDialogue\target\release\pal-agent-dialogue.exe"
    $CharacterPack = Join-Path $RepositoryRoot "PalAgentDialogue\character-packs\pwft-author-sdk-minimal.json"
    $BridgeRoot = Join-Path $StateRoot "AgentDialogue"
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf) -or
        -not (Test-Path -LiteralPath $CharacterPack -PathType Leaf)) {
        Write-Warning "Local Agent runtime or paired character pack is unavailable; the offline dialogue tree remains usable."
        return $null
    }
    $Model = if ([string]::IsNullOrWhiteSpace($env:PAL_AGENT_MODEL)) { "gemma4:e4b" } else { $env:PAL_AGENT_MODEL }
    $Environment = @{
        PAL_AGENT_PROVIDER = "ollama"
        PAL_AGENT_MODEL = $Model
        PAL_AGENT_OLLAMA_BASE_URL = "http://127.0.0.1:11434"
        PAL_AGENT_TIMEOUT_SECONDS = "120"
    }
    $StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = $Executable
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    # The Agent also watches this companion PID. If the console is force-closed
    # and PowerShell cannot run its finally block, the child still self-exits.
    $StartInfo.Arguments = ('run-owned "{0}" "{1}" {2}' -f $CharacterPack, $BridgeRoot, $PID)
    foreach ($Name in $Environment.Keys) {
        $StartInfo.EnvironmentVariables[$Name] = $Environment[$Name]
    }
    $Process = [System.Diagnostics.Process]::new()
    $Process.StartInfo = $StartInfo
    if (-not $Process.Start()) {
        throw "Local Agent runtime could not be started."
    }
    Write-Host "Agent: local Ollama ($Model), PID $($Process.Id)"
    Write-Host "Bridge: $BridgeRoot"
    return $Process
}

function Write-StaticResponse {
    param(
        [System.Net.HttpListenerContext]$Context,
        [string]$RelativePath,
        [string]$ContentType
    )
    $PublicRoot = [System.IO.Path]::GetFullPath((Join-Path $CompanionRoot "public"))
    $Candidate = [System.IO.Path]::GetFullPath((Join-Path $PublicRoot $RelativePath))
    if (-not $Candidate.StartsWith($PublicRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
        Write-JsonResponse -Context $Context -StatusCode 404 -Payload @{ ok = $false; reason = "not-found" }
        return
    }
    $Bytes = [System.IO.File]::ReadAllBytes($Candidate)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = $ContentType
    $Context.Response.Headers["Cache-Control"] = "no-cache"
    $Context.Response.ContentLength64 = $Bytes.Length
    $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Context.Response.Close()
}

$ResolvedStateDir = Resolve-StateDirectory -Requested $StateDir
$Prefix = "http://127.0.0.1:$Port/"
$Listener = [System.Net.HttpListener]::new()
$Listener.Prefixes.Add($Prefix)
$Listener.Start()

try {
    $AgentRuntimeProcess = Start-LocalAgentRuntime -StateRoot $ResolvedStateDir
}
catch {
    Write-Warning "Local Agent startup failed: $($_.Exception.Message)"
}

Write-Host "Palworld Total War - Faction Companion"
Write-Host "URL: $Prefix"
Write-Host "Ledger: $ResolvedStateDir"
Write-Host "Press Ctrl+C to stop."

if (-not $NoBrowser) {
    Start-Process $Prefix
}

try {
    while ($Listener.IsListening) {
        $Context = $Listener.GetContext()
        try {
            if ($Context.Request.HttpMethod -eq "POST" -and
                $Context.Request.Url.AbsolutePath -eq "/api/agent/submit") {
                $Outcome = Write-AgentOperatorCommand -Context $Context -Root $ResolvedStateDir
                Write-JsonResponse -Context $Context -StatusCode $Outcome.StatusCode -Payload $Outcome.Payload
                continue
            }
            if ($Context.Request.HttpMethod -ne "GET") {
                Write-JsonResponse -Context $Context -StatusCode 405 -Payload @{
                    ok = $false
                    reason = "method-not-allowed"
                }
                continue
            }
            switch ($Context.Request.Url.AbsolutePath) {
                "/api/health" {
                    Write-JsonResponse -Context $Context -StatusCode 200 -Payload @{
                        ok = $true
                        service = "pwft-companion"
                        readOnly = $false
                        ledgerReadOnly = $true
                        agentTextSubmission = $true
                        directStateMutation = $false
                        operatorToken = $OperatorToken
                        stateDirectory = $ResolvedStateDir
                    }
                }
                "/api/state" {
                    Write-JsonResponse -Context $Context -StatusCode 200 -Payload (
                        Read-ActiveState -Root $ResolvedStateDir
                    )
                }
                "/api/events" {
                    Write-JsonResponse -Context $Context -StatusCode 200 -Payload (
                        Read-TransactionEvents -Root $ResolvedStateDir
                    )
                }
                "/api/agent/status" {
                    Write-JsonResponse -Context $Context -StatusCode 200 -Payload (
                        Read-AgentOperatorStatus -Root $ResolvedStateDir
                    )
                }
                "/app.js" {
                    Write-StaticResponse -Context $Context -RelativePath "app.js" -ContentType "text/javascript; charset=utf-8"
                }
                "/styles.css" {
                    Write-StaticResponse -Context $Context -RelativePath "styles.css" -ContentType "text/css; charset=utf-8"
                }
                default {
                    Write-StaticResponse -Context $Context -RelativePath "index.html" -ContentType "text/html; charset=utf-8"
                }
            }
        }
        catch {
            if ($Context.Response.OutputStream.CanWrite) {
                Write-JsonResponse -Context $Context -StatusCode 500 -Payload @{
                    ok = $false
                    reason = "request-failed"
                    detail = $_.Exception.Message
                }
            }
        }
    }
}
finally {
    $Listener.Stop()
    $Listener.Close()
    if ($AgentRuntimeProcess -ne $null -and -not $AgentRuntimeProcess.HasExited) {
        $AgentRuntimeProcess.Kill()
        $AgentRuntimeProcess.WaitForExit(5000) | Out-Null
    }
    if ($AgentRuntimeProcess -ne $null) {
        $AgentRuntimeProcess.Dispose()
    }
}
