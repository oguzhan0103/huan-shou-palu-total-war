[CmdletBinding()]
param(
    [string]$ObjectDumpPath =
        "E:\SteamLibrary\steamapps\common\Palworld\Pal\Binaries\Win64\ue4ss\UE4SS_ObjectDump.txt",
    [string]$ExpectedSha256 =
        "7B73AE341D48A18D7019D732E6B765FD85051F83BE3A76078CAAFB97888A8557"
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $ObjectDumpPath -PathType Leaf)) {
    throw "Current-Build ObjectDump is missing: $ObjectDumpPath"
}

$ActualHash = (Get-FileHash -LiteralPath $ObjectDumpPath `
    -Algorithm SHA256).Hash.ToUpperInvariant()
if ($ActualHash -ne $ExpectedSha256.ToUpperInvariant()) {
    throw "ObjectDump hash mismatch: expected=$ExpectedSha256 actual=$ActualHash"
}

$RequiredPatterns = [ordered]@{
    ServerNpcDamage = 'Function /Script/Pal\.PalPlayerController:DamageReactionComponent_ProcessDamage_ToServer_ToNPC'
    ServerNpcInfo = 'StructProperty /Script/Pal\.PalPlayerController:DamageReactionComponent_ProcessDamage_ToServer_ToNPC:Info \[o: 0\]'
    ServerNpcDefender = 'ObjectProperty /Script/Pal\.PalPlayerController:DamageReactionComponent_ProcessDamage_ToServer_ToNPC:Defender \[o: 130\]'
    DamageInfoStruct = 'ScriptStruct /Script/Pal\.PalDamageInfo'
    NativeDamageValue = 'IntProperty /Script/Pal\.PalDamageInfo:NativeDamageValue \[o: 0\]'
    DamageInfoAttacker = 'ObjectProperty /Script/Pal\.PalDamageInfo:Attacker \[o: 48\]'
    DamageInfoNoDamage = 'BoolProperty /Script/Pal\.PalDamageInfo:NoDamage \[o: D6\]'
    CharacterDamagedServerEvent = 'Function /Script/Pal\.PalEventNotify_Character:OnCharacterDamaged_ServerInternal'
    DamageResultParameter = 'StructProperty /Script/Pal\.PalEventNotify_Character:OnCharacterDamaged_ServerInternal:DamageResult \[o: 0\]'
    DamageResultStruct = 'ScriptStruct /Script/Pal\.PalDamageResult'
    Damage = 'IntProperty /Script/Pal\.PalDamageResult:Damage \[o: 0\]'
    Attacker = 'ObjectProperty /Script/Pal\.PalDamageResult:Attacker \[o: 8\]'
    Defender = 'ObjectProperty /Script/Pal\.PalDamageResult:Defender \[o: 10\]'
    ActualDamage = 'IntProperty /Script/Pal\.PalDamageResult:ActualDamage \[o: 50\]'
}

foreach ($Entry in $RequiredPatterns.GetEnumerator()) {
    $Match = Select-String -LiteralPath $ObjectDumpPath `
        -Pattern $Entry.Value -Encoding utf8
    if (@($Match).Count -ne 1) {
        throw "Current-Build native damage signature mismatch: $($Entry.Key) matches=$(@($Match).Count)"
    }
}

Write-Host "PASS current-Build native damage contract"
Write-Host "ObjectDump: $ObjectDumpPath"
Write-Host "SHA-256: $ActualHash"
Write-Host "Primary authority hook: /Script/Pal.PalPlayerController:DamageReactionComponent_ProcessDamage_ToServer_ToNPC"
Write-Host "Primary parameters: Info@0x0 Defender@0x130"
Write-Host "PalDamageInfo fields: NativeDamageValue@0x0 Attacker@0x48 NoDamage@0xD6"
Write-Host "Pal fallback hook: /Script/Pal.PalEventNotify_Character:OnCharacterDamaged_ServerInternal"
Write-Host "Fallback parameter: DamageResult@0x0; fields Attacker@0x8 Defender@0x10 ActualDamage@0x50"
