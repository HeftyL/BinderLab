param(
    [string]$SdkRoot = $(if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { "D:\Android" }),
    [string]$CompileSdkPlatform = "36.1",
    [string]$BuildToolsVersion = "36.0.0"
)

$ErrorActionPreference = "Stop"

$projectRoot = $PSScriptRoot
$buildDir = Join-Path $projectRoot "build"
$targetSdk = 36
$minSdk = 26
$platformDir = Join-Path $SdkRoot "platforms\android-$CompileSdkPlatform"
$toolsDir = Join-Path $SdkRoot "build-tools\$BuildToolsVersion"
$androidJar = Join-Path $platformDir "android.jar"
$frameworkAidl = Join-Path $platformDir "framework.aidl"
$aidl = Join-Path $toolsDir "aidl.exe"
$aapt2 = Join-Path $toolsDir "aapt2.exe"
$d8 = Join-Path $toolsDir "d8.bat"
$zipalign = Join-Path $toolsDir "zipalign.exe"
$apksigner = Join-Path $toolsDir "apksigner.bat"

foreach ($required in @(
    $androidJar,
    $frameworkAidl,
    $aidl,
    $aapt2,
    $d8,
    $zipalign,
    $apksigner
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing build dependency: $required"
    }
}

$javac = (Get-Command javac.exe -ErrorAction Stop).Source
$jar = Join-Path (Split-Path -Parent $javac) "jar.exe"
$keytool = Join-Path (Split-Path -Parent $javac) "keytool.exe"

if (Test-Path -LiteralPath $buildDir) {
    $expected = Join-Path (Resolve-Path -LiteralPath $projectRoot).Path "build"
    $resolved = (Resolve-Path -LiteralPath $buildDir).Path
    if ($resolved -ne $expected) {
        throw "Refusing to clean unexpected directory: $resolved"
    }
    Remove-Item -LiteralPath $buildDir -Recurse -Force
}

$generatedDir = Join-Path $buildDir "generated"
$classesDir = Join-Path $buildDir "classes"
$dexDir = Join-Path $buildDir "dex"
New-Item -ItemType Directory -Force -Path $generatedDir, $classesDir, $dexDir | Out-Null

$signingDir = Join-Path $projectRoot ".debug"
$keystore = Join-Path $signingDir "debug.keystore"
if (-not (Test-Path -LiteralPath $keystore -PathType Leaf)) {
    New-Item -ItemType Directory -Force -Path $signingDir | Out-Null
    & $keytool `
        -genkeypair `
        -keystore $keystore `
        -storepass android `
        -alias androiddebugkey `
        -keypass android `
        -dname "CN=Android Debug,O=Android,C=US" `
        -keyalg RSA `
        -keysize 2048 `
        -validity 10000
    if ($LASTEXITCODE -ne 0) {
        throw "debug keystore generation failed"
    }
}

$aidlRoot = Join-Path $projectRoot "aidl"
$aidlFiles = Get-ChildItem -LiteralPath $aidlRoot -Recurse -Filter "*.aidl" -File |
    Sort-Object FullName
foreach ($file in $aidlFiles) {
    & $aidl `
        "--lang=java" `
        "--min_sdk_version=$minSdk" `
        "--omit_invocation" `
        "-Werror" `
        "-p$frameworkAidl" `
        "-I$aidlRoot" `
        "-o$generatedDir" `
        $file.FullName
    if ($LASTEXITCODE -ne 0) {
        throw "AIDL failed: $($file.FullName)"
    }
}

$sources = @(
    Get-ChildItem -LiteralPath (Join-Path $projectRoot "src") -Recurse -Filter "*.java" -File
    Get-ChildItem -LiteralPath $generatedDir -Recurse -Filter "*.java" -File
) | ForEach-Object { $_.FullName }

& $javac `
    -encoding UTF-8 `
    -source 8 `
    -target 8 `
    -Xlint:-options `
    -classpath $androidJar `
    -d $classesDir `
    @sources
if ($LASTEXITCODE -ne 0) {
    throw "javac failed"
}

$classesJar = Join-Path $buildDir "classes.jar"
& $jar cf $classesJar -C $classesDir .
if ($LASTEXITCODE -ne 0) {
    throw "jar failed"
}

& $d8 --lib $androidJar --min-api $minSdk --output $dexDir $classesJar
if ($LASTEXITCODE -ne 0) {
    throw "d8 failed"
}

$unsignedApk = Join-Path $buildDir "BinderLab-unsigned.apk"
& $aapt2 link `
    -o $unsignedApk `
    -I $androidJar `
    --manifest (Join-Path $projectRoot "AndroidManifest.xml") `
    --min-sdk-version $minSdk `
    --target-sdk-version $targetSdk
if ($LASTEXITCODE -ne 0) {
    throw "aapt2 link failed"
}

& $jar uf $unsignedApk -C $dexDir classes.dex
if ($LASTEXITCODE -ne 0) {
    throw "adding classes.dex failed"
}

$alignedApk = Join-Path $buildDir "BinderLab-aligned.apk"
& $zipalign -f 4 $unsignedApk $alignedApk
if ($LASTEXITCODE -ne 0) {
    throw "zipalign failed"
}

$signedApk = Join-Path $buildDir "BinderLab-debug.apk"
& $apksigner sign `
    --ks $keystore `
    --ks-key-alias androiddebugkey `
    --ks-pass pass:android `
    --key-pass pass:android `
    --out $signedApk `
    $alignedApk
if ($LASTEXITCODE -ne 0) {
    throw "apksigner failed"
}

& $apksigner verify --verbose $signedApk
if ($LASTEXITCODE -ne 0) {
    throw "APK signature verification failed"
}

$badgingPath = Join-Path $buildDir "apk-badging.txt"
& $aapt2 dump badging $signedApk 2>&1 |
    Set-Content -LiteralPath $badgingPath -Encoding UTF8
if ($LASTEXITCODE -ne 0) {
    throw "aapt2 dump badging failed"
}

$toolchainPath = Join-Path $buildDir "toolchain.txt"
$platformProperties = Join-Path $platformDir "source.properties"
$platformRevision = (Get-Content -LiteralPath $platformProperties -Encoding UTF8 |
    Where-Object { $_ -match '^Pkg\.Revision=' } |
    Select-Object -First 1) -replace '^Pkg\.Revision=', ''
$platformApiLevel = (Get-Content -LiteralPath $platformProperties -Encoding UTF8 |
    Where-Object { $_ -match '^AndroidVersion\.ApiLevel=' } |
    Select-Object -First 1) -replace '^AndroidVersion\.ApiLevel=', ''
$buildToolsProperties = Join-Path $toolsDir "source.properties"
$buildToolsRevision = Get-Content -LiteralPath $buildToolsProperties -Encoding UTF8 |
    Where-Object { $_ -match '^Pkg\.Revision=' } |
    Select-Object -First 1
$aidlBanner = (& cmd.exe /d /s /c "`"$aidl`" --help 2>&1" |
    Select-String -Pattern 'AIDL Compiler: built for platform SDK version' |
    Select-Object -First 1).Line
$aapt2Version = (& cmd.exe /d /s /c "`"$aapt2`" version 2>&1" |
    Select-Object -First 1)
$d8Version = (& cmd.exe /d /s /c "`"$d8`" --version 2>&1" |
    Select-Object -First 1)
$javacVersion = (& cmd.exe /d /s /c "`"$javac`" -version 2>&1" |
    Select-Object -First 1)
@(
    "sdkPlatform=android-$CompileSdkPlatform"
    "sdkPlatformRevision=$platformRevision"
    "sdkApiLevel=$platformApiLevel"
    "compileSdk=$CompileSdkPlatform"
    "targetSdk=$targetSdk"
    "minSdk=$minSdk"
    "buildTools=$BuildToolsVersion"
    $buildToolsRevision
    $aidlBanner
    $aapt2Version
    $d8Version
    $javacVersion
) | Set-Content -LiteralPath $toolchainPath -Encoding UTF8

Get-Item -LiteralPath $signedApk | Select-Object FullName, Length, LastWriteTime
$global:LASTEXITCODE = 0
