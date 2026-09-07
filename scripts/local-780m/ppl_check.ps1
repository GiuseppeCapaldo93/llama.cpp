<#
.SYNOPSIS
  Perplexity of one GGUF on the CPU backend vs the ROCm backend (optionally with env
  toggles), so kernel rewrites and graph fusions are checked end to end, not just per op.

.EXAMPLE
  .\ppl_check.ps1 -Model ..\..\..\LLama-GUI\models\gemma-4-12b-it-Q4_K_M.gguf -Chunks 8 `
      -RocmArms @{ default = @{}; upstream_geometry = @{ GGML_CUDA_MMVQ_CFG = '0' } }

.NOTES
  -Text defaults to a concatenation of the repo's docs/*.md (deterministic, no download).
  CPU is the reference; differences between arms are reported in percent of the CPU PPL.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Model,
    [string] $Text   = "",
    [int]    $Ctx    = 512,
    [int]    $Chunks = 8,
    [int]    $Threads = 8,
    [hashtable] $RocmArms = @{ default = @{} },
    [string] $Perplexity = (Join-Path $PSScriptRoot "..\..\build-tests\bin\llama-perplexity.exe"),
    [string] $OutJsonl = ""
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $Perplexity)) { throw "llama-perplexity not found: $Perplexity (build with -Tests ... -Targets llama-perplexity)" }
if (-not $OutJsonl) { $OutJsonl = Join-Path $PSScriptRoot ("results\ppl_{0}_{1}.jsonl" -f ((Split-Path $Model -Leaf) -replace '\.gguf$',''), (Get-Date -Format yyyyMMdd-HHmmss)) }
New-Item -ItemType Directory -Force (Split-Path $OutJsonl) | Out-Null

if (-not $Text) {
    $Text = Join-Path (Split-Path $OutJsonl) "ppl_corpus_docs.txt"
    if (-not (Test-Path $Text)) {
        $docs = Get-ChildItem (Join-Path $PSScriptRoot "..\..\docs") -Filter *.md -Recurse | Sort-Object FullName
        $sb = New-Object System.Text.StringBuilder
        foreach ($d in $docs) { [void] $sb.Append((Get-Content $d.FullName -Raw)); [void] $sb.Append("`n`n") }
        [IO.File]::WriteAllText($Text, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
    }
}
"corpus: $Text ($([math]::Round((Get-Item $Text).Length/1KB)) KB)  ctx=$Ctx chunks=$Chunks"

Remove-Item Env:GGML_CUDA_ENABLE_UNIFIED_MEMORY -ErrorAction SilentlyContinue

function Run-Ppl([string] $arm, [int] $ngl, [hashtable] $envs) {
    $saved = @{}
    foreach ($k in $envs.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); Set-Item "Env:$k" -Value ([string] $envs[$k]) }
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $raw = & $Perplexity -m $Model -f $Text -c $Ctx --chunks $Chunks -ngl $ngl -t $Threads -b 512 2>&1 | Out-String
        $sw.Stop()
        $clean = $raw -replace "\x1b\[[0-9;]*m", ""
        $ppl = if ($clean -match 'Final estimate: PPL = ([0-9.]+) \+/- ([0-9.]+)') { [double] $matches[1] } else { $null }
        $err = if ($ppl) { [double] $matches[2] } else { $null }
        $rec = [ordered]@{ ts = (Get-Date -Format s); arm = $arm; ngl = $ngl; env = ($envs | ConvertTo-Json -Compress); model = (Split-Path $Model -Leaf); ctx = $Ctx; chunks = $Chunks; ppl = $ppl; ppl_err = $err; seconds = [int] $sw.Elapsed.TotalSeconds }
        ($rec | ConvertTo-Json -Compress) | Add-Content $OutJsonl
        if (-not $ppl) { "  {0,-20} FAILED to parse PPL; tail:" -f $arm; ($clean -split "`n" | Select-Object -Last 6) }
        return $rec
    } finally {
        foreach ($k in $envs.Keys) { if ($null -eq $saved[$k]) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue } else { Set-Item "Env:$k" -Value $saved[$k] } }
    }
}

"model : $(Split-Path $Model -Leaf)"
$cpu = Run-Ppl 'cpu_reference' 0 @{}
"  {0,-20} PPL = {1:N4} +/- {2:N4}  ({3}s)" -f $cpu.arm, $cpu.ppl, $cpu.ppl_err, $cpu.seconds
foreach ($a in ($RocmArms.Keys | Sort-Object)) {
    $r = Run-Ppl "rocm_$a" 99 $RocmArms[$a]
    $d = if ($cpu.ppl -and $r.ppl) { " delta vs CPU = {0:+0.000;-0.000}%" -f (100 * ($r.ppl / $cpu.ppl - 1)) } else { "" }
    "  {0,-20} PPL = {1:N4} +/- {2:N4}  ({3}s){4}" -f $r.arm, $r.ppl, $r.ppl_err, $r.seconds, $d
}
"jsonl: $OutJsonl"
