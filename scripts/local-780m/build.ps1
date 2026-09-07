<#
.SYNOPSIS
  Build llama.cpp with the HIP backend for a Radeon 780M (gfx1103) on Windows and
  make build\bin a self-contained runtime (ROCm DLLs + Tensile kernel libraries).

.DESCRIPTION
  Reproduces the configuration used for the LLama-GUI / Unsloth deployments:
    Ninja, Release, GGML_HIP=ON, gfx1103, clang/clang++ and lld-link from the
    TheRock ROCm SDK installed in the rocmvenv Python environment, MSVC 14.44
    headers/libs via vcvars64.

  After the build, every ROCm DLL that build\bin\*.dll / *.exe import (transitively)
  is copied next to them, together with rocblas\library and hipblaslt\library, so
  the folder can be pointed at directly by:
    - Unsloth Studio:  UNSLOTH_LLAMA_CPP_PATH=<repo root>  (finds build\bin\llama-server.exe)
    - LLama-GUI:       llama\custom\bin junction -> <repo root>\build\bin

.PARAMETER RocmVenv
  Python venv that holds the rocm-sdk-* wheels (default: %USERPROFILE%\llm-bench\rocmvenv).
.PARAMETER BuildDir
  CMake build directory relative to the repo root (default: build).
.PARAMETER Arch
  AMD GPU target (default: gfx1103).
.PARAMETER Jobs
  Parallel compile jobs (default: number of logical processors).
.PARAMETER Reconfigure
  Delete CMakeCache.txt first to force a fresh configure.
.PARAMETER SkipDeploy
  Build only; do not copy the ROCm runtime into build\bin.
.PARAMETER Targets
  Optional list of CMake targets (default: everything).
#>
[CmdletBinding()]
param(
    [string]   $RocmVenv    = (Join-Path $env:USERPROFILE "llm-bench\rocmvenv"),
    [string]   $BuildDir    = "build",
    [string]   $Arch        = "gfx1103",
    [int]      $Jobs        = [Environment]::ProcessorCount,
    [switch]   $Reconfigure,
    [switch]   $SkipDeploy,
    [string[]] $Targets     = @()
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repo  = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$build = Join-Path $repo $BuildDir
$sp    = Join-Path $RocmVenv "Lib\site-packages"
$sdk   = Join-Path $sp "_rocm_sdk_devel"
$core  = Join-Path $sp "_rocm_sdk_core"
$libs  = Join-Path $sp "_rocm_sdk_libraries"

foreach ($d in @($sdk, $core, $libs)) {
    if (-not (Test-Path $d)) { throw "ROCm SDK component not found: $d (pip install rocm[libraries,devel] into $RocmVenv)" }
}

# --- toolchain ---------------------------------------------------------------
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found; install Visual Studio Build Tools" }
$vsRoot = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath -latest
if (-not $vsRoot) { throw "No Visual Studio installation with the C++ toolset was found" }
$vcvars = Join-Path $vsRoot "VC\Auxiliary\Build\vcvars64.bat"

$ninja = (Get-Command ninja.exe -ErrorAction SilentlyContinue).Source
if (-not $ninja) { throw "ninja.exe not on PATH (winget install Ninja-build.Ninja)" }
$cmake = (Get-Command cmake.exe -ErrorAction SilentlyContinue).Source
if (-not $cmake) { throw "cmake.exe not on PATH" }

$clang   = (Join-Path $sdk "lib\llvm\bin\clang.exe")   -replace '\\', '/'
$clangxx = (Join-Path $sdk "lib\llvm\bin\clang++.exe") -replace '\\', '/'
$sdkFwd  = $sdk -replace '\\', '/'

Write-Host "repo      : $repo"
Write-Host "build dir : $build"
Write-Host "ROCm SDK  : $sdk"
Write-Host "VS        : $vsRoot"
Write-Host "arch      : $Arch   jobs: $Jobs"

if ($Reconfigure -and (Test-Path (Join-Path $build "CMakeCache.txt"))) {
    Remove-Item (Join-Path $build "CMakeCache.txt") -Force
}

# --- configure + build (inside one cmd.exe so vcvars64 applies) ----------------
$cfgArgs = @(
    "-S `"$repo`"", "-B `"$build`"", "-G Ninja",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_C_COMPILER=$clang",
    "-DCMAKE_CXX_COMPILER=$clangxx",
    "-DCMAKE_PREFIX_PATH=$sdkFwd",
    "-DGGML_HIP=ON",
    "-DAMDGPU_TARGETS=$Arch",
    "-DCMAKE_HIP_ARCHITECTURES=$Arch",
    "-DGGML_HIP_GRAPHS=ON",
    "-DGGML_HIP_NO_VMM=ON",
    "-DGGML_NATIVE=ON",
    "-DGGML_OPENMP=ON",
    "-DBUILD_SHARED_LIBS=ON",
    "-DLLAMA_BUILD_TESTS=OFF",
    "-DLLAMA_BUILD_EXAMPLES=ON",
    "-DLLAMA_BUILD_SERVER=ON",
    "-DLLAMA_CURL=OFF"
) -join " "

$bldArgs = "--build `"$build`" -j $Jobs"
if ($Targets.Count -gt 0) { $bldArgs += " --target " + ($Targets -join " ") }

$cmd = "call `"$vcvars`" -vcvars_ver=14.44 >nul 2>&1 && " +
       "set `"HIP_PATH=$sdk`" && set `"ROCM_PATH=$sdk`" && " +
       "set `"PATH=$sdk\bin;$core\bin;$libs\bin;%PATH%`" && " +
       "`"$cmake`" $cfgArgs && `"$cmake`" $bldArgs"

& $env:ComSpec /c $cmd
if ($LASTEXITCODE -ne 0) { throw "configure/build failed (exit $LASTEXITCODE)" }

$bin = Join-Path $build "bin"
if (-not (Test-Path (Join-Path $bin "llama-server.exe"))) { throw "llama-server.exe not produced in $bin" }
Write-Host "BUILD OK -> $bin"

if ($SkipDeploy) { return }

# --- deploy ROCm runtime next to the binaries ---------------------------------
$readobj  = Join-Path $sdk "lib\llvm\bin\llvm-readobj.exe"
$srcDirs  = @((Join-Path $core "bin"), (Join-Path $libs "bin"), (Join-Path $sdk "bin"))
$present  = @{}
Get-ChildItem $bin -Filter *.dll | ForEach-Object { $present[$_.Name.ToLower()] = $true }

function Get-Imports([string] $file) {
    @(& $readobj --coff-imports $file 2>$null |
        Select-String -Pattern '^\s*Name:\s*(\S+\.dll)\s*$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value.ToLower() } |
        Sort-Object -Unique)
}

$copied = New-Object System.Collections.Generic.List[string]
$queue  = New-Object System.Collections.Generic.Queue[string]

function Add-Runtime([string] $name, [string] $src) {
    Copy-Item $src (Join-Path $bin $name) -Force
    $present[$name.ToLower()] = $true
    $copied.Add($name)
    $queue.Enqueue((Join-Path $bin $name))
}

function Resolve-Queue {
    while ($queue.Count -gt 0) {
        $f = $queue.Dequeue()
        foreach ($imp in (Get-Imports $f)) {
            if ($present.ContainsKey($imp)) { continue }
            foreach ($d in $srcDirs) {
                $c = Join-Path $d $imp
                if (Test-Path $c) { Add-Runtime $imp $c; break }
            }
        }
    }
}

Get-ChildItem $bin -File | Where-Object { $_.Extension -in ".dll", ".exe" } | ForEach-Object { $queue.Enqueue($_.FullName) }
Resolve-Queue

# Loaded at runtime via LoadLibrary, so they never show up in an import table.
foreach ($pattern in @("amd_comgr*.dll", "hiprtc*.dll", "libhipblaslt.dll", "rocm_kpack.dll")) {
    foreach ($d in $srcDirs) {
        Get-ChildItem $d -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not $present.ContainsKey($_.Name.ToLower())) { Add-Runtime $_.Name $_.FullName }
        }
    }
}
Resolve-Queue

# Tensile / hipBLASLt kernel libraries are resolved relative to the DLL location.
foreach ($lib in @("rocblas", "hipblaslt")) {
    $srcLib = Join-Path $libs "bin\$lib\library"
    if (Test-Path $srcLib) {
        $dstLib = Join-Path $bin "$lib\library"
        New-Item -ItemType Directory -Force $dstLib | Out-Null
        Copy-Item (Join-Path $srcLib "*") $dstLib -Recurse -Force
        $n = (Get-ChildItem $dstLib -File -Recurse).Count
        Write-Host ("deployed {0}\library ({1} files)" -f $lib, $n)
    }
}

Write-Host ("deployed {0} ROCm DLLs: {1}" -f $copied.Count, (($copied | Sort-Object -Unique) -join ", "))
Write-Host "DEPLOY OK -> $bin"
