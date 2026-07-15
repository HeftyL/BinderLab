param(
    [switch]$SkipBuild,
    [string]$SdkRoot = $(if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { "D:\Android" }),
    [string]$CompileSdkPlatform = "36.1",
    [string]$BuildToolsVersion = "36.0.0",
    [string]$DiffBase
)

$ErrorActionPreference = "Stop"

$projectRoot = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$gitRoot = (& git -C $projectRoot rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitRoot)) {
    throw "Could not resolve the Git repository root"
}
$gitRoot = [System.IO.Path]::GetFullPath($gitRoot).TrimEnd('\')
if ($gitRoot -ne $projectRoot) {
    throw "BinderLab must be its own Git worktree (standalone clone or initialized submodule): $projectRoot"
}
$generatedRoot = Join-Path $projectRoot "build\generated\com\example\binderdemo"
$referenceRoot = Join-Path $projectRoot "generated-reference"
$evidenceRoot = Join-Path $projectRoot "evidence"
$toolsDir = Join-Path $SdkRoot "build-tools\$BuildToolsVersion"
$aapt2 = Join-Path $toolsDir "aapt2.exe"
$apksigner = Join-Path $toolsDir "apksigner.bat"
$apk = Join-Path $projectRoot "build\BinderLab-debug.apk"

function Invoke-NativeCapture {
    param(
        [string]$Executable,
        [string[]]$Arguments
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $Executable @Arguments 2>&1 |
            ForEach-Object { $_.ToString() }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        throw "$Executable $($Arguments -join ' ') failed:`n$($output -join "`n")"
    }
    return @($output)
}

function Read-TransactionMap {
    param(
        [string]$Path,
        [string]$Pattern
    )

    $map = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match $Pattern) {
            $map[$Matches.name] = [int]$Matches.offset
        }
    }
    return $map
}

function Assert-MapEqual {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Description
    )

    $actualKeys = @($Actual.Keys |
        ForEach-Object { [string]$_ } |
        Sort-Object)
    $expectedKeys = @($Expected.Keys |
        ForEach-Object { [string]$_ } |
        Sort-Object)
    if (($actualKeys -join "`n") -cne ($expectedKeys -join "`n")) {
        throw "$Description keys drifted. Expected:`n$($expectedKeys -join "`n")`nActual:`n$($actualKeys -join "`n")"
    }
    foreach ($key in $expectedKeys) {
        if ($Actual[$key] -cne $Expected[$key]) {
            throw "$Description value drifted for '$key'. Expected '$($Expected[$key])', actual '$($Actual[$key])'"
        }
    }
}

function Assert-Regex {
    param(
        [string]$Content,
        [string]$Pattern,
        [string]$Description
    )

    if (-not [regex]::IsMatch($Content, $Pattern)) {
        throw "Missing generated protocol shape: $Description"
    }
}

function Read-KeyValueFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing key/value metadata file: $Path"
    }
    $result = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            continue
        }
        if ($line -notmatch '^(?<key>[A-Za-z][A-Za-z0-9]*)=(?<value>.*)$') {
            throw "Malformed key/value metadata line in ${Path}: $line"
        }
        $result[$Matches.key] = $Matches.value
    }
    return $result
}

function Get-JsonPlainStringProperty {
    param(
        [string]$Json,
        [string]$PropertyName,
        [string]$Description
    )

    $pattern = '(?m)^\s*"' + [regex]::Escape($PropertyName) +
        '"\s*:\s*"(?<value>[^"\\]*)"\s*,?\s*$'
    $matches = [regex]::Matches($Json, $pattern)
    if ($matches.Count -ne 1) {
        throw "$Description must be exactly one unescaped JSON string property"
    }
    return $matches[0].Groups["value"].Value
}

function ConvertFrom-IsoTimestamp {
    param(
        [string]$Text,
        [string]$Description
    )

    try {
        return [DateTimeOffset]::ParseExact(
            $Text,
            "o",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None)
    } catch {
        throw "$Description is not a round-trip ISO-8601 timestamp: $Text"
    }
}

$sourceManifestAtVerifyStart = @(& (Join-Path $projectRoot "source-manifest.ps1") `
    -ProjectRoot $projectRoot)
if ($sourceManifestAtVerifyStart.Count -eq 0) {
    throw "BinderLab source manifest is empty"
}
foreach ($entry in $sourceManifestAtVerifyStart) {
    $path = $entry.Path
    $attributeOutput = (& git -C $gitRoot check-attr eol -- $path).Trim()
    if ($LASTEXITCODE -ne 0 -or $attributeOutput -ne "$path`: eol: lf") {
        throw "Every source-manifest text input requires eol=lf from .gitattributes: $attributeOutput"
    }
}

if (-not $SkipBuild) {
    & (Join-Path $projectRoot "build.ps1") `
        -SdkRoot $SdkRoot `
        -CompileSdkPlatform $CompileSdkPlatform `
        -BuildToolsVersion $BuildToolsVersion
    if ($LASTEXITCODE -ne 0) {
        throw "BinderLab build failed"
    }
}

foreach ($required in @($aapt2, $apksigner, $apk)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing verification dependency: $required"
    }
}

$generatedFiles = [ordered]@{
    IAsyncWorker = Join-Path $generatedRoot "IAsyncWorker.java"
    ICalculator = Join-Path $generatedRoot "ICalculator.java"
    IResultCallback = Join-Path $generatedRoot "IResultCallback.java"
    ISyncResultCallback = Join-Path $generatedRoot "ISyncResultCallback.java"
}
foreach ($path in $generatedFiles.Values) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing generated AIDL file: $path"
    }
}

$generatedPattern = 'TRANSACTION_(?<name>[A-Za-z0-9_]+)\s*=\s*\(android\.os\.IBinder\.FIRST_CALL_TRANSACTION\s*\+\s*(?<offset>\d+)\)'
$calculatorMap = Read-TransactionMap -Path $generatedFiles.ICalculator -Pattern $generatedPattern
if ($calculatorMap.Count -eq 0) {
    throw "Could not parse generated ICalculator transaction constants"
}

$expectedMaps = [ordered]@{
    IAsyncWorker = [ordered]@{ work = 0 }
    IResultCallback = [ordered]@{ onResult = 0 }
    ISyncResultCallback = [ordered]@{ onResult = 0 }
}
foreach ($name in $expectedMaps.Keys) {
    $actual = Read-TransactionMap -Path $generatedFiles[$name] -Pattern $generatedPattern
    Assert-MapEqual `
        -Actual $actual `
        -Expected $expectedMaps[$name] `
        -Description "$name transaction constants"
}

$calculatorContent = Get-Content -LiteralPath $generatedFiles.ICalculator -Raw -Encoding UTF8
$workerContent = Get-Content -LiteralPath $generatedFiles.IAsyncWorker -Raw -Encoding UTF8
$resultContent = Get-Content -LiteralPath $generatedFiles.IResultCallback -Raw -Encoding UTF8
$syncContent = Get-Content -LiteralPath $generatedFiles.ISyncResultCallback -Raw -Encoding UTF8

Assert-Regex $calculatorContent 'TRANSACTION_notifyValue,\s*_data,\s*null,\s*android\.os\.IBinder\.FLAG_ONEWAY' "ICalculator.notifyValue oneway null reply"
Assert-Regex $calculatorContent 'TRANSACTION_notifyValueViaHandler,\s*_data,\s*null,\s*android\.os\.IBinder\.FLAG_ONEWAY' "ICalculator.notifyValueViaHandler oneway null reply"
Assert-Regex $workerContent 'TRANSACTION_work,\s*_data,\s*null,\s*android\.os\.IBinder\.FLAG_ONEWAY' "IAsyncWorker.work oneway null reply"
Assert-Regex $resultContent 'TRANSACTION_onResult,\s*_data,\s*null,\s*android\.os\.IBinder\.FLAG_ONEWAY' "IResultCallback.onResult oneway null reply"
Assert-Regex $syncContent 'TRANSACTION_onResult,\s*_data,\s*_reply,\s*0\)' "ISyncResultCallback synchronous reply"
Assert-Regex $calculatorContent '_data\.writeStrongInterface\(callback\)' "callback Binder argument write"
Assert-Regex $calculatorContent 'IResultCallback\.Stub\.asInterface\(data\.readStrongBinder\(\)\)' "async callback Binder argument read"
Assert-Regex $calculatorContent 'ISyncResultCallback\.Stub\.asInterface\(data\.readStrongBinder\(\)\)' "sync callback Binder argument read"
Assert-Regex $calculatorContent 'IAsyncWorker\.Stub\.asInterface\(_reply\.readStrongBinder\(\)\)' "returned Binder reference"
Assert-Regex $calculatorContent 'TRANSACTION_addWithRequestId' "request-correlated Handler experiment method"
Assert-Regex $calculatorContent '_data\.writeInt\(\(\(injectHandlerBlocker\)\?\(1\):\(0\)\)\)' "Handler experiment blocker flag write"
Assert-Regex $calculatorContent '_arg3 = \(0!=data\.readInt\(\)\)' "Handler experiment blocker flag read"
if ($calculatorContent -match 'enforceNoDataAvail') {
    throw "Build Tools 36.0.0 output unexpectedly contains enforceNoDataAvail; review the generated reference before accepting toolchain drift"
}

$hashManifest = Join-Path $referenceRoot "aidl-generated.sha256"
$hashEntries = [ordered]@{}
foreach ($line in Get-Content -LiteralPath $hashManifest -Encoding UTF8) {
    if ($line -match '^(?<hash>[0-9a-fA-F]{64})\s+(?<name>\S+\.java)$') {
        $hashEntries[$Matches.name] = $Matches.hash.ToLowerInvariant()
    }
}
if ($hashEntries.Count -ne 4) {
    throw "Expected four hashes in generated-reference/aidl-generated.sha256"
}
foreach ($path in $generatedFiles.Values) {
    $name = Split-Path -Leaf $path
    if (-not $hashEntries.Contains($name)) {
        throw "Missing generated reference hash for $name"
    }
    $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $hashEntries[$name]) {
        throw "Generated AIDL hash drift for $name"
    }
}

$referenceToolchain = Get-Content -LiteralPath (Join-Path $referenceRoot "toolchain.txt") -Raw -Encoding UTF8
foreach ($requiredText in @(
    "sdkPlatform=android-36.1",
    "sdkPlatformRevision=1",
    "sdkApiLevel=36.1",
    "compileSdk=36.1",
    "targetSdk=36",
    "minSdk=26",
    "buildTools=36.0.0",
    "aidlPackage=36.0.0",
    "built for platform SDK version 36"
)) {
    if ($referenceToolchain -notmatch [regex]::Escape($requiredText)) {
        throw "Generated-reference toolchain is missing: $requiredText"
    }
}

$requiredToolchainText = @(
    "sdkPlatform=android-36.1",
    "sdkPlatformRevision=1",
    "sdkApiLevel=36.1",
    "compileSdk=36.1",
    "targetSdk=36",
    "minSdk=26",
    "buildTools=36.0.0",
    "built for platform SDK version 36"
)
foreach ($toolchainPath in @(
        (Join-Path $projectRoot "build\toolchain.txt"),
        (Join-Path $evidenceRoot "toolchain.txt")
    )) {
    $toolchainContent = Get-Content -LiteralPath $toolchainPath -Raw -Encoding UTF8
    foreach ($requiredText in $requiredToolchainText) {
        if ($toolchainContent -notmatch [regex]::Escape($requiredText)) {
            throw "$toolchainPath is missing: $requiredText"
        }
    }
}

$badging = (Invoke-NativeCapture -Executable $aapt2 -Arguments @(
    "dump", "badging", $apk
)) -join "`n"
foreach ($metadataPattern in @(
    "compileSdkVersion='36'",
    "sdkVersion:'26'",
    "targetSdkVersion:'36'",
    "application-debuggable"
)) {
    if ($badging -notmatch [regex]::Escape($metadataPattern)) {
        throw "APK metadata check failed: $metadataPattern"
    }
}
[void](Invoke-NativeCapture -Executable $apksigner -Arguments @(
    "verify", "--verbose", $apk
))

$freshAnalysisPath = Join-Path $projectRoot "build\analysis.verify.json"
$freshKeyEvidencePath = Join-Path $projectRoot "build\key-evidence.verify.md"
$analysisSourceInfo = Read-KeyValueFile -Path (Join-Path $evidenceRoot "source.txt")
foreach ($captureKey in @("captureId", "captureStartedAt")) {
    if (-not $analysisSourceInfo.Contains($captureKey) -or
            [string]::IsNullOrWhiteSpace($analysisSourceInfo[$captureKey])) {
        throw "Evidence source metadata is missing $captureKey"
    }
}
& (Join-Path $projectRoot "analyze-evidence.ps1") `
    -EvidenceDir $evidenceRoot `
    -OutputPath $freshAnalysisPath `
    -KeyEvidencePath $freshKeyEvidencePath `
    -CaptureId $analysisSourceInfo.captureId `
    -CaptureStartedAt $analysisSourceInfo.captureStartedAt | Out-Null
$committedAnalysisJson = Get-Content `
    -LiteralPath (Join-Path $evidenceRoot "analysis.json") `
    -Raw `
    -Encoding UTF8
$freshAnalysisJson = Get-Content `
    -LiteralPath $freshAnalysisPath `
    -Raw `
    -Encoding UTF8
$committedAnalysisCaptureId = Get-JsonPlainStringProperty `
    -Json $committedAnalysisJson `
    -PropertyName "captureId" `
    -Description "analysis.captureId"
$committedAnalysisCaptureStartedAt = Get-JsonPlainStringProperty `
    -Json $committedAnalysisJson `
    -PropertyName "captureStartedAt" `
    -Description "analysis.captureStartedAt"
$committedAnalysisGeneratedAt = Get-JsonPlainStringProperty `
    -Json $committedAnalysisJson `
    -PropertyName "generatedAt" `
    -Description "analysis.generatedAt"
$committedAnalysis = $committedAnalysisJson | ConvertFrom-Json
$freshAnalysis = $freshAnalysisJson | ConvertFrom-Json
$freshAnalysis.generatedAt = $committedAnalysis.generatedAt
$committedJson = $committedAnalysis | ConvertTo-Json -Depth 12 -Compress
$freshJson = $freshAnalysis | ConvertTo-Json -Depth 12 -Compress
if ($committedJson -ne $freshJson) {
    throw "Committed evidence/analysis.json drifted from raw logs"
}
$committedKeyEvidencePath = Join-Path $evidenceRoot "key-evidence.md"
$committedKeyEvidence = [System.IO.File]::ReadAllText($committedKeyEvidencePath)
$freshKeyEvidence = [System.IO.File]::ReadAllText($freshKeyEvidencePath)
if ($committedKeyEvidence -cne $freshKeyEvidence) {
    throw "Committed evidence/key-evidence.md drifted from raw logs"
}
if (-not $committedAnalysis.allRequiredChecksPassed) {
    throw "Evidence analysis reports a failed required check"
}
if ($committedAnalysis.handlerLatencyBaseline.runCount -ne 5 -or
        $committedAnalysis.handlerLatencyBlocked.runCount -ne 5) {
    throw "Expected exactly five baseline and five blocked Handler evidence runs"
}

$evidenceNarrativeDocuments = [ordered]@{
    (Join-Path $projectRoot "README.md") = @(
        "evidence/key-evidence.md#binder-key-handler",
        "evidence/analysis.json",
        "blocked.queueNsMin - baseline.queueNsMax ~= injectedBlockerNs"
    )
    (Join-Path $evidenceRoot "README.md") = @(
        "key-evidence.md#binder-key-handler",
        "analysis.json",
        "blocked.queueNsMin - baseline.queueNsMax ~= injectedBlockerNs"
    )
}
foreach ($path in $evidenceNarrativeDocuments.Keys) {
    $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    foreach ($expectedText in $evidenceNarrativeDocuments[$path]) {
        if (-not $content.Contains($expectedText)) {
            throw "Stable evidence narrative drift in ${path}: missing '$expectedText'"
        }
    }
    $captureSpecificNumberPattern = '(?i)(?:\d+(?:\.\d+)?\s*[~\uFF5E]\s*\d+(?:\.\d+)?\s*(?:ns|ms|s)\b|\b\d{1,3}(?:,\d{3})+\s*ns\b|\b\d{7,}\s*ns\b|\b\d+\.\d{3,}\s*(?:ms|s)\b)'
    if ($content -match $captureSpecificNumberPattern) {
        throw "Narrative document contains capture-specific timing '$($Matches[0])': $path"
    }
}

$expectedEvidenceFiles = @(
    "analysis.json",
    "apk-badging.txt",
    "apk-signature.txt",
    "async-callback.log",
    "binder-death.log",
    "commands.txt",
    "device.txt",
    "evidence-manifest.sha256",
    "handler-latency-baseline-run-01.log",
    "handler-latency-baseline-run-02.log",
    "handler-latency-baseline-run-03.log",
    "handler-latency-baseline-run-04.log",
    "handler-latency-baseline-run-05.log",
    "handler-latency-blocked-run-01.log",
    "handler-latency-blocked-run-02.log",
    "handler-latency-blocked-run-03.log",
    "handler-latency-blocked-run-04.log",
    "handler-latency-blocked-run-05.log",
    "key-evidence.md",
    "oneway-cross-node.log",
    "oneway-same-node.log",
    "README.md",
    "service-manager.txt",
    "source-manifest.sha256",
    "source.txt",
    "sync-reentry.log",
    "toolchain.txt"
) | Sort-Object
$actualEvidenceFiles = @(Get-ChildItem -LiteralPath $evidenceRoot -File |
    ForEach-Object { $_.Name } |
    Sort-Object)
if (($expectedEvidenceFiles -join "`n") -ne ($actualEvidenceFiles -join "`n")) {
    throw "Evidence file set drifted. Expected:`n$($expectedEvidenceFiles -join "`n")`nActual:`n$($actualEvidenceFiles -join "`n")"
}

$evidenceManifestPath = Join-Path $evidenceRoot "evidence-manifest.sha256"
$recordedEvidenceEntries = [ordered]@{}
foreach ($line in Get-Content -LiteralPath $evidenceManifestPath -Encoding UTF8) {
    if ($line -notmatch '^(?<hash>[0-9a-f]{64})  (?<name>[^\\/]+)$') {
        throw "Malformed evidence-manifest entry: $line"
    }
    if ($Matches.name -eq "evidence-manifest.sha256") {
        throw "evidence-manifest.sha256 must not hash itself"
    }
    if ($recordedEvidenceEntries.Contains($Matches.name)) {
        throw "Duplicate evidence-manifest entry: $($Matches.name)"
    }
    $recordedEvidenceEntries[$Matches.name] = $Matches.hash
}
$manifestExpectedNames = @($actualEvidenceFiles |
    Where-Object { $_ -ne "evidence-manifest.sha256" } |
    Sort-Object)
$recordedEvidenceNames = @($recordedEvidenceEntries.Keys |
    ForEach-Object { [string]$_ } |
    Sort-Object)
if (($recordedEvidenceNames -join "`n") -cne ($manifestExpectedNames -join "`n")) {
    throw "evidence-manifest.sha256 file set drifted. Expected:`n$($manifestExpectedNames -join "`n")`nRecorded:`n$($recordedEvidenceNames -join "`n")"
}
foreach ($name in $manifestExpectedNames) {
    $actualHash = (Get-FileHash `
        -LiteralPath (Join-Path $evidenceRoot $name) `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($recordedEvidenceEntries[$name] -cne $actualHash) {
        throw "Evidence file hash mismatch for $name"
    }
}

$sourceInfo = $analysisSourceInfo
foreach ($requiredKey in @(
    "captureId",
    "captureStartedAt",
    "captureCompletedAt",
    "gitCommit",
    "gitBranch",
    "gitDirty",
    "gitDirtyScope",
    "sourceManifestSha256",
    "apkSha256"
)) {
    if (-not $sourceInfo.Contains($requiredKey) -or
            [string]::IsNullOrWhiteSpace($sourceInfo[$requiredKey])) {
        throw "Evidence source metadata is missing $requiredKey"
    }
}
if ($sourceInfo.gitDirty -ne "false") {
    throw "Published evidence must come from a clean Git working tree (gitDirty=false)"
}
if ($sourceInfo.gitCommit -notmatch '^[0-9a-f]{40}$') {
    throw "Evidence gitCommit is not a full SHA-1 commit id"
}
& git -C $gitRoot cat-file -e "$($sourceInfo.gitCommit)^{commit}"
if ($LASTEXITCODE -ne 0) {
    throw "Evidence gitCommit is not present in this repository"
}

$sourceManifestPath = Join-Path $evidenceRoot "source-manifest.sha256"
$sourceManifestHash = (Get-FileHash `
    -LiteralPath $sourceManifestPath `
    -Algorithm SHA256).Hash.ToLowerInvariant()
if ($sourceManifestHash -ne $sourceInfo.sourceManifestSha256) {
    throw "Evidence source-manifest.sha256 does not match source.txt"
}
$recordedSourceEntries = [ordered]@{}
foreach ($line in Get-Content -LiteralPath $sourceManifestPath -Encoding UTF8) {
    if ($line -notmatch '^(?<hash>[0-9a-f]{64})  (?<path>.+)$') {
        throw "Malformed source-manifest entry: $line"
    }
    if ($recordedSourceEntries.Contains($Matches.path)) {
        throw "Duplicate source-manifest entry: $($Matches.path)"
    }
    $recordedSourceEntries[$Matches.path] = $Matches.hash
}
$currentSourceEntries = [ordered]@{}
foreach ($entry in & (Join-Path $projectRoot "source-manifest.ps1") `
        -ProjectRoot $projectRoot) {
    $currentSourceEntries[$entry.Path] = $entry.Hash
}
Assert-MapEqual `
    -Actual $currentSourceEntries `
    -Expected $recordedSourceEntries `
    -Description "Evidence source manifest"
$sourcePathsAtRecordedCommit = @($recordedSourceEntries.Keys |
    ForEach-Object { [string]$_ })
& git -C $gitRoot diff --quiet $sourceInfo.gitCommit -- @sourcePathsAtRecordedCommit
if ($LASTEXITCODE -ne 0) {
    throw "Evidence source inputs differ from the recorded clean commit $($sourceInfo.gitCommit)"
}

$evidenceBadging = Get-Content `
    -LiteralPath (Join-Path $evidenceRoot "apk-badging.txt") `
    -Raw `
    -Encoding UTF8
if ($evidenceBadging -notmatch '(?m)^apkSha256=(?<hash>[0-9a-f]{64})$') {
    throw "Evidence apk-badging.txt has no APK SHA-256"
}
if ($Matches.hash -ne $sourceInfo.apkSha256) {
    throw "Evidence APK SHA-256 differs between source.txt and apk-badging.txt"
}

$deviceInfo = Read-KeyValueFile -Path (Join-Path $evidenceRoot "device.txt")
foreach ($requiredDeviceKey in @("captureId", "hostCapturedAt")) {
    if (-not $deviceInfo.Contains($requiredDeviceKey) -or
            [string]::IsNullOrWhiteSpace($deviceInfo[$requiredDeviceKey])) {
        throw "Evidence device metadata is missing $requiredDeviceKey"
    }
}
if ($sourceInfo.captureId -cne $deviceInfo.captureId) {
    throw "source.captureId must equal device.captureId"
}
if ($sourceInfo.captureStartedAt -cne $deviceInfo.hostCapturedAt) {
    throw "source.captureStartedAt must equal device.hostCapturedAt"
}
if ($committedAnalysisCaptureId -cne $sourceInfo.captureId) {
    throw "analysis.captureId must equal source.captureId"
}
if ($committedAnalysisCaptureStartedAt -cne $sourceInfo.captureStartedAt) {
    throw "analysis.captureStartedAt must equal source.captureStartedAt"
}
$captureStartedAt = ConvertFrom-IsoTimestamp `
    -Text $sourceInfo.captureStartedAt `
    -Description "source.captureStartedAt"
$analysisGeneratedAt = ConvertFrom-IsoTimestamp `
    -Text $committedAnalysisGeneratedAt `
    -Description "analysis.generatedAt"
$captureCompletedAt = ConvertFrom-IsoTimestamp `
    -Text $sourceInfo.captureCompletedAt `
    -Description "source.captureCompletedAt"
if (-not ($captureStartedAt -lt $analysisGeneratedAt -and
        $analysisGeneratedAt -lt $captureCompletedAt)) {
    throw "Capture timestamps must satisfy captureStartedAt < analysis.generatedAt < captureCompletedAt"
}
$requiredDevicePairs = [ordered]@{
    AndroidVersion = "16"
    ApiLevel = "36"
    Model = "redacted"
    Fingerprint = "redacted"
    Carrier = "redacted"
    serialHash = "not-recorded"
}
foreach ($key in $requiredDevicePairs.Keys) {
    if (-not $deviceInfo.Contains($key) -or
            $deviceInfo[$key] -ne $requiredDevicePairs[$key]) {
        throw "Public device metadata must contain $key=$($requiredDevicePairs[$key])"
    }
}
if (-not $deviceInfo.Contains("KernelVersion") -or
        $deviceInfo.KernelVersion -notmatch '^\d+\.\d+$') {
    throw "Public KernelVersion must be reduced to major.minor"
}
$evidenceTextFiles = Get-ChildItem -LiteralPath $evidenceRoot -File
$sensitivePatterns = @(
    '(?m)^Model=(?!redacted$).+',
    '(?m)^Fingerprint=(?!redacted$).+',
    '(?m)^Carrier=(?!redacted$).+',
    '(?m)^serialHash=(?!not-recorded$).+',
    '(?m)^KernelVersion=(?!\d+\.\d+$).+',
    '(?m)^ro\.product\.model=',
    '(?m)^ro\.build\.fingerprint=',
    '(?im)^(?:gsm\.operator|ro\.(?:carrier|boot\.carrier))[^=]*=',
    '(?i)\bLinux version\b',
    '(?i)\b\d+\.\d+\.\d+-android\S*',
    '(?m)^kernel=Linux',
    '(?m)^deviceSerial='
)
foreach ($pattern in $sensitivePatterns) {
    $hits = Select-String `
        -Path $evidenceTextFiles.FullName `
        -Pattern $pattern `
        -Encoding UTF8
    if ($hits) {
        throw "Public evidence contains sensitive device metadata matching '$pattern':`n$($hits -join "`n")"
    }
}

$workflowPath = Join-Path $gitRoot ".github\workflows\binderlab-verify.yml"
if (-not (Test-Path -LiteralPath $workflowPath -PathType Leaf)) {
    throw "Standalone BinderLab workflow is not located at the repository root"
}
$workflowContent = Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8
foreach ($requiredWorkflowText in @(
    'build/BinderLab-debug.apk',
    'platforms;android-36.1',
    'CompileSdkPlatform = "36.1"',
    'github.event.before',
    '$verifyArgs.DiffBase = "${{ github.event.before }}"'
)) {
    if ($workflowContent -notmatch [regex]::Escape($requiredWorkflowText)) {
        throw "Repository-root workflow is missing: $requiredWorkflowText"
    }
}

$markdownFiles = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File -Filter "*.md" |
    Where-Object { $_.FullName -notlike "*\build\*" })
$markdownFiles = @($markdownFiles | Sort-Object FullName -Unique)
$brokenLinks = New-Object System.Collections.Generic.List[string]
$unbalancedFences = New-Object System.Collections.Generic.List[string]
$publicBoundaryViolations = New-Object System.Collections.Generic.List[string]
$outboundLinks = New-Object System.Collections.Generic.List[string]
$allowedExternalHosts = @(
    "android.googlesource.com",
    "developer.android.com",
    "source.android.com"
)
$publicRepositoryPath = "/HeftyL/BinderLab"
$linkPattern = '!?\[[^\]]*\]\((?<target><[^>]+>|[^)\s]+)\)'
foreach ($file in $markdownFiles) {
    $lines = Get-Content -LiteralPath $file.FullName -Encoding UTF8
    $fenceCount = @($lines | Where-Object { $_ -match '^\s*```' }).Count
    if (($fenceCount % 2) -ne 0) {
        $unbalancedFences.Add($file.FullName)
    }

    $content = $lines -join "`n"
    foreach ($match in [regex]::Matches($content, $linkPattern)) {
        $target = $match.Groups['target'].Value.Trim('<', '>')
        if ($target -match '^https?:') {
            try {
                $uri = [Uri]$target
            } catch {
                $publicBoundaryViolations.Add("$($file.Name) -> invalid external URL $target")
                continue
            }
            $allowed = $uri.Scheme -eq "https" -and (
                $allowedExternalHosts -contains $uri.Host -or
                ($uri.Host -eq "github.com" -and (
                    $uri.AbsolutePath.TrimEnd('/') -eq $publicRepositoryPath -or
                    $uri.AbsolutePath.StartsWith(
                        "$publicRepositoryPath/",
                        [System.StringComparison]::OrdinalIgnoreCase))))
            if (-not $allowed) {
                $publicBoundaryViolations.Add("$($file.Name) -> disallowed external URL $target")
            }
            $outboundLinks.Add("$($file.Name) -> $target")
            continue
        }
        if ($target -match '^mailto:') {
            $publicBoundaryViolations.Add("$($file.Name) -> disallowed external URL $target")
            continue
        }
        $parts = $target -split '#', 2
        $pathPart = $parts[0]
        $anchor = if ($parts.Count -gt 1) { $parts[1] } else { $null }
        if ([string]::IsNullOrWhiteSpace($pathPart)) {
            $resolved = $file.FullName
        } else {
            $resolved = Join-Path $file.DirectoryName $pathPart
        }
        if (-not (Test-Path -LiteralPath $resolved)) {
            $brokenLinks.Add("$($file.Name) -> $target")
            continue
        }
        if ($anchor -like 'binder-*' -and (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            $targetContent = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8
            if ($targetContent -notmatch ('id=["'']' + [regex]::Escape($anchor) + '["'']')) {
                $brokenLinks.Add("$($file.Name) -> missing explicit anchor $target")
            }
        }
    }
}
if ($publicBoundaryViolations.Count -gt 0) {
    throw "Public repository boundary violations:`n$($publicBoundaryViolations -join "`n")"
}
if ($brokenLinks.Count -gt 0) {
    throw "Broken Markdown links:`n$($brokenLinks -join "`n")"
}
if ($unbalancedFences.Count -gt 0) {
    throw "Unbalanced code fences:`n$($unbalancedFences -join "`n")"
}

$staleScanFiles = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File -Include "*.md", "*.ps1", "*.java", "*.aidl", "*.xml" |
    Where-Object {
        $_.FullName -notlike "*\build\*" -and $_.FullName -ne $PSCommandPath
    })
$forbidden = @(
    "35.0.0",
    "Build Tools 35",
    "AidlBuildToolsVersion",
    "Build Tools 33",
    "Android platform 33",
    "-CompileApi 36",
    '"platforms;android-36"',
    "notifyValue(int value)",
    "notifyValueViaHandler(int value)",
    "addAndCallback(int a, int b",
    "onResult(int value)",
    "PublishedAtomically",
    "segmentClosure",
    "segmentSumMatchesTotal",
    ((-join @([char]0x516D, [char]0x4E2A, [char]0x72EC, [char]0x7ACB)) + " requestId mode"),
    ("TID" + (-join @([char]0x53EF, [char]0x4EE5))),
    "totalNs="
)
foreach ($text in $forbidden) {
    $hits = Select-String `
        -Path ($staleScanFiles.FullName) `
        -SimpleMatch `
        -Pattern $text `
        -Encoding UTF8
    if ($hits) {
        throw "Stale Binder-series text '$text':`n$($hits -join "`n")"
    }
}
$forbiddenPatterns = @(
    '(?m)^sdkPlatform=android-36$',
    'Android SDK Platform 36(?!\.1)',
    'Platform 36 \+'
)
foreach ($pattern in $forbiddenPatterns) {
    $hits = Select-String `
        -Path ($staleScanFiles.FullName) `
        -Pattern $pattern `
        -Encoding UTF8
    if ($hits) {
        throw "Stale Binder-series pattern '$pattern':`n$($hits -join "`n")"
    }
}

& git -C $gitRoot diff --check
if ($LASTEXITCODE -ne 0) {
    throw "git diff --check failed for the BinderLab working tree"
}
& git -C $gitRoot diff --cached --check
if ($LASTEXITCODE -ne 0) {
    throw "git diff --cached --check failed for BinderLab"
}

$rangeChecked = "HEAD"
if (-not [string]::IsNullOrWhiteSpace($DiffBase)) {
    if ($DiffBase -match '^0{40}$') {
        & git -C $gitRoot diff-tree --check --root -r HEAD
        if ($LASTEXITCODE -ne 0) {
            throw "git diff-tree --check failed for an initial push"
        }
        $rangeChecked = "initial-push:HEAD"
    } else {
        & git -C $gitRoot cat-file -e "$DiffBase^{commit}"
        if ($LASTEXITCODE -ne 0) {
            throw "DiffBase is not an available commit: $DiffBase"
        }
        & git -C $gitRoot diff --check "$DiffBase..HEAD"
        if ($LASTEXITCODE -ne 0) {
            throw "git diff --check failed for $DiffBase..HEAD"
        }
        $rangeChecked = "$DiffBase..HEAD"
    }
} elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_BASE_REF)) {
    $candidate = "origin/$($env:GITHUB_BASE_REF)"
    $mergeBase = (& git -C $gitRoot merge-base HEAD $candidate 2>$null).Trim()
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($mergeBase)) {
        & git -C $gitRoot diff --check "$mergeBase..HEAD"
        if ($LASTEXITCODE -ne 0) {
            throw "git diff --check failed for PR range $mergeBase..HEAD"
        }
        $rangeChecked = "$mergeBase..HEAD"
    } else {
        throw "Could not resolve GitHub base ref $candidate"
    }
} else {
    & git -C $gitRoot diff-tree --check --root -r HEAD
    if ($LASTEXITCODE -ne 0) {
        throw "git diff-tree --check failed for HEAD"
    }
}

[pscustomobject]@{
    Build = if ($SkipBuild) { "skipped" } else { "passed" }
    SdkPlatform = $CompileSdkPlatform
    BuildTools = $BuildToolsVersion
    AidlsChecked = $generatedFiles.Count
    TransactionConstants = $calculatorMap.Count
    GeneratedHashes = $hashEntries.Count
    ApkMetadata = "passed"
    EvidenceAnalysis = "passed"
    EvidenceKeySummary = "passed"
    EvidenceNarrativeStability = "passed"
    EvidenceManifest = "passed"
    EvidenceSourceBinding = "clean-commit"
    EvidenceCaptureBinding = "passed"
    EvidencePrivacy = "passed"
    BinderLabLineEndings = "lf"
    WorkflowLocation = "standalone-root"
    PublicRepositoryBoundary = "passed"
    OutboundMarkdownLinks = $outboundLinks.Count
    HandlerRuns = $committedAnalysis.handlerLatencyBaseline.runCount `
        + $committedAnalysis.handlerLatencyBlocked.runCount
    MarkdownFiles = $markdownFiles.Count
    RelativeLinks = "passed"
    CodeFences = "passed"
    StaleText = "passed"
    GitRangeCheck = $rangeChecked
}
