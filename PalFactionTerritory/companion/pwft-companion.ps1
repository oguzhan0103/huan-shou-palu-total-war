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

function Resolve-StateDirectory {
    param([string]$Requested)

    $Candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $Candidates.Add($Requested)
    }
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
            if ($Context.Request.HttpMethod -ne "GET") {
                Write-JsonResponse -Context $Context -StatusCode 405 -Payload @{
                    ok = $false
                    reason = "read-only-console"
                }
                continue
            }
            switch ($Context.Request.Url.AbsolutePath) {
                "/api/health" {
                    Write-JsonResponse -Context $Context -StatusCode 200 -Payload @{
                        ok = $true
                        service = "pwft-companion"
                        readOnly = $true
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
}
