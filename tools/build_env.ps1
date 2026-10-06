# Dot-source this file (". .\tools\build_env.ps1") before running flutter or
# gradle commands. It puts Flutter, the JDK and the Android SDK from D:\DuasSDK
# on PATH and redirects every cache and temp folder there, so the small C: drive
# is left alone.

$SdkRoot = "D:\DuasSDK"
$HomeDir = Join-Path $SdkRoot "home"
foreach ($d in @($SdkRoot, $HomeDir, "$SdkRoot\tmp", "$SdkRoot\gradle", "$SdkRoot\pub-cache")) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

# The SDKs live under D:\DuasSDK\home (flutter\, java\, Android\sdk).
$env:USERPROFILE = $HomeDir
$env:HOME = $HomeDir
$env:TEMP = "$SdkRoot\tmp"
$env:TMP = "$SdkRoot\tmp"
$env:GRADLE_USER_HOME = "$SdkRoot\gradle"
$env:PUB_CACHE = "$SdkRoot\pub-cache"
$env:FLUTTER_SUPPRESS_ANALYTICS = "true"
$env:DART_SUPPRESS_ANALYTICS = "true"
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

$flutterBin = Get-ChildItem "$HomeDir\flutter" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
if ($flutterBin) { $env:PATH = "$($flutterBin.FullName)\bin;$env:PATH" }
$jdk = Get-ChildItem "$HomeDir\java" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
if ($jdk) { $env:JAVA_HOME = $jdk.FullName; $env:PATH = "$($jdk.FullName)\bin;$env:PATH" }
$androidSdk = "$HomeDir\Android\sdk"
if (Test-Path $androidSdk) { $env:ANDROID_HOME = $androidSdk; $env:ANDROID_SDK_ROOT = $androidSdk }
