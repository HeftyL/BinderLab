param(
    [string]$ProjectRoot = $PSScriptRoot
)

$ErrorActionPreference = "Stop"

$root = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$gitRootOutput = (& git -C $root rev-parse --show-toplevel 2>&1 |
    ForEach-Object { $_.ToString() })
if ($LASTEXITCODE -ne 0 -or $gitRootOutput.Count -eq 0) {
    throw "Could not resolve the Git repository root for $root"
}
$gitRoot = [System.IO.Path]::GetFullPath(
    ($gitRootOutput | Select-Object -Last 1).Trim()).TrimEnd('\')
$gitRootPrefix = $gitRoot + "\"
if ($root -ne $gitRoot -and -not $root.StartsWith(
        $gitRootPrefix,
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "BinderLab project root is outside the Git repository: $root"
}
$paths = New-Object System.Collections.Generic.List[string]
$paths.Add((Join-Path $gitRoot ".gitattributes"))

foreach ($relativePath in @(
    ".github/workflows/binderlab-release.yml",
    ".github/workflows/binderlab-verify.yml",
    "AndroidManifest.xml",
    "build.ps1",
    "run-experiment.ps1",
    "collect-evidence.ps1",
    "analyze-evidence.ps1",
    "key-evidence.template",
    "source-manifest.ps1",
    "tests/analyzer-async-partial-order.ps1",
    "verify.ps1",
    "write-verification-artifacts.ps1"
)) {
    $fullPath = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Missing source-manifest input: $fullPath"
    }
    $paths.Add([System.IO.Path]::GetFullPath($fullPath))
}

foreach ($directory in @("aidl", "src")) {
    $fullDirectory = Join-Path $root $directory
    if (-not (Test-Path -LiteralPath $fullDirectory -PathType Container)) {
        throw "Missing source-manifest directory: $fullDirectory"
    }
    Get-ChildItem -LiteralPath $fullDirectory -Recurse -File |
        ForEach-Object { $paths.Add($_.FullName) }
}

foreach ($fullPath in @($paths | Sort-Object -Unique)) {
    $normalizedPath = [System.IO.Path]::GetFullPath($fullPath)
    if ($normalizedPath -ne $gitRoot -and -not $normalizedPath.StartsWith(
            $gitRootPrefix,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Source-manifest input escaped repository root: $normalizedPath"
    }
    if (-not (Test-Path -LiteralPath $normalizedPath -PathType Leaf)) {
        throw "Missing source-manifest input: $normalizedPath"
    }
    $relativePath = $normalizedPath.Substring($gitRootPrefix.Length).Replace('\', '/')
    [pscustomobject]@{
        Hash = (Get-FileHash -LiteralPath $normalizedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Path = $relativePath
    }
}
