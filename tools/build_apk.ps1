# Builds the release APK (arm64 only, to keep it small) and copies it to the
# project root as DailyDuas-<version>.apk.
#   powershell -ExecutionPolicy Bypass -File tools\build_apk.ps1
# The built-in Gemini key comes from the git-ignored secrets.json (copy
# secrets.example.json and fill it in). Without it the app still builds; users
# paste a key in Settings instead.

$ProjectDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "build_env.ps1")
Set-Location $ProjectDir

$defineArgs = @()
if (Test-Path "secrets.json") {
    $defineArgs = @("--dart-define-from-file=secrets.json")
} else {
    Write-Warning "secrets.json not found: building without a built-in Gemini key."
}

flutter build apk --release --target-platform android-arm64 @defineArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value
Copy-Item "build\app\outputs\flutter-apk\app-release.apk" "DailyDuas-$version.apk" -Force
Write-Host "APK: $ProjectDir\DailyDuas-$version.apk"
