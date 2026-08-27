[CmdletBinding()]
param(
    [ValidateSet("Host", "Client", "DedicatedServer")]
    [string]$Role = "",
    [string]$GameRoot = "",
    [string]$OutputRoot = ""
)

$ErrorActionPreference = "Stop"

function Add-Candidate {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    try {
        $Full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    }
    catch {
        return
    }
    if (-not $List.Contains($Full)) {
        $List.Add($Full)
    }
}

function Find-PalworldRoot {
    param([string]$RequestedRoot)

    $Candidates = [System.Collections.Generic.List[string]]::new()
    Add-Candidate $Candidates $RequestedRoot

    $SteamPath = $null
    try {
        $SteamPath = (Get-ItemProperty -LiteralPath `
            "HKCU:\Software\Valve\Steam" -ErrorAction Stop).SteamPath
    }
    catch {
        $SteamPath = $null
    }
    if (-not [string]::IsNullOrWhiteSpace($SteamPath)) {
        Add-Candidate $Candidates `
            (Join-Path $SteamPath "steamapps\common\Palworld")
        $LibraryFile = Join-Path $SteamPath `
            "steamapps\libraryfolders.vdf"
        if (Test-Path -LiteralPath $LibraryFile -PathType Leaf) {
            foreach ($Line in Get-Content -LiteralPath $LibraryFile `
                -Encoding UTF8) {
                if ($Line -match '"path"\s+"([^"]+)"') {
                    $LibraryRoot = $Matches[1].Replace('\\', '\')
                    Add-Candidate $Candidates `
                        (Join-Path $LibraryRoot `
                            "steamapps\common\Palworld")
                }
            }
        }
    }

    foreach ($Drive in Get-PSDrive -PSProvider FileSystem) {
        Add-Candidate $Candidates `
            (Join-Path $Drive.Root `
                "SteamLibrary\steamapps\common\Palworld")
        Add-Candidate $Candidates `
            (Join-Path $Drive.Root `
                "Program Files (x86)\Steam\steamapps\common\Palworld")
        Add-Candidate $Candidates `
            (Join-Path $Drive.Root `
                "Program Files\Steam\steamapps\common\Palworld")
    }

    foreach ($Candidate in $Candidates) {
        $Executable = Join-Path $Candidate `
            "Pal\Binaries\Win64\Palworld-Win64-Shipping.exe"
        if (Test-Path -LiteralPath $Executable -PathType Leaf) {
            return (Resolve-Path -LiteralPath $Candidate).Path.TrimEnd('\')
        }
    }
    return $null
}

function Get-SteamBuildId {
    param([string]$ResolvedGameRoot)
    $CommonRoot = Split-Path -Parent $ResolvedGameRoot
    $SteamAppsRoot = Split-Path -Parent $CommonRoot
    $Manifest = Join-Path $SteamAppsRoot "appmanifest_1623730.acf"
    if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
        return "unknown"
    }
    foreach ($Line in Get-Content -LiteralPath $Manifest -Encoding UTF8) {
        if ($Line -match '"buildid"\s+"([0-9]+)"') {
            return $Matches[1]
        }
    }
    return "unknown"
}

function Protect-PublicText {
    param([string]$Text)

    if ($null -eq $Text) {
        return ""
    }
    $Protected = $Text
    $ProfilePaths = @(
        [Environment]::GetFolderPath("UserProfile"),
        $env:USERPROFILE
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    foreach ($ProfilePath in $ProfilePaths) {
        $Protected = [regex]::Replace(
            $Protected,
            [regex]::Escape($ProfilePath),
            "<USER_PROFILE>",
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    $Protected = [regex]::Replace(
        $Protected,
        '(?<![0-9])7656119[0-9]{10}(?![0-9])',
        '<STEAM_ID_REDACTED>'
    )
    $Protected = [regex]::Replace(
        $Protected,
        '(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])',
        '<IP_REDACTED>'
    )
    $Protected = [regex]::Replace(
        $Protected,
        '(?i)(access[_-]?token|auth[_-]?token|external[_-]?token|password)\s*[=:]\s*[^\s,;]+',
        '$1=<REDACTED>'
    )

    $IdMap = @{}
    $IdReplacer = [System.Text.RegularExpressions.MatchEvaluator]{
        param($Match)
        $Key = $Match.Value.ToUpperInvariant()
        if (-not $IdMap.ContainsKey($Key)) {
            $IdMap[$Key] = "<RUNTIME_ID_$($IdMap.Count + 1)>"
        }
        return $IdMap[$Key]
    }
    return [regex]::Replace(
        $Protected,
        '(?i)(?<![0-9a-f])[0-9a-f]{32}(?![0-9a-f])',
        $IdReplacer
    )
}

if ([string]::IsNullOrWhiteSpace($Role)) {
    Write-Host "请选择这台电脑在测试中的角色："
    Write-Host "  1 = 开房的主机"
    Write-Host "  2 = 加入房间的客户端"
    Write-Host "  3 = 独立服务器"
    $Choice = Read-Host "请输入 1、2 或 3"
    switch ($Choice) {
        "1" { $Role = "Host" }
        "2" { $Role = "Client" }
        "3" { $Role = "DedicatedServer" }
        default { throw "角色无效：只能输入 1、2 或 3。" }
    }
}

$ResolvedGameRoot = Find-PalworldRoot $GameRoot
if ($null -eq $ResolvedGameRoot) {
    throw "没有找到 Palworld。请在 PowerShell 中用 -GameRoot 指定游戏根目录。"
}

$Win64Root = Join-Path $ResolvedGameRoot "Pal\Binaries\Win64"
$ModRoot = Join-Path $Win64Root `
    "ue4ss\Mods\PalFactionTerritory0"
$MainLua = Join-Path $ModRoot "Scripts\main.lua"
$RuntimeLua = Join-Path $ModRoot "Scripts\pwft\runtime.lua"
$RegistryLua = Join-Path $ModRoot "Scripts\pwft\registry.lua"
$EnabledFile = Join-Path $ModRoot "enabled.txt"
$LogPath = Join-Path $Win64Root "ue4ss\UE4SS.log"

foreach ($RequiredPath in @($MainLua, $RuntimeLua, $RegistryLua, $EnabledFile)) {
    if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf)) {
        throw "联机测试版安装不完整，缺少：$RequiredPath"
    }
}
if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
    throw "没有找到 UE4SS.log。请至少启动并退出一次游戏后再收集。"
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $Desktop = [Environment]::GetFolderPath("Desktop")
    if ([string]::IsNullOrWhiteSpace($Desktop)) {
        $Desktop = [Environment]::GetFolderPath("MyDocuments")
    }
    $OutputRoot = Join-Path $Desktop "幻兽帕鲁全面战争_联机测试证据"
}
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BundleName = "PWFT-Multiplayer-$Role-$Stamp"
$BundleRoot = Join-Path $OutputRoot $BundleName
$ZipPath = Join-Path $OutputRoot "$BundleName.zip"
New-Item -ItemType Directory -Path $BundleRoot -Force | Out-Null

$BuildId = Get-SteamBuildId $ResolvedGameRoot
$PalworldProcessRunning = @(
    Get-Process -Name "Palworld-Win64-Shipping" -ErrorAction SilentlyContinue
).Count -gt 0
$StateRoot = Join-Path $ModRoot "State"
$StateFileCount = 0
if (Test-Path -LiteralPath $StateRoot -PathType Container) {
    $StateFileCount = @(
        Get-ChildItem -LiteralPath $StateRoot -Recurse -File -Force
    ).Count
}

$EnvironmentRecord = [ordered]@{
    schemaVersion = "1.0.0"
    collectedAt = (Get-Date).ToString("o")
    role = $Role
    steamBuildId = $BuildId
    expectedSteamBuildId = "24575825"
    buildMatchesPreview = ($BuildId -eq "24575825")
    operatingSystem = [Environment]::OSVersion.VersionString
    powershellVersion = $PSVersionTable.PSVersion.ToString()
    palworldProcessRunningDuringCollection = $PalworldProcessRunning
    modEnabled = (Test-Path -LiteralPath $EnabledFile -PathType Leaf)
    modStateFileCount = $StateFileCount
    mainLuaSha256 = (Get-FileHash -LiteralPath $MainLua `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    runtimeLuaSha256 = (Get-FileHash -LiteralPath $RuntimeLua `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    registryLuaSha256 = (Get-FileHash -LiteralPath $RegistryLua `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    rawSaveGameIncluded = $false
    rawModStateIncluded = $false
    rawFullLogIncluded = $false
}
$EnvironmentRecord | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $BundleRoot `
        "environment.json") -Encoding UTF8

$Needle = '(?i)\[PalFactionTerritory0\]|MULTIPLAYER_|PLAYER_SESSION_|POST_LOGIN_|LOGOUT_|EOS_|EXCEPTION_ACCESS_VIOLATION|Fatal error'
$MatchedLines = @(
    Get-Content -LiteralPath $LogPath -Encoding UTF8 |
        Where-Object { $_ -match $Needle }
)
if ($MatchedLines.Count -gt 6000) {
    $MatchedLines = @($MatchedLines | Select-Object -Last 6000)
}
$ProtectedLog = Protect-PublicText ($MatchedLines -join [Environment]::NewLine)
$ProtectedLog | Set-Content -LiteralPath (Join-Path $BundleRoot `
    "UE4SS-PWFT-sanitized.log") -Encoding UTF8

$ReadyCount = @($MatchedLines | Where-Object {
    $_ -match 'MULTIPLAYER_AUTHORITY_READY'
}).Count
$SessionCount = @($MatchedLines | Where-Object {
    $_ -match 'PLAYER_SESSION_READY'
}).Count
$RemoteCount = @($MatchedLines | Where-Object {
    $_ -match 'PLAYER_SESSION_READY.*role=server-remote'
}).Count
$ObserverCount = @($MatchedLines | Where-Object {
    $_ -match 'multiplayer-client-observer-only'
}).Count
$FatalCount = @($MatchedLines | Where-Object {
    $_ -match '(?i)EXCEPTION_ACCESS_VIOLATION|Fatal error'
}).Count
$EosErrorCount = @($MatchedLines | Where-Object {
    $_ -match '(?i)EOS_.*(?:Failed|Error)'
}).Count

@"
幻兽帕鲁全面战争 v1.0.6 联机测试自动摘要
角色: $Role
Steam Build: $BuildId（预览版目标 24575825）
MULTIPLAYER_AUTHORITY_READY 次数: $ReadyCount
PLAYER_SESSION_READY 次数: $SessionCount
server-remote 会话次数: $RemoteCount
client-observer 记录次数: $ObserverCount
Fatal/EXCEPTION 记录次数: $FatalCount
EOS 失败记录次数: $EosErrorCount
收集时游戏仍在运行: $PalworldProcessRunning

注意：0 次错误不等于测试通过；必须与另一台电脑的截图、操作步骤和时间一起判断。
"@ | Set-Content -LiteralPath (Join-Path $BundleRoot `
    "自动摘要.txt") -Encoding UTF8

@"
# 联机测试回报

- GitHub 用户名或称呼：
- 本机角色：$Role
- 测试日期与北京时间：
- 对方测试者称呼：
- 使用的发布标签／提交号：
- Steam Build：$BuildId
- UE4SS 版本：
- 是否只有本项目 Mod：是 / 否（如否请列出）
- 测试世界：全新临时世界 / 重要存档的副本 / 其他

## 做了哪些用例

- [ ] M01 两人首次连接
- [ ] M02 主机与客户端身份分离
- [ ] M03 客户端退出后用同一角色重连
- [ ] M04 主机退回标题并重新开房
- [ ] M05 连续运行 30 分钟
- [ ] M06 两名玩家分别触发势力事件（仅专用 QA 包）
- [ ] M07 远端 A9 奖励（仅专用 QA 包）
- [ ] M08 多人帕鲁袭击归属（仅专用 QA 包）
- [ ] M09 独立服务器（仅有经验者）

## 结果

- 结论：通过 / 失败 / 无法判断
- 实际看到的现象：
- 预期现象：
- 第一次出问题的准确时间：
- 能否稳定复现：每次 / 偶尔 / 只发生一次
- 复现步骤（按 1、2、3 写）：
- 截图或视频链接：
- 对方证据包文件名：

## 隐私确认

- [ ] 没有上传 Palworld SaveGames
- [ ] 没有上传 `State` 原文件
- [ ] 没有上传 Steam 登录令牌、邮箱、密码或未脱敏完整日志
"@ | Set-Content -LiteralPath (Join-Path $BundleRoot `
    "请填写_测试回报.md") -Encoding UTF8

@"
这个证据包可以公开上传到本项目 GitHub Issue。

它只包含：
1. 本 Mod 与联机相关的脱敏日志行；
2. 不含用户名和绝对安装路径的环境摘要；
3. 一份需要人工填写的测试回报模板。

它明确不包含：Palworld SaveGames、Mod State 原文件、完整 UE4SS.log、Steam 登录令牌。
如维护者后来需要 State，请先私下沟通，不要直接发到公开 Issue。
"@ | Set-Content -LiteralPath (Join-Path $BundleRoot `
    "隐私说明.txt") -Encoding UTF8

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
Compress-Archive -LiteralPath $BundleRoot -DestinationPath $ZipPath `
    -CompressionLevel Optimal
$ZipHash = (Get-FileHash -LiteralPath $ZipPath `
    -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Host "PASS 联机测试证据已收集并脱敏。"
Write-Host "文件夹: $BundleRoot"
Write-Host "可公开上传的 ZIP: $ZipPath"
Write-Host "SHA256: $ZipHash"
if ($BuildId -ne "24575825") {
    Write-Warning "当前 Build 是 $BuildId，不是本预览版锁定的 24575825；请在回报中明确写出。"
}
if ($PalworldProcessRunning) {
    Write-Warning "收集时游戏仍在运行。最好完全退出游戏后再收集一次最终证据。"
}
