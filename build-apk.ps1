# Build APK in one step.
# The project path contains non-ASCII characters (ai-chinese), which breaks
# aapt2 on Windows, so we mirror the project into C:\lb-build first.
$ErrorActionPreference = "Stop"

$repo = $PSScriptRoot
$build = "C:\lb-build"
$sdk = Join-Path $repo "tools\sdk"
$jdk = Join-Path $repo "tools\jdk\jdk-17.0.21+9"
$gradle = Join-Path $repo "tools\gradle\gradle-8.9\bin\gradle.bat"

if (-not (Test-Path $jdk)) { throw "JDK not found: $jdk" }
if (-not (Test-Path $sdk)) { throw "Android SDK not found: $sdk" }
if (-not (Test-Path $gradle)) { throw "Gradle not found: $gradle" }

$env:JAVA_HOME = $jdk
$env:ANDROID_HOME = $sdk
$env:ANDROID_SDK_ROOT = $sdk
$env:GRADLE_USER_HOME = Join-Path $repo "tools\gradle-home"
$env:Path = "$jdk\bin;$env:Path"

Write-Host "==> Mirroring sources to $build ..."
if (-not (Test-Path $build)) { New-Item -ItemType Directory -Path $build | Out-Null }
robocopy (Join-Path $repo "android") $build /MIR /XD ".gradle" ".kotlin" "build" /NFL /NDL /NJH /NJS | Out-Null

Write-Host "==> Building ..."
Push-Location $build
try {
    & $gradle ":app:assembleDebug" --no-daemon --console=plain
    if ($LASTEXITCODE -ne 0) { throw "Build failed, see errors above" }
} finally {
    Pop-Location
}

$apk = Join-Path $build "app\build\outputs\apk\debug\app-debug.apk"
if (-not (Test-Path $apk)) { throw "APK not produced" }

$outDir = Join-Path $repo "dist"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$out = Join-Path $outDir "LectureBuddy.apk"
Copy-Item $apk $out -Force

Write-Host ""
Write-Host "BUILD OK" -ForegroundColor Green
Write-Host "APK: $out"
Write-Host ("Size: {0:N1} MB" -f ((Get-Item $out).Length / 1MB))