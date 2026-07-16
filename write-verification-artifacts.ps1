param(
    [string]$BuildDir,
    [Parameter(Mandatory = $true)]
    [string]$ProducerRepository,
    [Parameter(Mandatory = $true)]
    [string]$ProducerCommit,
    [string]$ParentRepository = "none",
    [string]$ParentCommit = "none",
    [Parameter(Mandatory = $true)]
    [string]$BinderLabTag,
    [Parameter(Mandatory = $true)]
    [string]$BinderLabCommit,
    [Parameter(Mandatory = $true)]
    [string]$EvidenceSourceCommit,
    [Parameter(Mandatory = $true)]
    [string]$WorkflowRunId,
    [Parameter(Mandatory = $true)]
    [string]$WorkflowRunAttempt,
    [string]$SdkPlatform = "android-36.1",
    [string]$BuildToolsVersion = "36.0.0"
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($BuildDir)) {
    $BuildDir = Join-Path $PSScriptRoot "build"
}
$buildPath = [System.IO.Path]::GetFullPath($BuildDir).TrimEnd('\')
if (-not (Test-Path -LiteralPath $buildPath -PathType Container)) {
    throw "Build directory does not exist: $buildPath"
}
foreach ($commit in @($ProducerCommit, $BinderLabCommit, $EvidenceSourceCommit)) {
    if ($commit -notmatch '^[0-9a-f]{40}$') {
        throw "Expected a full lowercase commit id, got: $commit"
    }
}
if ($ParentCommit -ne "none" -and $ParentCommit -notmatch '^[0-9a-f]{40}$') {
    throw "Expected parentCommit=none or a full lowercase commit id"
}
if ($BinderLabTag -notmatch '^(?:unreleased|android16-qpr2-evidence-v[0-9]+(?:\.[0-9]+)*)$') {
    throw "Unexpected BinderLab tag value: $BinderLabTag"
}

$generatedRelativePaths = @(
    "generated/com/example/binderdemo/IAsyncWorker.java",
    "generated/com/example/binderdemo/ICalculator.java",
    "generated/com/example/binderdemo/IResultCallback.java",
    "generated/com/example/binderdemo/ISyncResultCallback.java"
)
$requiredRelativePaths = @(
    "BinderLab-debug.apk",
    "apk-badging.txt",
    "toolchain.txt",
    "evidence-replay-report.json"
) + $generatedRelativePaths

$actualGeneratedPaths = @(Get-ChildItem `
        -LiteralPath (Join-Path $buildPath "generated") `
        -Recurse `
        -File `
        -Filter *.java |
    ForEach-Object {
        $_.FullName.Substring($buildPath.Length + 1).Replace('\', '/')
    } |
    Sort-Object)
if (($actualGeneratedPaths -join "`n") -cne (($generatedRelativePaths | Sort-Object) -join "`n")) {
    throw "Generated Java file set drifted. Expected:`n$($generatedRelativePaths -join "`n")`nActual:`n$($actualGeneratedPaths -join "`n")"
}
foreach ($relativePath in $requiredRelativePaths) {
    $path = Join-Path $buildPath ($relativePath.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required verification artifact is missing: $relativePath"
    }
    if ((Get-Item -LiteralPath $path).Length -le 0) {
        throw "Required verification artifact is empty: $relativePath"
    }
}

$replayReportJson = Get-Content `
    -LiteralPath (Join-Path $buildPath "evidence-replay-report.json") `
    -Raw `
    -Encoding UTF8
if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey("DateKind")) {
    $replayReport = ConvertFrom-Json `
        -InputObject $replayReportJson `
        -DateKind String
} else {
    $replayReport = $replayReportJson | ConvertFrom-Json
}
if ($replayReport.analysisMode -cne "replay" -or
        -not $replayReport.allRequiredChecksPassed -or
        $replayReport.originalAnalysisSha256 -notmatch '^[0-9a-f]{64}$') {
    throw "evidence-replay-report.json is not a successful provenance-bound replay"
}

$javacOutput = (& javac -version 2>&1 | ForEach-Object { $_.ToString() }) -join " "
if ($LASTEXITCODE -ne 0 -or $javacOutput -notmatch '^javac\s+21(?:\.|$)') {
    throw "Expected javac 21.x, got: $javacOutput"
}
$provenancePath = Join-Path $buildPath "verification-provenance.txt"
$provenanceLines = @(
    "artifactSchemaVersion=1",
    "producerRepository=$ProducerRepository",
    "producerCommit=$ProducerCommit",
    "parentRepository=$ParentRepository",
    "parentCommit=$ParentCommit",
    "binderLabRepository=HeftyL/BinderLab",
    "binderLabTag=$BinderLabTag",
    "binderLabCommit=$BinderLabCommit",
    "evidenceSourceCommit=$EvidenceSourceCommit",
    "workflowRunId=$WorkflowRunId",
    "workflowRunAttempt=$WorkflowRunAttempt",
    "sdkPlatform=$SdkPlatform",
    "buildTools=$BuildToolsVersion",
    "java=$javacOutput",
    "sourceAnalysisSha256=$($replayReport.originalAnalysisSha256)",
    "sourceAnalysisGeneratedAt=$($replayReport.sourceAnalysisGeneratedAt)",
    "replayedAt=$($replayReport.replayedAt)"
)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText(
    $provenancePath,
    ($provenanceLines -join "`n") + "`n",
    $utf8NoBom)

$manifestPath = Join-Path $buildPath "artifact-manifest.sha256"
$manifestRelativePaths = @($requiredRelativePaths + "verification-provenance.txt" | Sort-Object)
$manifestLines = foreach ($relativePath in $manifestRelativePaths) {
    $path = Join-Path $buildPath ($relativePath.Replace('/', '\'))
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $relativePath"
}
[System.IO.File]::WriteAllText(
    $manifestPath,
    ($manifestLines -join "`n") + "`n",
    $utf8NoBom)

[pscustomobject]@{
    RequiredArtifacts = $requiredRelativePaths.Count
    GeneratedJavaFiles = $generatedRelativePaths.Count
    Provenance = $provenancePath
    Manifest = $manifestPath
}
