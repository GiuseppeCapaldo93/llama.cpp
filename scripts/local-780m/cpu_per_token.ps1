<#
.SYNOPSIS
  CPU time consumed by llama-server PER GENERATED TOKEN, during generation only.

.DESCRIPTION
  Starts llama-server, waits for /health, then samples the process's TotalProcessorTime
  immediately before and after one /completion request, so model load and warm-up are
  excluded. Reports CPU-seconds per generated token and the server-reported tg t/s.
  Arms toggle one environment variable (e.g. GGML_CUDA_ACTIVE_WAIT) and are rotated.

  This replaces the earlier whole-process CPU/wall-clock accounting, which included model
  load and was withdrawn (see evidence/EVIDENCE-full.md "OS-level CPU accounting").

.EXAMPLE
  .\cpu_per_token.ps1 -Model ..\..\..\LLama-GUI\models\gemma-4-12b-it-Q4_K_M.gguf `
      -EnvName GGML_CUDA_ACTIVE_WAIT -Arms @{ blocking = $null; spin = '1' } -Rounds 3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Model,
    [Parameter(Mandatory)] [string] $EnvName,
    [Parameter(Mandatory)] [hashtable] $Arms,
    [int]    $Rounds   = 3,
    [int]    $NPredict = 128,
    [int]    $Port     = 8097,
    [string] $Server   = (Join-Path $PSScriptRoot "..\..\build\bin\llama-server.exe"),
    [string] $OutJsonl = "",
    [switch] $AllowBattery
)

$ErrorActionPreference = "Stop"
$bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
if ($bat -and $bat.BatteryStatus -ne 2 -and -not $AllowBattery) { throw "On battery; pass -AllowBattery to override." }
if (-not (Test-Path $Server)) { throw "llama-server not found: $Server" }
if (-not $OutJsonl) { $OutJsonl = Join-Path $PSScriptRoot ("results\cpu_{0}_{1}.jsonl" -f $EnvName, (Get-Date -Format yyyyMMdd-HHmmss)) }
New-Item -ItemType Directory -Force (Split-Path $OutJsonl) | Out-Null
Remove-Item Env:GGML_CUDA_ENABLE_UNIFIED_MEMORY -ErrorAction SilentlyContinue

$prompt = "Write a detailed, multi-paragraph explanation of how a wind turbine converts kinetic energy into electricity, covering the rotor, gearbox, generator and grid connection."
$armNames = @($Arms.Keys | Sort-Object)
$results = @{}
foreach ($a in $armNames) { $results[$a] = @{ cpu_per_tok = @(); tg = @(); cores = @() } }

function Invoke-Arm([string] $arm, [int] $round) {
    $val = $Arms[$arm]
    if ($null -eq $val) { Remove-Item "Env:$EnvName" -ErrorAction SilentlyContinue } else { Set-Item "Env:$EnvName" -Value ([string] $val) }
    $present = Test-Path "Env:$EnvName"
    $p = Start-Process -FilePath $Server -ArgumentList @('-m', $Model, '-ngl', '99', '-c', '4096', '-np', '1', '--host', '127.0.0.1', '--port', $Port, '-lv', '0') -PassThru -WindowStyle Hidden
    try {
        $deadline = (Get-Date).AddSeconds(240); $ok = $false
        while (-not $ok -and (Get-Date) -lt $deadline -and -not $p.HasExited) {
            Start-Sleep 2
            try { $h = Invoke-RestMethod "http://127.0.0.1:$Port/health" -Proxy $null -TimeoutSec 3; if ($h.status -eq 'ok') { $ok = $true } } catch {}
        }
        if (-not $ok) { throw "server did not become healthy (arm=$arm)" }
        # warm-up request so the first-token compile/alloc costs are not attributed to the measured run
        $body = @{ prompt = $prompt; n_predict = 8; temperature = 0 } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "http://127.0.0.1:$Port/completion" -Method Post -Body $body -ContentType 'application/json' -Proxy $null -TimeoutSec 300 | Out-Null
        Start-Sleep 1
        $p.Refresh(); $cpu0 = $p.TotalProcessorTime; $t0 = Get-Date
        $body = @{ prompt = $prompt; n_predict = $NPredict; temperature = 0 } | ConvertTo-Json -Compress
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/completion" -Method Post -Body $body -ContentType 'application/json' -Proxy $null -TimeoutSec 600
        $p.Refresh(); $cpu1 = $p.TotalProcessorTime; $t1 = Get-Date
        $cpuSec = ($cpu1 - $cpu0).TotalSeconds; $wall = ($t1 - $t0).TotalSeconds
        $ntok = [int] $r.timings.predicted_n
        $rec = [ordered]@{
            ts = (Get-Date -Format s); round = $round; arm = $arm; env = $EnvName
            value = $(if ($null -eq $val) { 'ABSENT' } else { [string] $val }); env_present = $present
            model = (Split-Path $Model -Leaf); n_predict = $ntok; prompt_n = [int] $r.timings.prompt_n
            cpu_s = [math]::Round($cpuSec, 3); wall_s = [math]::Round($wall, 3)
            cpu_ms_per_tok = [math]::Round(1000 * $cpuSec / $ntok, 2)
            cores_busy = [math]::Round($cpuSec / $wall, 2)
            tg_ts = [math]::Round($r.timings.predicted_per_second, 2)
            pp_ts = [math]::Round($r.timings.prompt_per_second, 1)
        }
        ($rec | ConvertTo-Json -Compress) | Add-Content $OutJsonl
        $results[$arm].cpu_per_tok += $rec.cpu_ms_per_tok; $results[$arm].tg += $rec.tg_ts; $results[$arm].cores += $rec.cores_busy
        "  r{0} {1,-9} env_present={2,-5} cpu={3,6:N2} ms/tok  cores_busy={4,4:N2}  tg={5,6:N2} t/s  (n={6})" -f $round, $arm, $present, $rec.cpu_ms_per_tok, $rec.cores_busy, $rec.tg_ts, $ntok
    } finally {
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
        Start-Sleep 2
    }
}

"model : $(Split-Path $Model -Leaf)"
"toggle: $EnvName  arms: " + (($armNames | ForEach-Object { "$_=" + $(if ($null -eq $Arms[$_]) { 'ABSENT' } else { $Arms[$_] }) }) -join ', ')
for ($round = 1; $round -le $Rounds; $round++) {
    $order = if ($round % 2) { $armNames } else { @($armNames[($armNames.Count-1)..0]) }
    foreach ($arm in $order) { Invoke-Arm $arm $round }
}
Remove-Item "Env:$EnvName" -ErrorAction SilentlyContinue

function Median([double[]] $v) { $s = @($v | Sort-Object); $n = $s.Count; if ($n % 2) { $s[[math]::Floor($n / 2)] } else { ($s[$n/2 - 1] + $s[$n/2]) / 2 } }
""
"=== summary (median of $Rounds rounds, generation only) ==="
"{0,-9} {1,14} {2,11} {3,9}" -f 'arm', 'cpu ms/token', 'cores busy', 'tg t/s'
foreach ($a in $armNames) { "{0,-9} {1,14:N2} {2,11:N2} {3,9:N2}" -f $a, (Median $results[$a].cpu_per_tok), (Median $results[$a].cores), (Median $results[$a].tg) }
"jsonl: $OutJsonl"
