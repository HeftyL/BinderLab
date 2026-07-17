param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
$projectPath = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
$evidencePath = Join-Path $projectPath "evidence"
$analyzerPath = Join-Path $projectPath "analyze-evidence.ps1"
$sourceAnalysisPath = Join-Path $evidencePath "analysis.json"
$sourceMetadataPath = Join-Path $evidencePath "source.txt"
$asyncSourcePath = Join-Path $evidencePath "async-callback.log"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

foreach ($requiredPath in @(
        $evidencePath,
        $analyzerPath,
        $sourceAnalysisPath,
        $sourceMetadataPath,
        $asyncSourcePath
    )) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Missing async partial-order test input: $requiredPath"
    }
}

$sourceMetadata = [ordered]@{}
foreach ($line in Get-Content -LiteralPath $sourceMetadataPath -Encoding UTF8) {
    if ($line -match '^(?<key>[A-Za-z][A-Za-z0-9]*)=(?<value>.*)$') {
        $sourceMetadata[$Matches.key] = $Matches.value
    }
}
foreach ($requiredKey in @("captureId", "captureStartedAt")) {
    if (-not $sourceMetadata.Contains($requiredKey)) {
        throw "Evidence source metadata is missing $requiredKey"
    }
}

$asyncMarkers = @(
    "C_ASYNC_CALL_BEGIN",
    "C_ASYNC_CALL_RETURN",
    "S_HANDLER_POST",
    "S_HANDLER_RUN",
    "C_CALLBACK",
    "C_ASYNC_CALLBACK_OBSERVED"
)
$sourceLines = @(Get-Content -LiteralPath $asyncSourcePath -Encoding UTF8)
$markerLines = [ordered]@{}
$markerIndices = New-Object System.Collections.Generic.List[int]
foreach ($marker in $asyncMarkers) {
    $indices = @(for ($i = 0; $i -lt $sourceLines.Count; $i++) {
            if ($sourceLines[$i] -match ("BinderLab:\s+" + [regex]::Escape($marker) + "\s")) {
                $i
            }
        })
    if ($indices.Count -ne 1) {
        throw "Expected exactly one $marker line in async-callback.log"
    }
    $markerLines[$marker] = $sourceLines[$indices[0]]
    $markerIndices.Add($indices[0])
}
$insertionIndex = ($markerIndices | Measure-Object -Minimum).Minimum
$markerIndexSet = @{}
foreach ($index in $markerIndices) {
    $markerIndexSet[$index] = $true
}
$nonMarkerLines = @(for ($i = 0; $i -lt $sourceLines.Count; $i++) {
        if (-not $markerIndexSet.ContainsKey($i)) {
            $sourceLines[$i]
        }
    })

function Write-AsyncSchedule {
    param(
        [string]$Path,
        [string[]]$Order
    )

    $actualMarkers = @($Order | Sort-Object) -join "`n"
    $expectedMarkers = @($asyncMarkers | Sort-Object) -join "`n"
    if ($actualMarkers -cne $expectedMarkers) {
        throw "Async schedule must contain every marker exactly once"
    }
    $result = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $insertionIndex; $i++) {
        $result.Add($nonMarkerLines[$i])
    }
    for ($position = 0; $position -lt $Order.Count; $position++) {
        $marker = $Order[$position]
        $lineWithoutAtNs = [regex]::Replace(
            $markerLines[$marker],
            '\s+atNs=\d+',
            '')
        $result.Add($lineWithoutAtNs + " atNs=" + (1000000 + $position))
    }
    for ($i = $insertionIndex; $i -lt $nonMarkerLines.Count; $i++) {
        $result.Add($nonMarkerLines[$i])
    }
    [System.IO.File]::WriteAllLines($Path, $result, $utf8NoBom)
}

$cases = @(
    [pscustomobject]@{
        Name = "observed-capture-order"
        Order = @("C_ASYNC_CALL_BEGIN", "C_ASYNC_CALL_RETURN", "S_HANDLER_POST", "S_HANDLER_RUN", "C_CALLBACK", "C_ASYNC_CALLBACK_OBSERVED")
        ExpectedFailureProperty = $null
    },
    [pscustomobject]@{
        Name = "server-post-before-client-return"
        Order = @("C_ASYNC_CALL_BEGIN", "S_HANDLER_POST", "C_ASYNC_CALL_RETURN", "S_HANDLER_RUN", "C_CALLBACK", "C_ASYNC_CALLBACK_OBSERVED")
        ExpectedFailureProperty = $null
    },
    [pscustomobject]@{
        Name = "callback-before-client-return"
        Order = @("C_ASYNC_CALL_BEGIN", "S_HANDLER_POST", "S_HANDLER_RUN", "C_CALLBACK", "C_ASYNC_CALL_RETURN", "C_ASYNC_CALLBACK_OBSERVED")
        ExpectedFailureProperty = $null
    },
    [pscustomobject]@{
        Name = "client-return-before-begin"
        Order = @("C_ASYNC_CALL_RETURN", "C_ASYNC_CALL_BEGIN", "S_HANDLER_POST", "S_HANDLER_RUN", "C_CALLBACK", "C_ASYNC_CALLBACK_OBSERVED")
        ExpectedFailureProperty = "clientCallOrderPassed"
    },
    [pscustomobject]@{
        Name = "server-post-before-client-begin"
        Order = @("S_HANDLER_POST", "C_ASYNC_CALL_BEGIN", "C_ASYNC_CALL_RETURN", "S_HANDLER_RUN", "C_CALLBACK", "C_ASYNC_CALLBACK_OBSERVED")
        ExpectedFailureProperty = "serverHandlerOrderPassed"
    },
    [pscustomobject]@{
        Name = "handler-run-before-post"
        Order = @("C_ASYNC_CALL_BEGIN", "C_ASYNC_CALL_RETURN", "S_HANDLER_RUN", "S_HANDLER_POST", "C_CALLBACK", "C_ASYNC_CALLBACK_OBSERVED")
        ExpectedFailureProperty = "serverHandlerOrderPassed"
    },
    [pscustomobject]@{
        Name = "callback-before-handler-run"
        Order = @("C_ASYNC_CALL_BEGIN", "C_ASYNC_CALL_RETURN", "S_HANDLER_POST", "C_CALLBACK", "S_HANDLER_RUN", "C_ASYNC_CALLBACK_OBSERVED")
        ExpectedFailureProperty = "callbackOrderPassed"
    },
    [pscustomobject]@{
        Name = "client-observes-before-return"
        Order = @("C_ASYNC_CALL_BEGIN", "S_HANDLER_POST", "S_HANDLER_RUN", "C_CALLBACK", "C_ASYNC_CALLBACK_OBSERVED", "C_ASYNC_CALL_RETURN")
        ExpectedFailureProperty = "clientEventuallyObservedCallback"
    }
)

$results = New-Object System.Collections.Generic.List[object]
foreach ($case in $cases) {
    $tempRoot = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ("BinderLab-async-order-" + [guid]::NewGuid().ToString("N"))
    $tempEvidence = Join-Path $tempRoot "evidence"
    try {
        New-Item -ItemType Directory -Path $tempEvidence -Force | Out-Null
        Copy-Item -Path (Join-Path $evidencePath "*") `
            -Destination $tempEvidence `
            -Recurse `
            -Force
        Write-AsyncSchedule `
            -Path (Join-Path $tempEvidence "async-callback.log") `
            -Order $case.Order
        $outputPath = Join-Path $tempRoot "analysis.json"
        $failed = $false
        try {
            & $analyzerPath `
                -EvidenceDir $tempEvidence `
                -OutputPath $outputPath `
                -KeyEvidencePath (Join-Path $tempRoot "key-evidence.md") `
                -CaptureId $sourceMetadata.captureId `
                -CaptureStartedAt $sourceMetadata.captureStartedAt `
                -AnalysisMode Replay `
                -SourceAnalysisPath $sourceAnalysisPath | Out-Null
        } catch {
            $failed = $true
        }
        if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw "Analyzer did not write a report for case $($case.Name)"
        }
        $report = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        if ((@($report.asyncCallback.observedMarkerOrder) -join "`n") -cne
                ($case.Order -join "`n")) {
            throw "Analyzer did not preserve observed marker order for $($case.Name)"
        }
        if ($null -eq $case.ExpectedFailureProperty) {
            foreach ($propertyName in @(
                    "clientCallOrderPassed",
                    "serverHandlerOrderPassed",
                    "callbackOrderPassed",
                    "clientEventuallyObservedCallback",
                    "partialOrderPassed",
                    "clientCallAtNsOrderPassed",
                    "serverHandlerAtNsOrderPassed",
                    "callbackAtNsOrderPassed",
                    "clientEventuallyObservedCallbackAtNs",
                    "partialOrderAtNsPassed"
                )) {
                if (-not $report.asyncCallback.$propertyName) {
                    throw "Legal schedule $($case.Name) failed $propertyName"
                }
            }
            if ($failed -or -not $report.allRequiredChecksPassed) {
                throw "Legal schedule $($case.Name) was rejected"
            }
        } else {
            if (-not $failed -or $report.allRequiredChecksPassed) {
                throw "Invalid schedule $($case.Name) was accepted"
            }
            if ($report.asyncCallback.($case.ExpectedFailureProperty)) {
                throw "Invalid schedule $($case.Name) did not fail $($case.ExpectedFailureProperty)"
            }
            $atNsFailureProperty = switch ($case.ExpectedFailureProperty) {
                "clientCallOrderPassed" { "clientCallAtNsOrderPassed" }
                "serverHandlerOrderPassed" { "serverHandlerAtNsOrderPassed" }
                "callbackOrderPassed" { "callbackAtNsOrderPassed" }
                "clientEventuallyObservedCallback" {
                    "clientEventuallyObservedCallbackAtNs"
                }
            }
            if ($report.asyncCallback.$atNsFailureProperty -or
                    $report.asyncCallback.partialOrderAtNsPassed) {
                throw "Invalid schedule $($case.Name) did not fail its atNs edge"
            }
        }
        $results.Add([pscustomobject]@{
                Name = $case.Name
                Expected = if ($case.ExpectedFailureProperty) { "reject" } else { "accept" }
                Result = if ($failed) { "rejected" } else { "accepted" }
            })
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

[pscustomobject]@{
    Cases = $results.Count
    LegalSchedulesAccepted = @($results | Where-Object { $_.Expected -eq "accept" }).Count
    InvalidSchedulesRejected = @($results | Where-Object { $_.Expected -eq "reject" }).Count
    Result = "passed"
}
