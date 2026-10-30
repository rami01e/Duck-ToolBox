param(
  [string]$BinaryArm64 = "target/aarch64-linux-android/release/duckd",
  [string]$BinaryX86_64 = "target/x86_64-linux-android/release/duckd",
  [string]$DistDir = "dist"
)
$ErrorActionPreference = "Stop"
$script = Join-Path $PSScriptRoot "package-module.py"
$repoRoot = Split-Path -Parent $PSScriptRoot
$versionLine = Get-Content (Join-Path $repoRoot "module/module.prop") | Where-Object { $_ -match '^version=' } | Select-Object -First 1
$version = $versionLine.Split('=', 2)[1].Trim()
python $script --binary-arm64 $BinaryArm64 --binary-x86_64 $BinaryX86_64 --output "$DistDir/duck-toolbox-$version.zip"
if ($LASTEXITCODE -ne 0) { throw "Module validation or packaging failed." }
