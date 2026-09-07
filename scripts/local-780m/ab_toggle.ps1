<#
.SYNOPSIS
  Interleaved A/B (or A/B/C) of one llama-bench binary toggled through an environment
  variable. Arms are rotated every round so no arm always runs hot or cold.

.EXAMPLE
  .\ab_toggle.ps1 -Model ..\..\..\LLama-GUI\models\Nemotron-3-Nano-30B-A3B-Q4_K_M.gguf `
      -EnvName GGML_CUDA_DISABLE_MAMBA2_FUSION -Arms @{ fused = $null; unfused = '1' } -Rounds 4

  $null (or omitted) means "variable absent" - it is removed from the environment, never
  set to "", because ggml tests presence for several of these knobs.

.NOTES
  Refuses to run on battery unless -AllowBattery is given (timing is not comparable).
  Output: one JSON object per arm per round appended to -OutJsonl, and a summary table.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Model,
    [Parameter(Mandatory)] [string] $EnvName,
    [Parameter(Mandatory)] [hashtable] $Arms,
    [int]    $Rounds  = 3,
    [int]    $P       = 128,
    [int]    $N       = 64,
    [int]    $R       = 3,
    [int]    $Ngl     = 99,
    [string] $Bench   = (Join-Path $PSScriptRoot "..\..\build\bin\llama-bench.exe"),
    [string] $OutJsonl = "",
    [string[]] $ExtraArgs = @(),
    [switch] $AllowBattery
)

$ErrorActionPreference = "Stop"

$bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
if ($bat -and $bat.BatteryStatus -ne 2 -and -not $AllowBattery) {
    throw "On battery (BatteryStatus=$($bat.BatteryStatus)); timing is invalid. Plug in or pass -AllowBattery."
}
if (-not (Test-Path $Bench)) { throw "llama-bench not found: $Bench" }
if (-not (Test-Path $Model)) { throw "model not found: $Model" }
if (-not $OutJsonl) { $OutJsonl = Join-Path $PSScriptRoot ("results\ab_{0}_{1}.jsonl" -f $EnvName, (Get-Date -Format yyyyMMdd-HHmmss)) }
New-Item -ItemType Directory -Force (Split-Path $OutJsonl) | Out-Null

# Never let a stale value leak into the "absent" arm.
Remove-Item "Env:$EnvName" -ErrorAction SilentlyContinue
Remove-Item Env:GGML_CUDA_ENABLE_UNIFIED_MEMORY -ErrorAction SilentlyContinue

$armNames = @($Arms.Keys | Sort-Object)
$results  = @{}
foreach ($a in $armNames) { $results[$a] = @{ pp = @(); tg = @() } }

function Invoke-Arm([string] $arm, [int] $round) {
    $val = $Arms[$arm]
    if ($null -eq $val) { Remove-Item "Env:$EnvName" -ErrorAction SilentlyContinue }
    else { Set-Item "Env:$EnvName" -Value ([string] $val) }
    $present = Test-Path "Env:$EnvName"
    $args = @('-m', $Model, '-ngl', $Ngl, '-p', $P, '-n', $N, '-r', $R, '-o', 'json') + $ExtraArgs
    $raw = & $Bench @args 2>$null | Out-String
    $objs = [regex]::Matches($raw, '\{[^{}]*"n_prompt"[^{}]*\}') | ForEach-Object { $_.Value | ConvertFrom-Json }
    $pp = ($objs | Where-Object { $_.n_prompt -gt 0 } | Select-Object -First 1).avg_ts
    $tg = ($objs | Where-Object { $_.n_gen    -gt 0 } | Select-Object -First 1).avg_ts
    $rec = [ordered]@{
        ts = (Get-Date -Format s); round = $round; arm = $arm; env = $EnvName
        value = $(if ($null -eq $val) { 'ABSENT' } else { [string] $val }); env_present = $present
        model = (Split-Path $Model -Leaf); p = $P; n = $N; r = $R; pp_ts = $pp; tg_ts = $tg
    }
    ($rec | ConvertTo-Json -Compress) | Add-Content $OutJsonl
    $results[$arm].pp += $pp; $results[$arm].tg += $tg
    "  r{0} {1,-10} env_present={2,-5} pp{3}={4,8:N2}  tg{5}={6,7:N2}" -f $round, $arm, $present, $P, $pp, $N, $tg
}

"model : $(Split-Path $Model -Leaf)"
"toggle: $EnvName  arms: " + (($armNames | ForEach-Object { "$_=" + $(if ($null -eq $Arms[$_]) { 'ABSENT' } else { $Arms[$_] }) }) -join ', ')
"bench : $Bench"
for ($round = 1; $round -le $Rounds; $round++) {
    # rotate the order by one position each round
    $shift = ($round - 1) % $armNames.Count
    $order = @()
    for ($k = 0; $k -lt $armNames.Count; $k++) { $order += $armNames[($k + $shift) % $armNames.Count] }
    foreach ($arm in $order) { Invoke-Arm $arm $round }
}
Remove-Item "Env:$EnvName" -ErrorAction SilentlyContinue

function Median([double[]] $v) { $s = $v | Sort-Object; if ($s.Count % 2) { $s[[int]($s.Count / 2)] } else { ($s[$s.Count/2 - 1] + $s[$s.Count/2]) / 2 } }

""
"=== summary (median of $Rounds rounds) ==="
$base = $armNames[0]
"{0,-10} {1,10} {2,10}   {3}" -f 'arm', "pp$P", "tg$N", 'tg per-round'
foreach ($a in $armNames) {
    $mpp = Median $results[$a].pp; $mtg = Median $results[$a].tg
    $d = if ($a -ne $base) { " ({0:+0.0;-0.0}% tg vs $base)" -f (100 * ($mtg / (Median $results[$base].tg) - 1)) } else { "" }
    "{0,-10} {1,10:N2} {2,10:N2}   {3}{4}" -f $a, $mpp, $mtg, (($results[$a].tg | ForEach-Object { "{0:N2}" -f $_ }) -join ' '), $d
}
"jsonl: $OutJsonl"
