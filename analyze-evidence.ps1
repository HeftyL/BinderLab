param(
    [string]$EvidenceDir = (Join-Path $PSScriptRoot "evidence"),
    [string]$OutputPath = (Join-Path $EvidenceDir "analysis.json"),
    [string]$KeyEvidencePath,
    [string]$CaptureId,
    [string]$CaptureStartedAt
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($KeyEvidencePath)) {
    $KeyEvidencePath = Join-Path `
        (Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputPath))) `
        "key-evidence.md"
}

if ([string]::IsNullOrWhiteSpace($CaptureId) -or
        [string]::IsNullOrWhiteSpace($CaptureStartedAt)) {
    $sourceMetadataPath = Join-Path $EvidenceDir "source.txt"
    if (-not (Test-Path -LiteralPath $sourceMetadataPath -PathType Leaf)) {
        throw "CaptureId and CaptureStartedAt are required when source.txt is unavailable"
    }
    $sourceMetadata = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $sourceMetadataPath -Encoding UTF8) {
        if ($line -match '^(?<key>[A-Za-z][A-Za-z0-9]*)=(?<value>.*)$') {
            if ($sourceMetadata.Contains($Matches.key)) {
                throw "Duplicate source metadata key $($Matches.key)"
            }
            $sourceMetadata[$Matches.key] = $Matches.value
        }
    }
    if ([string]::IsNullOrWhiteSpace($CaptureId) -and
            $sourceMetadata.Contains("captureId")) {
        $CaptureId = $sourceMetadata.captureId
    }
    if ([string]::IsNullOrWhiteSpace($CaptureStartedAt) -and
            $sourceMetadata.Contains("captureStartedAt")) {
        $CaptureStartedAt = $sourceMetadata.captureStartedAt
    }
}
if ($CaptureId -notmatch '^[A-Za-z0-9][A-Za-z0-9-]+$') {
    throw "CaptureId has an invalid format: $CaptureId"
}
try {
    $captureStartedAtValue = [DateTimeOffset]::ParseExact(
        $CaptureStartedAt,
        "o",
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None)
} catch {
    throw "CaptureStartedAt is not a round-trip ISO-8601 timestamp: $CaptureStartedAt"
}

function Read-Events {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing evidence log: $Path"
    }
    $events = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -notmatch 'BinderLab:\s+(?<marker>[A-Z0-9_]+)\s+(?<detail>.*)$') {
            continue
        }
        $fields = [ordered]@{}
        $fieldPattern = '(?<key>[A-Za-z][A-Za-z0-9]*)=(?<value>.*?)(?=\s+[A-Za-z][A-Za-z0-9]*=|$)'
        foreach ($match in [regex]::Matches($Matches.detail, $fieldPattern)) {
            $key = $match.Groups['key'].Value
            if ($fields.Contains($key)) {
                throw "Duplicate field $key in evidence line: $line"
            }
            $fields[$key] = $match.Groups['value'].Value.Trim()
        }
        $events.Add([pscustomobject]@{
            Index = $index
            Marker = $Matches.marker
            Fields = $fields
            Raw = $line
        })
        $index++
    }
    return $events.ToArray()
}

function Get-RequiredEvent {
    param(
        [object[]]$Events,
        [string]$Marker
    )

    $matches = @($Events | Where-Object { $_.Marker -eq $Marker })
    if ($matches.Count -ne 1) {
        throw "Expected exactly one $Marker event, found $($matches.Count)"
    }
    return $matches[0]
}

function Get-RequiredEventMatching {
    param(
        [object[]]$Events,
        [string]$Marker,
        [hashtable]$RequiredFields
    )

    $matches = @(
        foreach ($event in $Events) {
            if ($event.Marker -ne $Marker) {
                continue
            }
            $fieldMatch = $true
            foreach ($name in $RequiredFields.Keys) {
                if (-not $event.Fields.Contains($name) -or
                        $event.Fields[$name] -ne $RequiredFields[$name].ToString()) {
                    $fieldMatch = $false
                    break
                }
            }
            if ($fieldMatch) {
                $event
            }
        }
    )
    $fieldDescription = @($RequiredFields.Keys | ForEach-Object {
        "$_=$($RequiredFields[$_])"
    }) -join ", "
    if ($matches.Count -ne 1) {
        throw "Expected exactly one $Marker event matching $fieldDescription, found $($matches.Count)"
    }
    return $matches[0]
}

function Get-Field {
    param(
        [object]$Event,
        [string]$Name
    )

    if (-not $Event.Fields.Contains($Name)) {
        throw "Event $($Event.Marker) has no $Name field: $($Event.Raw)"
    }
    return $Event.Fields[$Name]
}

function Test-MarkerOrder {
    param(
        [object[]]$Events,
        [string[]]$Markers
    )

    $indices = @()
    foreach ($marker in $Markers) {
        $indices += (Get-RequiredEvent -Events $Events -Marker $marker).Index
    }
    for ($i = 1; $i -lt $indices.Count; $i++) {
        if ($indices[$i] -le $indices[$i - 1]) {
            return $false
        }
    }
    return $true
}

function Get-Intervals {
    param(
        [object[]]$Events,
        [string]$EnterMarker,
        [string]$ExitMarker,
        [string]$NodeField
    )

    $intervals = New-Object System.Collections.Generic.List[object]
    $enters = @($Events | Where-Object { $_.Marker -eq $EnterMarker })
    $exits = @($Events | Where-Object { $_.Marker -eq $ExitMarker })
    if ($enters.Count -ne $exits.Count) {
        throw "$EnterMarker/$ExitMarker count mismatch: $($enters.Count)/$($exits.Count)"
    }
    foreach ($enter in $enters) {
        $requestId = Get-Field -Event $enter -Name "requestId"
        $exit = @($exits | Where-Object {
            $_.Marker -eq $ExitMarker `
                -and $_.Fields.Contains("requestId") `
                -and $_.Fields["requestId"] -eq $requestId
        })
        if ($exit.Count -ne 1) {
            throw "Expected one $ExitMarker for requestId=$requestId, found $($exit.Count)"
        }
        $enterNode = Get-Field -Event $enter -Name $NodeField
        $exitNode = Get-Field -Event $exit[0] -Name $NodeField
        $beginNs = [long](Get-Field -Event $enter -Name "begin")
        $endNs = [long](Get-Field -Event $exit[0] -Name "end")
        $reportedRunNs = [long](Get-Field -Event $exit[0] -Name "runNs")
        $enterPid = [int](Get-Field -Event $enter -Name "pid")
        $exitPid = [int](Get-Field -Event $exit[0] -Name "pid")
        $enterTid = [int](Get-Field -Event $enter -Name "tid")
        $exitTid = [int](Get-Field -Event $exit[0] -Name "tid")
        $enterThread = Get-Field -Event $enter -Name "thread"
        $exitThread = Get-Field -Event $exit[0] -Name "thread"
        $durationNs = $endNs - $beginNs
        $integrityPassed = $durationNs -gt 0L `
            -and $enterNode -eq $exitNode `
            -and $enterPid -eq $exitPid `
            -and $enterTid -eq $exitTid `
            -and $enterThread -eq $exitThread `
            -and $reportedRunNs -eq $durationNs
        $intervals.Add([pscustomobject]@{
            Node = $enterNode
            RequestId = [int]$requestId
            Pid = $enterPid
            Tid = $enterTid
            Thread = $enterThread
            BeginNs = $beginNs
            EndNs = $endNs
            RunNs = $durationNs
            ReportedRunNs = $reportedRunNs
            PositiveDuration = $durationNs -gt 0L
            NodeMatches = $enterNode -eq $exitNode
            PidMatches = $enterPid -eq $exitPid
            TidMatches = $enterTid -eq $exitTid
            ThreadMatches = $enterThread -eq $exitThread
            RunNsMatches = $reportedRunNs -eq $durationNs
            IntegrityPassed = $integrityPassed
        })
    }
    return $intervals.ToArray()
}

function Test-SerialIntervals {
    param([object[]]$Intervals)

    $sorted = @($Intervals | Sort-Object BeginNs)
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        if ($sorted[$i].BeginNs -lt $sorted[$i - 1].EndNs) {
            return $false
        }
    }
    return $true
}

function Get-RequiredInterval {
    param(
        [object[]]$Intervals,
        [int]$RequestId
    )

    $matches = @($Intervals | Where-Object { $_.RequestId -eq $RequestId })
    if ($matches.Count -ne 1) {
        throw "Expected exactly one interval for requestId=$RequestId, found $($matches.Count)"
    }
    return $matches[0]
}

function Get-RequestIdOrder {
    param(
        [object[]]$Events,
        [string]$Marker
    )

    return @($Events |
        Where-Object { $_.Marker -eq $Marker } |
        Sort-Object Index |
        ForEach-Object { [int](Get-Field -Event $_ -Name "requestId") })
}

function Test-ExactOrder {
    param(
        [int[]]$Actual,
        [int[]]$Expected
    )

    return ($Actual -join ',') -eq ($Expected -join ',')
}

$handlerMarkers = @("C0", "S0", "H0A", "H0B", "H1", "H2", "S1", "C1")

function Read-HandlerRuns {
    param(
        [string]$Prefix,
        [bool]$ExpectedBlocker
    )

    $expectedNames = @(1..5 | ForEach-Object {
        "{0}-run-{1:d2}.log" -f $Prefix, $_
    })
    $actualNames = @(Get-ChildItem `
        -LiteralPath $EvidenceDir `
        -File `
        -Filter "$Prefix*.log" |
        ForEach-Object { $_.Name } |
        Sort-Object)
    if (($expectedNames -join "`n") -ne ($actualNames -join "`n")) {
        throw "$Prefix evidence must contain exactly run-01 through run-05. Expected:`n$($expectedNames -join "`n")`nActual:`n$($actualNames -join "`n")"
    }

    $runs = New-Object System.Collections.Generic.List[object]
    foreach ($name in $expectedNames) {
        $events = Read-Events -Path (Join-Path $EvidenceDir $name)
        $eventByMarker = [ordered]@{}
        foreach ($marker in $handlerMarkers) {
            $eventByMarker[$marker] = Get-RequiredEvent `
                -Events $events `
                -Marker $marker
        }
        $requestIds = @($handlerMarkers | ForEach-Object {
            Get-Field -Event $eventByMarker[$_] -Name "requestId"
        } | Select-Object -Unique)
        $atNs = [ordered]@{}
        foreach ($marker in $handlerMarkers) {
            $atNs[$marker] = [long](Get-Field `
                -Event $eventByMarker[$marker] `
                -Name "atNs")
        }
        $segments = [ordered]@{
            c0ToS0Ns = $atNs.S0 - $atNs.C0
            s0ToH0aNs = $atNs.H0A - $atNs.S0
            h0aToH0bNs = $atNs.H0B - $atNs.H0A
            h0bToH1Ns = $atNs.H1 - $atNs.H0B
            h1ToH2Ns = $atNs.H2 - $atNs.H1
            h2ToS1Ns = $atNs.S1 - $atNs.H2
            s1ToC1Ns = $atNs.C1 - $atNs.S1
        }
        $segmentValues = @($segments.Values | ForEach-Object { [long]$_ })
        $segmentSum = [long](($segmentValues | Measure-Object -Sum).Sum)
        $totalNs = $atNs.C1 - $atNs.C0
        $postCallNs = [long](Get-Field -Event $eventByMarker.H0B -Name "postCallNs")
        $queueNs = [long](Get-Field -Event $eventByMarker.H1 -Name "queueNs")
        $runNs = [long](Get-Field -Event $eventByMarker.H2 -Name "runNs")
        $serverNs = [long](Get-Field -Event $eventByMarker.S1 -Name "serverNs")
        $costNs = [long](Get-Field -Event $eventByMarker.C1 -Name "costNs")
        $expectedBlockerText = $ExpectedBlocker.ToString().ToLowerInvariant()
        $blockerFields = @("C0", "S0", "H0B") | ForEach-Object {
            Get-Field -Event $eventByMarker[$_] -Name "injectHandlerBlocker"
        }
        $clientMarkers = @("C0", "C1")
        $serverMarkers = @("S0", "H0A", "H0B", "H1", "H2", "S1")
        $binderMarkers = @("S0", "H0A", "H0B", "S1")
        $handlerThreadMarkers = @("H1", "H2")
        $clientPids = @($clientMarkers | ForEach-Object {
            [int](Get-Field -Event $eventByMarker[$_] -Name "pid")
        } | Select-Object -Unique)
        $serverPids = @($serverMarkers | ForEach-Object {
            [int](Get-Field -Event $eventByMarker[$_] -Name "pid")
        } | Select-Object -Unique)
        $clientTids = @($clientMarkers | ForEach-Object {
            [int](Get-Field -Event $eventByMarker[$_] -Name "tid")
        } | Select-Object -Unique)
        $binderTids = @($binderMarkers | ForEach-Object {
            [int](Get-Field -Event $eventByMarker[$_] -Name "tid")
        } | Select-Object -Unique)
        $handlerTids = @($handlerThreadMarkers | ForEach-Object {
            [int](Get-Field -Event $eventByMarker[$_] -Name "tid")
        } | Select-Object -Unique)
        $threadNameConsistentWithBinderPool = @($binderMarkers | Where-Object {
            (Get-Field -Event $eventByMarker[$_] -Name "thread") -notmatch '(?i)^binder:'
        }).Count -eq 0
        $handlerThreadNameMatchesConfiguredWorker = @($handlerThreadMarkers | Where-Object {
            (Get-Field -Event $eventByMarker[$_] -Name "thread") -ne 'CalculatorWorker'
        }).Count -eq 0
        $topologyPassed = $clientPids.Count -eq 1 `
            -and $serverPids.Count -eq 1 `
            -and $clientPids[0] -ne $serverPids[0] `
            -and $clientTids.Count -eq 1 `
            -and $binderTids.Count -eq 1 `
            -and $handlerTids.Count -eq 1 `
            -and $binderTids[0] -ne $handlerTids[0]
        $runs.Add([pscustomobject]@{
            file = $name
            requestId = [int]$requestIds[0]
            sameRequestId = $requestIds.Count -eq 1
            strictMarkerOrder = Test-MarkerOrder `
                -Events $events `
                -Markers $handlerMarkers
            strictlyIncreasingAtNs = @($segmentValues | Where-Object { $_ -le 0 }).Count -eq 0
            segmentArithmeticMatchesTotal = $segmentSum -eq $totalNs
            durationFieldsMatchAtNs = $costNs -eq $totalNs `
                -and $serverNs -eq ($atNs.S1 - $atNs.S0) `
                -and $postCallNs -eq $segments.h0aToH0bNs `
                -and $queueNs -eq $segments.h0bToH1Ns `
                -and $runNs -eq $segments.h1ToH2Ns
            blockerModeMatches = @($blockerFields | Where-Object {
                $_ -ne $expectedBlockerText
            }).Count -eq 0
            selfReportedPostAccepted = (Get-Field `
                -Event $eventByMarker.H0B `
                -Name "postAccepted") -eq "true"
            clientProcessStable = $clientPids.Count -eq 1
            serverProcessStable = $serverPids.Count -eq 1
            clientAndServerProcessesDiffer = $clientPids.Count -eq 1 `
                -and $serverPids.Count -eq 1 `
                -and $clientPids[0] -ne $serverPids[0]
            clientThreadStable = $clientTids.Count -eq 1
            binderThreadStable = $binderTids.Count -eq 1
            handlerThreadStable = $handlerTids.Count -eq 1
            handlerThreadDiffersFromBinderThread = $binderTids.Count -eq 1 `
                -and $handlerTids.Count -eq 1 `
                -and $binderTids[0] -ne $handlerTids[0]
            threadNameConsistentWithBinderPool = $threadNameConsistentWithBinderPool
            handlerThreadNameMatchesConfiguredWorker = $handlerThreadNameMatchesConfiguredWorker
            topologyPassed = $topologyPassed
            postCallNs = $postCallNs
            queueNs = $queueNs
            handlerRunNs = $runNs
            serverNs = $serverNs
            totalNs = $totalNs
            segmentSumNs = $segmentSum
            segments = $segments
        })
    }
    return $runs.ToArray()
}

function New-HandlerSummary {
    param(
        [object[]]$Runs,
        [bool]$ExpectedBlocker
    )

    $postCallMeasure = $Runs | Measure-Object -Property postCallNs -Minimum -Maximum
    $queueMeasure = $Runs | Measure-Object -Property queueNs -Minimum -Maximum
    $semanticThresholdPassed = if ($ExpectedBlocker) {
        @($Runs | Where-Object {
            $_.queueNs -le 1000000000L `
                -or $_.postCallNs -ge 50000000L `
                -or $_.queueNs -le ($_.postCallNs * 10L)
        }).Count -eq 0
    } else {
        @($Runs | Where-Object {
            $_.queueNs -lt 0L `
                -or $_.queueNs -ge 500000000L `
                -or $_.postCallNs -ge 50000000L
        }).Count -eq 0
    }
    return [ordered]@{
        runCount = $Runs.Count
        expectedBlocker = $ExpectedBlocker
        sameRequestId = @($Runs | Where-Object { -not $_.sameRequestId }).Count -eq 0
        strictMarkerOrder = @($Runs | Where-Object { -not $_.strictMarkerOrder }).Count -eq 0
        strictlyIncreasingAtNs = @($Runs | Where-Object {
            -not $_.strictlyIncreasingAtNs
        }).Count -eq 0
        segmentArithmeticConsistent = @($Runs | Where-Object {
            -not $_.segmentArithmeticMatchesTotal
        }).Count -eq 0
        durationFieldsCrossChecked = @($Runs | Where-Object {
            -not $_.durationFieldsMatchAtNs
        }).Count -eq 0
        blockerModeMatches = @($Runs | Where-Object {
            -not $_.blockerModeMatches
        }).Count -eq 0
        topologyPassed = @($Runs | Where-Object {
            -not $_.topologyPassed
        }).Count -eq 0
        semanticThresholdPassed = $semanticThresholdPassed
        postCallNsMin = [long]$postCallMeasure.Minimum
        postCallNsMax = [long]$postCallMeasure.Maximum
        queueNsMin = [long]$queueMeasure.Minimum
        queueNsMax = [long]$queueMeasure.Maximum
        runs = $Runs
    }
}

$handlerBaselineRuns = @(Read-HandlerRuns `
    -Prefix "handler-latency-baseline" `
    -ExpectedBlocker $false)
$handlerBlockedRuns = @(Read-HandlerRuns `
    -Prefix "handler-latency-blocked" `
    -ExpectedBlocker $true)
$handlerBaseline = New-HandlerSummary `
    -Runs $handlerBaselineRuns `
    -ExpectedBlocker $false
$handlerBlocked = New-HandlerSummary `
    -Runs $handlerBlockedRuns `
    -ExpectedBlocker $true
$handlerComparison = [ordered]@{
    baselineQueueNsMax = $handlerBaseline.queueNsMax
    blockedQueueNsMin = $handlerBlocked.queueNsMin
    queueSeparationNs = $handlerBlocked.queueNsMin - $handlerBaseline.queueNsMax
    blockedClearlySeparated = $handlerBlocked.queueNsMin `
        -gt ($handlerBaseline.queueNsMax + 500000000L)
}

$syncEvents = Read-Events -Path (Join-Path $EvidenceDir "sync-reentry.log")
$syncMarkers = @(
    "C_SYNC_CALL_BEGIN",
    "S_BEFORE_SYNC_CALLBACK",
    "C_SYNC_CALLBACK",
    "S_AFTER_SYNC_CALLBACK",
    "C_SYNC_CALL_END"
)
$syncRequestIds = @($syncMarkers | ForEach-Object {
    Get-Field -Event (Get-RequiredEvent -Events $syncEvents -Marker $_) -Name "requestId"
} | Select-Object -Unique)
$syncBegin = Get-RequiredEvent -Events $syncEvents -Marker "C_SYNC_CALL_BEGIN"
$syncBeforeCallback = Get-RequiredEvent -Events $syncEvents -Marker "S_BEFORE_SYNC_CALLBACK"
$syncCallback = Get-RequiredEvent -Events $syncEvents -Marker "C_SYNC_CALLBACK"
$syncAfterCallback = Get-RequiredEvent -Events $syncEvents -Marker "S_AFTER_SYNC_CALLBACK"
$syncEnd = Get-RequiredEvent -Events $syncEvents -Marker "C_SYNC_CALL_END"
$syncCallerTid = [int](Get-Field -Event $syncBegin -Name "tid")
$syncDeclaredCallerTid = [int](Get-Field -Event $syncBegin -Name "callerTid")
$syncCallbackTid = [int](Get-Field -Event $syncCallback -Name "tid")
$syncWaitingTid = [int](Get-Field -Event $syncCallback -Name "waitingTid")
$syncStrictOrder = Test-MarkerOrder -Events $syncEvents -Markers $syncMarkers
$syncAtNs = [ordered]@{
    callBegin = [long](Get-Field -Event $syncBegin -Name "atNs")
    beforeCallback = [long](Get-Field -Event $syncBeforeCallback -Name "atNs")
    callback = [long](Get-Field -Event $syncCallback -Name "atNs")
    afterCallback = [long](Get-Field -Event $syncAfterCallback -Name "atNs")
    callEnd = [long](Get-Field -Event $syncEnd -Name "atNs")
}
$syncSegmentsNs = [ordered]@{
    callBeginToBeforeCallback = $syncAtNs.beforeCallback - $syncAtNs.callBegin
    beforeCallbackToCallback = $syncAtNs.callback - $syncAtNs.beforeCallback
    callbackToAfterCallback = $syncAtNs.afterCallback - $syncAtNs.callback
    afterCallbackToCallEnd = $syncAtNs.callEnd - $syncAtNs.afterCallback
}
$syncStrictlyIncreasingAtNs = @($syncSegmentsNs.Values | Where-Object {
    [long]$_ -le 0L
}).Count -eq 0
$syncAppEvents = @($syncBegin, $syncCallback, $syncEnd)
$syncServerEvents = @($syncBeforeCallback, $syncAfterCallback)
$syncAppPids = @($syncAppEvents | ForEach-Object {
    [int](Get-Field -Event $_ -Name "pid")
} | Select-Object -Unique)
$syncServerPids = @($syncServerEvents | ForEach-Object {
    [int](Get-Field -Event $_ -Name "pid")
} | Select-Object -Unique)
$syncAppTids = @($syncAppEvents | ForEach-Object {
    [int](Get-Field -Event $_ -Name "tid")
} | Select-Object -Unique)
$syncServerTids = @($syncServerEvents | ForEach-Object {
    [int](Get-Field -Event $_ -Name "tid")
} | Select-Object -Unique)
$syncAppThreads = @($syncAppEvents | ForEach-Object {
    Get-Field -Event $_ -Name "thread"
} | Select-Object -Unique)
$syncAppThreadNameStable = $syncAppThreads.Count -eq 1
$syncServerThreadNameConsistentWithBinderPool = @($syncServerEvents | Where-Object {
    (Get-Field -Event $_ -Name "thread") -notmatch '(?i)^binder:'
}).Count -eq 0
$syncProcessTopologyPassed = $syncAppPids.Count -eq 1 `
    -and $syncServerPids.Count -eq 1 `
    -and $syncAppPids[0] -ne $syncServerPids[0]
$syncThreadTopologyPassed = $syncAppTids.Count -eq 1 `
    -and $syncServerTids.Count -eq 1
$sync = [ordered]@{
    requestId = [int]$syncRequestIds[0]
    sameRequestId = $syncRequestIds.Count -eq 1
    strictNestedOrder = $syncStrictOrder
    strictlyIncreasingAtNs = $syncStrictlyIncreasingAtNs
    atNs = $syncAtNs
    segmentsNs = $syncSegmentsNs
    callerTid = $syncCallerTid
    callbackTid = $syncCallbackTid
    waitingTid = $syncWaitingTid
    insideOuterCall = $syncStrictOrder
    reusedWaitingThread = $syncCallerTid -eq $syncDeclaredCallerTid `
        -and $syncCallbackTid -eq $syncCallerTid `
        -and $syncWaitingTid -eq $syncCallerTid
    appProcessStable = $syncAppPids.Count -eq 1
    serverProcessStable = $syncServerPids.Count -eq 1
    appAndServerProcessesDiffer = $syncAppPids.Count -eq 1 `
        -and $syncServerPids.Count -eq 1 `
        -and $syncAppPids[0] -ne $syncServerPids[0]
    appThreadStable = $syncAppTids.Count -eq 1
    serverThreadStable = $syncServerTids.Count -eq 1
    appThreadNameStable = $syncAppThreadNameStable
    serverThreadNameConsistentWithBinderPool = $syncServerThreadNameConsistentWithBinderPool
    processTopologyPassed = $syncProcessTopologyPassed
    threadTopologyPassed = $syncThreadTopologyPassed
    topologyPassed = $syncProcessTopologyPassed -and $syncThreadTopologyPassed
    selfReportedInsideOuterCall = (Get-Field `
        -Event $syncCallback `
        -Name "insideOuterCall") -eq "true"
    selfReportedReusedWaitingThread = (Get-Field `
        -Event $syncCallback `
        -Name "reusedWaitingThread") -eq "true"
}

$sameEvents = Read-Events -Path (Join-Path $EvidenceDir "oneway-same-node.log")
$sameIntervals = Get-Intervals `
    -Events $sameEvents `
    -EnterMarker "S_ONEWAY_ENTER" `
    -ExitMarker "S_ONEWAY_EXIT" `
    -NodeField "node"
$sameExpectedIds = [int[]]@(1001, 1002, 1003)
$sameBegins = @($sameEvents | Where-Object {
    $_.Marker -eq "C_SAME_NODE_CALL_BEGIN"
} | Sort-Object Index)
$sameReturns = @($sameEvents | Where-Object {
    $_.Marker -eq "C_SAME_NODE_CALL_RETURN"
} | Sort-Object Index)
$sameSorted = @($sameIntervals | Sort-Object BeginNs)
$sameClientBeginOrder = @(Get-RequestIdOrder `
    -Events $sameEvents `
    -Marker "C_SAME_NODE_CALL_BEGIN")
$sameClientReturnOrder = @(Get-RequestIdOrder `
    -Events $sameEvents `
    -Marker "C_SAME_NODE_CALL_RETURN")
$sameServerOrder = @($sameSorted | ForEach-Object { $_.RequestId })
$sameFirstInterval = Get-RequiredInterval -Intervals $sameIntervals -RequestId 1001
$sameSecondReturn = Get-RequiredEventMatching `
    -Events $sameEvents `
    -Marker "C_SAME_NODE_CALL_RETURN" `
    -RequiredFields @{ requestId = "1002" }
$sameIntervalIntegrityPassed = @($sameIntervals | Where-Object {
    -not $_.IntegrityPassed
}).Count -eq 0
$sameThreadNameConsistentWithBinderPool = @($sameIntervals | Where-Object {
    $_.Thread -notmatch '(?i)^binder:'
}).Count -eq 0
$sameNode = [ordered]@{
    transactionCount = $sameIntervals.Count
    expectedRequestIds = $sameExpectedIds
    clientBeginOrder = $sameClientBeginOrder
    clientReturnOrder = $sameClientReturnOrder
    serverBeginOrder = $sameServerOrder
    clientBeginOrderMatchesExpected = Test-ExactOrder `
        -Actual $sameClientBeginOrder `
        -Expected $sameExpectedIds
    clientReturnOrderMatchesExpected = Test-ExactOrder `
        -Actual $sameClientReturnOrder `
        -Expected $sameExpectedIds
    clientAndServerRequestIdsMatch = Test-ExactOrder `
        -Actual $sameServerOrder `
        -Expected $sameExpectedIds
    serverOrderMatchesClientSubmission = Test-ExactOrder `
        -Actual $sameServerOrder `
        -Expected $sameClientBeginOrder
    intervalIntegrityPassed = $sameIntervalIntegrityPassed
    threadNameConsistentWithBinderPool = $sameThreadNameConsistentWithBinderPool
    serial = $sameIntervals.Count -eq 3 -and (Test-SerialIntervals -Intervals $sameIntervals)
    secondCallReturnedBeforeFirstExit = [long](Get-Field `
        -Event $sameSecondReturn `
        -Name "atNs") -lt $sameFirstInterval.EndNs
    intervals = @($sameSorted)
}

$crossEvents = Read-Events -Path (Join-Path $EvidenceDir "oneway-cross-node.log")
$crossIntervals = Get-Intervals `
    -Events $crossEvents `
    -EnterMarker "S_ASYNC_WORKER_ENTER" `
    -ExitMarker "S_ASYNC_WORKER_EXIT" `
    -NodeField "node"
$n1Intervals = @($crossIntervals | Where-Object { $_.Node -eq "N1" } | Sort-Object BeginNs)
$n2Intervals = @($crossIntervals | Where-Object { $_.Node -eq "N2" } | Sort-Object BeginNs)
$n1ExpectedIds = [int[]]@(1001, 1002)
$n2ExpectedIds = [int[]]@(1003, 1004)
$crossExpectedIds = [int[]]@(1001, 1002, 1003, 1004)
$n1ClientBeginOrder = @(Get-RequestIdOrder -Events $crossEvents -Marker "C_N1_CALL_BEGIN")
$n1ClientReturnOrder = @(Get-RequestIdOrder -Events $crossEvents -Marker "C_N1_CALL_RETURN")
$n2ClientBeginOrder = @(Get-RequestIdOrder -Events $crossEvents -Marker "C_N2_CALL_BEGIN")
$n2ClientReturnOrder = @(Get-RequestIdOrder -Events $crossEvents -Marker "C_N2_CALL_RETURN")
$n1ServerOrder = @($n1Intervals | ForEach-Object { $_.RequestId })
$n2ServerOrder = @($n2Intervals | ForEach-Object { $_.RequestId })
$crossClientIds = @(($n1ClientReturnOrder + $n2ClientReturnOrder) | Sort-Object)
$crossServerIds = @($crossIntervals | ForEach-Object { $_.RequestId } | Sort-Object)
$n1FirstInterval = Get-RequiredInterval -Intervals $crossIntervals -RequestId 1001
$n1SecondInterval = Get-RequiredInterval -Intervals $crossIntervals -RequestId 1002
$n2FirstInterval = Get-RequiredInterval -Intervals $crossIntervals -RequestId 1003
$n2SecondInterval = Get-RequiredInterval -Intervals $crossIntervals -RequestId 1004
$n1SecondReturn = Get-RequiredEventMatching `
    -Events $crossEvents `
    -Marker "C_N1_CALL_RETURN" `
    -RequiredFields @{ requestId = "1002" }
$n2SecondReturn = Get-RequiredEventMatching `
    -Events $crossEvents `
    -Marker "C_N2_CALL_RETURN" `
    -RequiredFields @{ requestId = "1004" }
$maxOverlapNs = 0L
$overlapPair = $null
foreach ($n1 in $n1Intervals) {
    foreach ($n2 in $n2Intervals) {
        $overlap = [Math]::Max(
            0L,
            [Math]::Min($n1.EndNs, $n2.EndNs) - [Math]::Max($n1.BeginNs, $n2.BeginNs))
        if ($overlap -gt $maxOverlapNs) {
            $maxOverlapNs = $overlap
            $overlapPair = [ordered]@{
                n1RequestId = $n1.RequestId
                n1Tid = $n1.Tid
                n2RequestId = $n2.RequestId
                n2Tid = $n2.Tid
            }
        }
    }
}
$firstPairOverlapNs = [Math]::Max(
    0L,
    [Math]::Min($n1FirstInterval.EndNs, $n2FirstInterval.EndNs) `
        - [Math]::Max($n1FirstInterval.BeginNs, $n2FirstInterval.BeginNs))
$crossIntervalIntegrityPassed = @($crossIntervals | Where-Object {
    -not $_.IntegrityPassed
}).Count -eq 0
$crossServerPids = @($crossIntervals | ForEach-Object { $_.Pid } | Select-Object -Unique)
$crossThreadNameConsistentWithBinderPool = @($crossIntervals | Where-Object {
    $_.Thread -notmatch '(?i)^binder:'
}).Count -eq 0
$crossNode = [ordered]@{
    transactionCount = $crossIntervals.Count
    expectedRequestIds = $crossExpectedIds
    clientAndServerRequestIdsMatch = Test-ExactOrder `
        -Actual $crossClientIds `
        -Expected $crossExpectedIds
    n1ClientBeginOrder = $n1ClientBeginOrder
    n1ClientReturnOrder = $n1ClientReturnOrder
    n1ServerBeginOrder = $n1ServerOrder
    n2ClientBeginOrder = $n2ClientBeginOrder
    n2ClientReturnOrder = $n2ClientReturnOrder
    n2ServerBeginOrder = $n2ServerOrder
    n1ClientOrderMatchesExpected = (Test-ExactOrder -Actual $n1ClientBeginOrder -Expected $n1ExpectedIds) `
        -and (Test-ExactOrder -Actual $n1ClientReturnOrder -Expected $n1ExpectedIds)
    n2ClientOrderMatchesExpected = (Test-ExactOrder -Actual $n2ClientBeginOrder -Expected $n2ExpectedIds) `
        -and (Test-ExactOrder -Actual $n2ClientReturnOrder -Expected $n2ExpectedIds)
    n1ServerOrderMatchesClientSubmission = Test-ExactOrder `
        -Actual $n1ServerOrder `
        -Expected $n1ClientBeginOrder
    n2ServerOrderMatchesClientSubmission = Test-ExactOrder `
        -Actual $n2ServerOrder `
        -Expected $n2ClientBeginOrder
    intervalIntegrityPassed = $crossIntervalIntegrityPassed
    serverProcessStable = $crossServerPids.Count -eq 1
    threadNameConsistentWithBinderPool = $crossThreadNameConsistentWithBinderPool
    n1Serial = $n1Intervals.Count -eq 2 -and (Test-SerialIntervals -Intervals $n1Intervals)
    n2Serial = $n2Intervals.Count -eq 2 -and (Test-SerialIntervals -Intervals $n2Intervals)
    n1SecondCallReturnedBeforeFirstExit = [long](Get-Field `
        -Event $n1SecondReturn `
        -Name "atNs") -lt $n1FirstInterval.EndNs
    n2SecondCallReturnedBeforeFirstExit = [long](Get-Field `
        -Event $n2SecondReturn `
        -Name "atNs") -lt $n2FirstInterval.EndNs
    firstPairOverlapNs = $firstPairOverlapNs
    maxCrossNodeOverlapNs = $maxOverlapNs
    meaningfulCrossNodeOverlap = $firstPairOverlapNs -gt 100000000L
    overlappingBinderThreadsDiffer = $n1FirstInterval.Tid -ne $n2FirstInterval.Tid
    overlapPair = $overlapPair
    intervals = @($crossIntervals | Sort-Object BeginNs)
}

$asyncEvents = Read-Events -Path (Join-Path $EvidenceDir "async-callback.log")
$asyncMarkers = @(
    "C_ASYNC_CALL_BEGIN",
    "C_ASYNC_CALL_RETURN",
    "S_HANDLER_POST",
    "S_HANDLER_RUN",
    "C_CALLBACK",
    "C_ASYNC_CALLBACK_OBSERVED"
)
$asyncRequestIds = @($asyncMarkers | ForEach-Object {
    Get-Field -Event (Get-RequiredEvent -Events $asyncEvents -Marker $_) -Name "requestId"
} | Select-Object -Unique)
$asyncServerChain = @("S_HANDLER_POST", "S_HANDLER_RUN", "C_CALLBACK", "C_ASYNC_CALLBACK_OBSERVED")
$asyncBegin = Get-RequiredEvent -Events $asyncEvents -Marker "C_ASYNC_CALL_BEGIN"
$asyncReturn = Get-RequiredEvent -Events $asyncEvents -Marker "C_ASYNC_CALL_RETURN"
$asyncServerPost = Get-RequiredEvent -Events $asyncEvents -Marker "S_HANDLER_POST"
$asyncServerRun = Get-RequiredEvent -Events $asyncEvents -Marker "S_HANDLER_RUN"
$asyncCallback = Get-RequiredEvent -Events $asyncEvents -Marker "C_CALLBACK"
$asyncObserved = Get-RequiredEvent -Events $asyncEvents -Marker "C_ASYNC_CALLBACK_OBSERVED"
$connectedActive = Get-RequiredEvent -Events $asyncEvents -Marker "C_CONNECTED_ACTIVE"
$registeredCallback = Get-RequiredEvent -Events $asyncEvents -Marker "S_REGISTER_CALLBACK"
$asyncClientEvents = @($asyncBegin, $asyncReturn, $asyncObserved)
$asyncClientPids = @($asyncClientEvents | ForEach-Object {
    [int](Get-Field -Event $_ -Name "pid")
} | Select-Object -Unique)
$asyncClientTids = @($asyncClientEvents | ForEach-Object {
    [int](Get-Field -Event $_ -Name "tid")
} | Select-Object -Unique)
$asyncServerEvents = @($asyncServerPost, $asyncServerRun)
$asyncServerPids = @($asyncServerEvents | ForEach-Object {
    [int](Get-Field -Event $_ -Name "pid")
} | Select-Object -Unique)
$asyncCallbackPid = [int](Get-Field -Event $asyncCallback -Name "pid")
$asyncCallbackTid = [int](Get-Field -Event $asyncCallback -Name "tid")
$asyncServerPostTid = [int](Get-Field -Event $asyncServerPost -Name "tid")
$asyncServerRunTid = [int](Get-Field -Event $asyncServerRun -Name "tid")
$asyncServerEntryThreadNameConsistentWithBinderPool = `
    (Get-Field -Event $asyncServerPost -Name "thread") -match '(?i)^binder:'
$asyncServerHandlerThreadNameMatchesConfiguredWorker = `
    (Get-Field -Event $asyncServerRun -Name "thread") -eq 'CalculatorWorker'
$asyncCallbackThreadNameConsistentWithBinderPool = `
    (Get-Field -Event $asyncCallback -Name "thread") -match '(?i)^binder:'
$asyncTopologyPassed = $asyncClientPids.Count -eq 1 `
    -and $asyncClientTids.Count -eq 1 `
    -and $asyncServerPids.Count -eq 1 `
    -and $asyncClientPids[0] -ne $asyncServerPids[0] `
    -and $asyncCallbackPid -eq $asyncClientPids[0] `
    -and $asyncCallbackTid -ne $asyncClientTids[0] `
    -and $asyncServerPostTid -ne $asyncServerRunTid
$async = [ordered]@{
    requestId = [int]$asyncRequestIds[0]
    sameRequestId = $asyncRequestIds.Count -eq 1
    serverToCallbackOrder = Test-MarkerOrder -Events $asyncEvents -Markers $asyncServerChain
    requestIdsMatchIndependently = $asyncRequestIds.Count -eq 1
    selfReportedRequestMatches = (Get-Field `
        -Event $asyncCallback `
        -Name "requestMatches") -eq "true"
    proxyClassesObserved = (Get-Field `
        -Event $connectedActive `
        -Name "calculatorClass") -eq "com.example.binderdemo.ICalculator`$Stub`$Proxy" `
        -and (Get-Field `
            -Event $connectedActive `
            -Name "calculatorBinderClass") -eq "android.os.BinderProxy" `
        -and (Get-Field `
            -Event $registeredCallback `
            -Name "callbackClass") -eq "com.example.binderdemo.IResultCallback`$Stub`$Proxy" `
        -and (Get-Field `
            -Event $registeredCallback `
            -Name "callbackBinderClass") -eq "android.os.BinderProxy"
    clientProcessStable = $asyncClientPids.Count -eq 1
    clientExperimentThreadStable = $asyncClientTids.Count -eq 1
    serverProcessStable = $asyncServerPids.Count -eq 1
    clientAndServerProcessesDiffer = $asyncClientPids.Count -eq 1 `
        -and $asyncServerPids.Count -eq 1 `
        -and $asyncClientPids[0] -ne $asyncServerPids[0]
    callbackRunsInClientProcess = $asyncClientPids.Count -eq 1 `
        -and $asyncCallbackPid -eq $asyncClientPids[0]
    callbackThreadDiffersFromExperimentThread = $asyncClientTids.Count -eq 1 `
        -and $asyncCallbackTid -ne $asyncClientTids[0]
    serverHandlerThreadDiffersFromBinderThread = $asyncServerPostTid -ne $asyncServerRunTid
    serverEntryThreadNameConsistentWithBinderPool = `
        $asyncServerEntryThreadNameConsistentWithBinderPool
    serverHandlerThreadNameMatchesConfiguredWorker = `
        $asyncServerHandlerThreadNameMatchesConfiguredWorker
    callbackThreadNameConsistentWithBinderPool = `
        $asyncCallbackThreadNameConsistentWithBinderPool
    topologyPassed = $asyncTopologyPassed
    calculatorClass = Get-Field -Event $connectedActive -Name "calculatorClass"
    calculatorBinderClass = Get-Field `
        -Event $connectedActive `
        -Name "calculatorBinderClass"
    callbackClass = Get-Field -Event $registeredCallback -Name "callbackClass"
    callbackBinderClass = Get-Field `
        -Event $registeredCallback `
        -Name "callbackBinderClass"
    observedMarkerOrder = @($asyncEvents | Where-Object {
        $asyncMarkers -contains $_.Marker
    } | ForEach-Object { $_.Marker })
}

$deathEvents = Read-Events -Path (Join-Path $EvidenceDir "binder-death.log")
$activeEvents = @($deathEvents | Where-Object {
    $_.Marker -eq "C_GENERATION_STATE" `
        -and $_.Fields.Contains("newState") `
        -and $_.Fields["newState"] -eq "ACTIVE"
})
$invalidEvent = Get-RequiredEvent -Events $deathEvents -Marker "C_GENERATION_INVALID"
$deadObjectEvent = Get-RequiredEvent -Events $deathEvents -Marker "C_OLD_PROXY_DEAD_OBJECT"
$testRebindEvent = Get-RequiredEvent -Events $deathEvents -Marker "C_TEST_REBIND_BEGIN"
$testRebindResult = Get-RequiredEvent -Events $deathEvents -Marker "C_TEST_REBIND_RESULT"
$experimentNotRestarted = Get-RequiredEvent `
    -Events $deathEvents `
    -Marker "C_EXPERIMENT_NOT_RESTARTED"
$lastSuccessBegin = Get-RequiredEvent `
    -Events $deathEvents `
    -Marker "C_LAST_SUCCESS_BEGIN"
$lastSuccessEnd = Get-RequiredEvent `
    -Events $deathEvents `
    -Marker "C_LAST_SUCCESS_END"
$deathArmed = Get-RequiredEvent `
    -Events $deathEvents `
    -Marker "C_DEATH_EXPERIMENT_ARMED"
$lastSuccessRequestId = Get-Field -Event $lastSuccessBegin -Name "requestId"
$lastSuccessServerS0 = @($deathEvents | Where-Object {
    $_.Marker -eq "S0" `
        -and $_.Fields.Contains("requestId") `
        -and $_.Fields.requestId -eq $lastSuccessRequestId
})
$lastSuccessServerS1 = @($deathEvents | Where-Object {
    $_.Marker -eq "S1" `
        -and $_.Fields.Contains("requestId") `
        -and $_.Fields.requestId -eq $lastSuccessRequestId
})
if ($lastSuccessServerS0.Count -ne 1 -or $lastSuccessServerS1.Count -ne 1) {
    throw "Expected exactly one S0/S1 pair for the pre-kill successful request"
}
$forbiddenDeathMarkers = @(
    "C_OLD_PROXY_PROBE_UNEXPECTED_SUCCESS",
    "C_OLD_PROXY_REMOTE_FAILURE",
    "C_OLD_PROXY_RUNTIME_FAILURE",
    "C_TEST_REBIND_SKIPPED",
    "C_STALE_DEATH_IGNORED",
    "C_REGISTER_FAILED",
    "C_SERVICE_ERROR"
)
$observedForbiddenDeathMarkers = @($deathEvents | Where-Object {
    $forbiddenDeathMarkers -contains $_.Marker
} | ForEach-Object { $_.Marker } | Select-Object -Unique)
$activeGenerationIds = @($activeEvents | ForEach-Object {
    [long](Get-Field -Event $_ -Name "generationId")
})
$activeConnectionEpochs = @($activeEvents | ForEach-Object {
    [long](Get-Field -Event $_ -Name "connectionEpoch")
})
$invalidConnectionEpoch = [long](Get-Field -Event $invalidEvent -Name "connectionEpoch")
$invalidGenerationId = [long](Get-Field -Event $invalidEvent -Name "generationId")
$deadObjectConnectionEpoch = [long](Get-Field -Event $deadObjectEvent -Name "connectionEpoch")
$deadObjectGenerationId = [long](Get-Field -Event $deadObjectEvent -Name "generationId")
$rebindOldEpoch = [long](Get-Field -Event $testRebindEvent -Name "oldConnectionEpoch")
$rebindNewEpoch = [long](Get-Field -Event $testRebindEvent -Name "newConnectionEpoch")
$exactlyTwoActiveGenerations = $activeEvents.Count -eq 2 `
    -and ($activeGenerationIds -join ',') -eq "1,2" `
    -and ($activeConnectionEpochs -join ',') -eq "1,2"
$explicitTestRebindReachedNewGeneration = $exactlyTwoActiveGenerations `
    -and $rebindOldEpoch -eq 1 `
    -and $rebindNewEpoch -eq 2
$deathLifecycleOrder = $exactlyTwoActiveGenerations `
    -and $activeEvents[0].Index -lt $lastSuccessBegin.Index `
    -and $lastSuccessBegin.Index -lt $lastSuccessServerS0[0].Index `
    -and $lastSuccessServerS0[0].Index -lt $lastSuccessServerS1[0].Index `
    -and $lastSuccessServerS1[0].Index -lt $lastSuccessEnd.Index `
    -and $lastSuccessEnd.Index -lt $deathArmed.Index `
    -and $deathArmed.Index -lt $invalidEvent.Index `
    -and $invalidEvent.Index -lt $deadObjectEvent.Index `
    -and $deadObjectEvent.Index -lt $testRebindEvent.Index `
    -and $testRebindEvent.Index -lt $activeEvents[-1].Index `
    -and $activeEvents[-1].Index -lt $experimentNotRestarted.Index
$death = [ordered]@{
    connectionEpoch = $invalidConnectionEpoch
    invalidGenerationId = $invalidGenerationId
    lastSuccessfulRequestId = [int]$lastSuccessRequestId
    t1LastSuccessObserved = (Get-Field `
        -Event $lastSuccessEnd `
        -Name "requestId") -eq $lastSuccessRequestId `
        -and (Get-Field -Event $lastSuccessEnd -Name "result") -eq "42" `
        -and [long](Get-Field -Event $lastSuccessBegin -Name "atNs") `
            -lt [long](Get-Field -Event $lastSuccessServerS0[0] -Name "atNs") `
        -and [long](Get-Field -Event $lastSuccessServerS0[0] -Name "atNs") `
            -lt [long](Get-Field -Event $lastSuccessServerS1[0] -Name "atNs") `
        -and [long](Get-Field -Event $lastSuccessServerS1[0] -Name "atNs") `
            -lt [long](Get-Field -Event $lastSuccessEnd -Name "atNs")
    invalidatedFromActive = (Get-Field -Event $invalidEvent -Name "oldState") -eq "ACTIVE"
    invalidatedCurrentGeneration = (Get-Field -Event $invalidEvent -Name "wasCurrent") -eq "true"
    deathReasonObserved = (Get-Field -Event $invalidEvent -Name "reason") -eq "binderDied"
    oldProxyRaisedDeadObject = (Get-Field -Event $deadObjectEvent -Name "exception") -eq "DeadObjectException"
    deadObjectMatchesInvalidGeneration = $deadObjectConnectionEpoch -eq $invalidConnectionEpoch `
        -and $deadObjectGenerationId -eq $invalidGenerationId
    activeGenerationIds = $activeGenerationIds
    activeConnectionEpochs = $activeConnectionEpochs
    exactlyTwoActiveGenerations = $exactlyTwoActiveGenerations
    explicitTestRebindReachedNewGeneration = $explicitTestRebindReachedNewGeneration
    spaceContainingValuesParsed = (Get-Field `
        -Event $testRebindEvent `
        -Name "reason") -eq "binder-death experiment" `
        -and @($activeEvents | Where-Object {
            (Get-Field -Event $_ -Name "reason") -ne "published to readers"
        }).Count -eq 0
    lifecycleOrder = $deathLifecycleOrder
    observedFailureOrder = "binderDied-before-controlled-dead-object-probe"
    reboundGenerationDidNotRestartExperiment = (Get-Field `
        -Event $experimentNotRestarted `
        -Name "mode") -eq "binder-death"
    rebindReportedBound = (Get-Field `
        -Event $testRebindResult `
        -Name "bound") -eq "true"
    forbiddenMarkersAbsent = $observedForbiddenDeathMarkers.Count -eq 0
    observedForbiddenMarkers = $observedForbiddenDeathMarkers
}

$allRequiredChecksPassed = `
    $handlerBaseline.runCount -eq 5 `
    -and $handlerBaseline.sameRequestId `
    -and $handlerBaseline.strictMarkerOrder `
    -and $handlerBaseline.strictlyIncreasingAtNs `
    -and $handlerBaseline.segmentArithmeticConsistent `
    -and $handlerBaseline.durationFieldsCrossChecked `
    -and $handlerBaseline.blockerModeMatches `
    -and $handlerBaseline.topologyPassed `
    -and $handlerBaseline.semanticThresholdPassed `
    -and $handlerBlocked.runCount -eq 5 `
    -and $handlerBlocked.sameRequestId `
    -and $handlerBlocked.strictMarkerOrder `
    -and $handlerBlocked.strictlyIncreasingAtNs `
    -and $handlerBlocked.segmentArithmeticConsistent `
    -and $handlerBlocked.durationFieldsCrossChecked `
    -and $handlerBlocked.blockerModeMatches `
    -and $handlerBlocked.topologyPassed `
    -and $handlerBlocked.semanticThresholdPassed `
    -and $handlerComparison.blockedClearlySeparated `
    -and $sync.sameRequestId `
    -and $sync.strictNestedOrder `
    -and $sync.strictlyIncreasingAtNs `
    -and $sync.insideOuterCall `
    -and $sync.reusedWaitingThread `
    -and $sync.topologyPassed `
    -and $sameNode.clientBeginOrderMatchesExpected `
    -and $sameNode.clientReturnOrderMatchesExpected `
    -and $sameNode.clientAndServerRequestIdsMatch `
    -and $sameNode.serverOrderMatchesClientSubmission `
    -and $sameNode.intervalIntegrityPassed `
    -and $sameNode.serial `
    -and $sameNode.secondCallReturnedBeforeFirstExit `
    -and $crossNode.clientAndServerRequestIdsMatch `
    -and $crossNode.n1ClientOrderMatchesExpected `
    -and $crossNode.n2ClientOrderMatchesExpected `
    -and $crossNode.n1ServerOrderMatchesClientSubmission `
    -and $crossNode.n2ServerOrderMatchesClientSubmission `
    -and $crossNode.intervalIntegrityPassed `
    -and $crossNode.serverProcessStable `
    -and $crossNode.n1Serial `
    -and $crossNode.n2Serial `
    -and $crossNode.n1SecondCallReturnedBeforeFirstExit `
    -and $crossNode.n2SecondCallReturnedBeforeFirstExit `
    -and $crossNode.meaningfulCrossNodeOverlap `
    -and $crossNode.overlappingBinderThreadsDiffer `
    -and $async.sameRequestId `
    -and $async.serverToCallbackOrder `
    -and $async.requestIdsMatchIndependently `
    -and $async.proxyClassesObserved `
    -and $async.topologyPassed `
    -and $death.invalidatedFromActive `
    -and $death.t1LastSuccessObserved `
    -and $death.invalidatedCurrentGeneration `
    -and $death.deathReasonObserved `
    -and $death.oldProxyRaisedDeadObject `
    -and $death.deadObjectMatchesInvalidGeneration `
    -and $death.exactlyTwoActiveGenerations `
    -and $death.explicitTestRebindReachedNewGeneration `
    -and $death.spaceContainingValuesParsed `
    -and $death.lifecycleOrder `
    -and $death.reboundGenerationDidNotRestartExperiment `
    -and $death.rebindReportedBound `
    -and $death.forbiddenMarkersAbsent

$analysisGeneratedAt = [DateTimeOffset]::Now
if ($analysisGeneratedAt -le $captureStartedAtValue) {
    throw "analysis.generatedAt must be later than captureStartedAt"
}
$analysis = [ordered]@{
    schemaVersion = 6
    captureId = $CaptureId
    captureStartedAt = $CaptureStartedAt
    generatedAt = $analysisGeneratedAt.ToString("o")
    evidenceDirectory = "evidence"
    handlerLatencyBaseline = $handlerBaseline
    handlerLatencyBlocked = $handlerBlocked
    handlerLatencyComparison = $handlerComparison
    syncReentry = $sync
    onewaySameNode = $sameNode
    onewayCrossNode = $crossNode
    asyncCallback = $async
    binderDeath = $death
    allRequiredChecksPassed = $allRequiredChecksPassed
}

$json = ($analysis | ConvertTo-Json -Depth 12) -replace "`r`n?", "`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutputPath, $json + "`n", $utf8NoBom)

if (-not $allRequiredChecksPassed) {
    throw "Evidence analysis did not satisfy every required check; inspect $OutputPath"
}

$baselineKeyEvents = Read-Events -Path (Join-Path $EvidenceDir "handler-latency-baseline-run-01.log")
$blockedKeyEvents = Read-Events -Path (Join-Path $EvidenceDir "handler-latency-blocked-run-01.log")
$baselineH0b = Get-RequiredEvent -Events $baselineKeyEvents -Marker "H0B"
$baselineH1 = Get-RequiredEvent -Events $baselineKeyEvents -Marker "H1"
$baselineC1 = Get-RequiredEvent -Events $baselineKeyEvents -Marker "C1"
$blockedH0b = Get-RequiredEvent -Events $blockedKeyEvents -Marker "H0B"
$blockedH1 = Get-RequiredEvent -Events $blockedKeyEvents -Marker "H1"
$blockedC1 = Get-RequiredEvent -Events $blockedKeyEvents -Marker "C1"

$n1FirstEnter = Get-RequiredEventMatching `
    -Events $crossEvents `
    -Marker "S_ASYNC_WORKER_ENTER" `
    -RequiredFields @{ node = "N1"; requestId = "1001" }
$n2FirstEnter = Get-RequiredEventMatching `
    -Events $crossEvents `
    -Marker "S_ASYNC_WORKER_ENTER" `
    -RequiredFields @{ node = "N2"; requestId = "1003" }
$n1FirstExit = Get-RequiredEventMatching `
    -Events $crossEvents `
    -Marker "S_ASYNC_WORKER_EXIT" `
    -RequiredFields @{ node = "N1"; requestId = "1001" }
$n1SecondEnter = Get-RequiredEventMatching `
    -Events $crossEvents `
    -Marker "S_ASYNC_WORKER_ENTER" `
    -RequiredFields @{ node = "N1"; requestId = "1002" }
$n2FirstExit = Get-RequiredEventMatching `
    -Events $crossEvents `
    -Marker "S_ASYNC_WORKER_EXIT" `
    -RequiredFields @{ node = "N2"; requestId = "1003" }
$n2SecondEnter = Get-RequiredEventMatching `
    -Events $crossEvents `
    -Marker "S_ASYNC_WORKER_ENTER" `
    -RequiredFields @{ node = "N2"; requestId = "1004" }

$secondActive = $activeEvents[1]
$syncEvidenceOriginNs = $syncAtNs.callBegin
$crossEvidenceOriginNs = [long](@(
    $n1FirstInterval.BeginNs,
    $n2FirstInterval.BeginNs,
    [long](Get-Field -Event $n1SecondReturn -Name "atNs"),
    [long](Get-Field -Event $n2SecondReturn -Name "atNs")
) | Measure-Object -Minimum).Minimum
$keyEvidenceTemplatePath = Join-Path $PSScriptRoot "key-evidence.template"
if (-not (Test-Path -LiteralPath $keyEvidenceTemplatePath -PathType Leaf)) {
    throw "Missing key evidence template: $keyEvidenceTemplatePath"
}
$keyEvidenceContent = Get-Content `
    -LiteralPath $keyEvidenceTemplatePath `
    -Raw `
    -Encoding UTF8
$keyEvidenceReplacements = [ordered]@{
    "{{BASELINE_REQUEST_ID}}" = Get-Field -Event $baselineH0b -Name "requestId"
    "{{BASELINE_BLOCKER}}" = Get-Field -Event $baselineH0b -Name "injectHandlerBlocker"
    "{{BASELINE_POST_NS}}" = Get-Field -Event $baselineH0b -Name "postCallNs"
    "{{BASELINE_QUEUE_NS}}" = Get-Field -Event $baselineH1 -Name "queueNs"
    "{{BASELINE_COST_NS}}" = Get-Field -Event $baselineC1 -Name "costNs"
    "{{BLOCKED_REQUEST_ID}}" = Get-Field -Event $blockedH0b -Name "requestId"
    "{{BLOCKED_BLOCKER}}" = Get-Field -Event $blockedH0b -Name "injectHandlerBlocker"
    "{{BLOCKED_POST_NS}}" = Get-Field -Event $blockedH0b -Name "postCallNs"
    "{{BLOCKED_QUEUE_NS}}" = Get-Field -Event $blockedH1 -Name "queueNs"
    "{{BLOCKED_COST_NS}}" = Get-Field -Event $blockedC1 -Name "costNs"
    "{{SYNC_REQUEST_ID}}" = Get-Field -Event $syncBegin -Name "requestId"
    "{{SYNC_BEGIN_TID}}" = Get-Field -Event $syncBegin -Name "tid"
    "{{SYNC_BEGIN_OFFSET_NS}}" = $syncAtNs.callBegin - $syncEvidenceOriginNs
    "{{SYNC_BEFORE_REQUEST_ID}}" = Get-Field -Event $syncBeforeCallback -Name "requestId"
    "{{SYNC_BEFORE_OFFSET_NS}}" = $syncAtNs.beforeCallback - $syncEvidenceOriginNs
    "{{SYNC_CALLBACK_REQUEST_ID}}" = Get-Field -Event $syncCallback -Name "requestId"
    "{{SYNC_CALLBACK_TID}}" = Get-Field -Event $syncCallback -Name "tid"
    "{{SYNC_WAITING_TID}}" = Get-Field -Event $syncCallback -Name "waitingTid"
    "{{SYNC_CALLBACK_OFFSET_NS}}" = $syncAtNs.callback - $syncEvidenceOriginNs
    "{{SYNC_AFTER_REQUEST_ID}}" = Get-Field -Event $syncAfterCallback -Name "requestId"
    "{{SYNC_AFTER_OFFSET_NS}}" = $syncAtNs.afterCallback - $syncEvidenceOriginNs
    "{{SYNC_END_REQUEST_ID}}" = Get-Field -Event $syncEnd -Name "requestId"
    "{{SYNC_END_TID}}" = Get-Field -Event $syncEnd -Name "tid"
    "{{SYNC_END_OFFSET_NS}}" = $syncAtNs.callEnd - $syncEvidenceOriginNs
    "{{N1_SECOND_REQUEST_ID}}" = Get-Field -Event $n1SecondReturn -Name "requestId"
    "{{N1_SECOND_RETURN_OFFSET_NS}}" = `
        [long](Get-Field -Event $n1SecondReturn -Name "atNs") - $crossEvidenceOriginNs
    "{{N2_SECOND_REQUEST_ID}}" = Get-Field -Event $n2SecondReturn -Name "requestId"
    "{{N2_SECOND_RETURN_OFFSET_NS}}" = `
        [long](Get-Field -Event $n2SecondReturn -Name "atNs") - $crossEvidenceOriginNs
    "{{N1_FIRST_REQUEST_ID}}" = Get-Field -Event $n1FirstEnter -Name "requestId"
    "{{N1_FIRST_BEGIN_OFFSET_NS}}" = `
        [long](Get-Field -Event $n1FirstEnter -Name "begin") - $crossEvidenceOriginNs
    "{{N1_FIRST_TID}}" = Get-Field -Event $n1FirstEnter -Name "tid"
    "{{N2_FIRST_REQUEST_ID}}" = Get-Field -Event $n2FirstEnter -Name "requestId"
    "{{N2_FIRST_BEGIN_OFFSET_NS}}" = `
        [long](Get-Field -Event $n2FirstEnter -Name "begin") - $crossEvidenceOriginNs
    "{{N2_FIRST_TID}}" = Get-Field -Event $n2FirstEnter -Name "tid"
    "{{N1_FIRST_EXIT_REQUEST_ID}}" = Get-Field -Event $n1FirstExit -Name "requestId"
    "{{N1_FIRST_EXIT_END_OFFSET_NS}}" = `
        [long](Get-Field -Event $n1FirstExit -Name "end") - $crossEvidenceOriginNs
    "{{N1_SECOND_ENTER_REQUEST_ID}}" = Get-Field -Event $n1SecondEnter -Name "requestId"
    "{{N1_SECOND_ENTER_BEGIN_OFFSET_NS}}" = `
        [long](Get-Field -Event $n1SecondEnter -Name "begin") - $crossEvidenceOriginNs
    "{{N2_FIRST_EXIT_REQUEST_ID}}" = Get-Field -Event $n2FirstExit -Name "requestId"
    "{{N2_FIRST_EXIT_END_OFFSET_NS}}" = `
        [long](Get-Field -Event $n2FirstExit -Name "end") - $crossEvidenceOriginNs
    "{{N2_SECOND_ENTER_REQUEST_ID}}" = Get-Field -Event $n2SecondEnter -Name "requestId"
    "{{N2_SECOND_ENTER_BEGIN_OFFSET_NS}}" = `
        [long](Get-Field -Event $n2SecondEnter -Name "begin") - $crossEvidenceOriginNs
    "{{FIRST_PAIR_OVERLAP_NS}}" = $crossNode.firstPairOverlapNs
    "{{LAST_SUCCESS_REQUEST_ID}}" = Get-Field -Event $lastSuccessEnd -Name "requestId"
    "{{LAST_SUCCESS_RESULT}}" = Get-Field -Event $lastSuccessEnd -Name "result"
    "{{INVALID_CONNECTION_EPOCH}}" = Get-Field -Event $invalidEvent -Name "connectionEpoch"
    "{{INVALID_GENERATION_ID}}" = Get-Field -Event $invalidEvent -Name "generationId"
    "{{INVALID_OLD_STATE}}" = Get-Field -Event $invalidEvent -Name "oldState"
    "{{INVALID_WAS_CURRENT}}" = Get-Field -Event $invalidEvent -Name "wasCurrent"
    "{{INVALID_REASON}}" = Get-Field -Event $invalidEvent -Name "reason"
    "{{DEAD_OBJECT_GENERATION_ID}}" = Get-Field -Event $deadObjectEvent -Name "generationId"
    "{{DEAD_OBJECT_EXCEPTION}}" = Get-Field -Event $deadObjectEvent -Name "exception"
    "{{SECOND_CONNECTION_EPOCH}}" = Get-Field -Event $secondActive -Name "connectionEpoch"
    "{{SECOND_GENERATION_ID}}" = Get-Field -Event $secondActive -Name "generationId"
    "{{NOT_RESTARTED_GENERATION_ID}}" = Get-Field -Event $experimentNotRestarted -Name "generationId"
}
foreach ($placeholder in $keyEvidenceReplacements.Keys) {
    if (-not $keyEvidenceContent.Contains($placeholder)) {
        throw "Key evidence template is missing placeholder $placeholder"
    }
    $keyEvidenceContent = $keyEvidenceContent.Replace(
        $placeholder,
        $keyEvidenceReplacements[$placeholder].ToString())
}
if ($keyEvidenceContent -match '\{\{[A-Z0-9_]+\}\}') {
    throw "Key evidence template contains an unreplaced placeholder: $($Matches[0])"
}
$keyEvidenceContent = $keyEvidenceContent -replace "`r`n?", "`n"
if (-not $keyEvidenceContent.EndsWith("`n")) {
    $keyEvidenceContent += "`n"
}
$keyEvidenceParent = Split-Path -Parent ([System.IO.Path]::GetFullPath($KeyEvidencePath))
if (-not (Test-Path -LiteralPath $keyEvidenceParent -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $keyEvidenceParent | Out-Null
}
[System.IO.File]::WriteAllText(
    $KeyEvidencePath,
    $keyEvidenceContent,
    $utf8NoBom)

$analysis
