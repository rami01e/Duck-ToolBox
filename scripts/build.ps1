[CmdletBinding()]
param(
  [string]$NdkRoot = $(if ($env:ANDROID_NDK_HOME) { $env:ANDROID_NDK_HOME } else { "C:\Development\Android\NDK\android-ndk-r30" }),
  [string]$SdkRoot = $(if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { $env:ANDROID_SDK_ROOT }),
  [ValidateSet("debug", "release")]
  [string]$Profile = "release",
  [ValidateSet("arm64-v8a", "x86_64")]
  [string]$AndroidAbi = "arm64-v8a",
  [switch]$SkipRust,
  [switch]$SkipWeb,
  [switch]$PackageModule
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$uiDir = Join-Path $repoRoot "ui"
$packageScript = Join-Path $PSScriptRoot "package-module.ps1"
$toolchainBin = Join-Path $NdkRoot "toolchains\llvm\prebuilt\windows-x86_64\bin"
# cargo-ndk takes an Android ABI; the Rust target triple derives from it.
$rustTarget = if ($AndroidAbi -eq "x86_64") { "x86_64-linux-android" } else { "aarch64-linux-android" }
$binaryRelativePath = "target\$rustTarget\$Profile\duckd"
$binaryPath = Join-Path $repoRoot $binaryRelativePath

function Write-Step([string]$Message) {
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Invoke-Step([string]$Message, [scriptblock]$Action) {
  Write-Step $Message
  & $Action
}

function Assert-Command([string]$Name, [string]$InstallHint) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "$Name is not installed or not on PATH. $InstallHint"
  }
}

function Invoke-Checked([scriptblock]$Action, [string]$FailureMessage) {
  & $Action
  if ($LASTEXITCODE -ne 0) {
    throw $FailureMessage
  }
}

if (-not $SkipRust) {
  if (-not $SdkRoot -or -not (Test-Path $SdkRoot)) {
    throw "Set ANDROID_HOME or pass -SdkRoot with Android SDK Build Tools 36.0.0 installed."
  }
  $env:ANDROID_HOME = $SdkRoot
  Assert-Command "cargo" "Install Rust via rustup before running this script."
  Assert-Command "rustup" "Install Rust via rustup before running this script."

  if (-not (Test-Path $NdkRoot)) {
    throw "Android NDK directory not found at '$NdkRoot'."
  }

  if (-not (Test-Path $toolchainBin)) {
    throw "Android NDK LLVM toolchain not found at '$toolchainBin'."
  }

  $env:ANDROID_NDK_ROOT = $NdkRoot
  $env:ANDROID_NDK_HOME = $NdkRoot
  $env:ANDROID_NDK = $NdkRoot

  $pathEntries = $env:Path -split ";"
  if ($pathEntries -notcontains $toolchainBin) {
    $env:Path = "$toolchainBin;$env:Path"
  }

  Invoke-Step "Checking cargo-ndk" {
    & cargo ndk --version *> $null
    if ($LASTEXITCODE -ne 0) {
      throw "cargo-ndk is required. Install it with: cargo install cargo-ndk --locked"
    }
  }

  Invoke-Step "Ensuring Rust target $rustTarget is installed" {
    $installedTargets = rustup target list --installed
    if ($installedTargets -notcontains $rustTarget) {
      Invoke-Checked { rustup target add $rustTarget } "Failed to add Rust target $rustTarget."
    }
  }

  Invoke-Step "Building Rust backend with cargo-ndk ($AndroidAbi, $Profile)" {
    Push-Location $repoRoot
    try {
      $cargoArgs = @("ndk", "-t", $AndroidAbi, "build", "--package", "duckd")
      if ($Profile -eq "release") {
        $cargoArgs += "--release"
      }
      Invoke-Checked { & cargo @cargoArgs } "Rust Android build failed."
    }
    finally {
      Pop-Location
    }
  }

  if (-not (Test-Path $binaryPath)) {
    throw "Expected Android backend binary was not produced at '$binaryPath'."
  }

  Write-Host "Rust binary: $binaryPath" -ForegroundColor Green
}

if (-not $SkipWeb) {
  Assert-Command "pnpm" "Install pnpm 12 (run corepack enable) before running this script."

  Invoke-Step "Installing WebUI dependencies" {
    Push-Location $uiDir
    try {
      Invoke-Checked { & pnpm install --frozen-lockfile } "pnpm install failed."
    }
    finally {
      Pop-Location
    }
  }

  Invoke-Step "Building WebUI" {
    Assert-Command "git" "Git is required to pin the Play Integrity source to this build."
    $sourceCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch '^[0-9a-f]{40}$') {
      throw "Could not resolve the exact Play Integrity source commit."
    }
    Push-Location $uiDir
    $previousSourceCommit = $env:VITE_PIF_SOURCE_COMMIT
    try {
      $env:VITE_PIF_SOURCE_COMMIT = $sourceCommit
      Invoke-Checked { & pnpm build } "WebUI build failed."
    }
    finally {
      if ($null -eq $previousSourceCommit) {
        Remove-Item Env:VITE_PIF_SOURCE_COMMIT -ErrorAction SilentlyContinue
      } else {
        $env:VITE_PIF_SOURCE_COMMIT = $previousSourceCommit
      }
      Pop-Location
    }
  }

  $webrootIndex = Join-Path $repoRoot "module\webroot\index.html"
  if (-not (Test-Path $webrootIndex)) {
    throw "Expected WebUI output was not produced at '$webrootIndex'."
  }

  Write-Host "WebUI output: $webrootIndex" -ForegroundColor Green
}

Invoke-Step "Building the independent Play Integrity engine" {
  Invoke-Checked { python (Join-Path $PSScriptRoot "build-play-integrity.py") --sdk $SdkRoot } "Play Integrity engine build failed."
}

if ($PackageModule) {
  Invoke-Step "Packaging KernelSU module zip" {
    # The universal package ships both architectures, so both backend binaries must exist.
    $arm64Relative = "target\aarch64-linux-android\$Profile\duckd"
    $x86Relative = "target\x86_64-linux-android\$Profile\duckd"
    foreach ($relative in @($arm64Relative, $x86Relative)) {
      if (-not (Test-Path (Join-Path $repoRoot $relative))) {
        throw "Module packaging needs both backend binaries; '$relative' is missing. Build the other ABI first (rerun with -AndroidAbi set to the missing one) or rerun without -SkipRust."
      }
    }
    & $packageScript -BinaryArm64 $arm64Relative -BinaryX86_64 $x86Relative
    if ($LASTEXITCODE -ne 0) {
      throw "Module packaging failed."
    }
  }
}

Write-Host ""
Write-Host "Build completed successfully." -ForegroundColor Green
