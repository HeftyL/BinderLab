param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "handler-latency-baseline",
        "handler-latency-blocked",
        "sync-reentry",
        "oneway-same-node",
        "oneway-cross-node",
        "async-callback",
        "binder-death"
    )]
    [string]$Mode,
    [string]$SdkRoot = $(if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { "D:\Android" }),
    [string]$OutputPath,
    [int]$TimeoutSeconds = 30,
    [string]$DeviceSerial,
    [switch]$SkipInstall
)

$ErrorActionPreference = "Stop"

$projectRoot = $PSScriptRoot
$adb = Join-Path $SdkRoot "platform-tools\adb.exe"
$apk = Join-Path $projectRoot "build\BinderLab-debug.apk"
$packageName = "com.example.binderdemo"
$component = "$packageName/.MainActivity"

foreach ($required in @($adb, $apk)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing experiment dependency: $required"
    }
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $projectRoot "build\run-logs\$Mode.log"
}
$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}

function Invoke-AdbChecked {
    param([string[]]$Arguments)

    [string[]]$effectiveArguments = if ([string]::IsNullOrWhiteSpace($DeviceSerial)) {
        [string[]]$Arguments
    } else {
        [string[]](@("-s", $DeviceSerial) + $Arguments)
    }
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $adb @effectiveArguments 2>&1 |
            ForEach-Object { $_.ToString() }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        $deviceLabel = if ([string]::IsNullOrWhiteSpace($DeviceSerial)) {
            "default-device"
        } else {
            "selected-device"
        }
        throw "adb[$deviceLabel] $($Arguments -join ' ') failed:`n$($output -join "`n")"
    }
    return @($output)
}

function Read-BinderLabLog {
    $lines = Invoke-AdbChecked -Arguments @(
        "logcat", "-d", "-v", "threadtime", "-s", "BinderLab:I", "*:S"
    )
    return ($lines -join "`n")
}

function Get-MarkerFields {
    param(
        [string]$Log,
        [string]$Marker
    )

    $pattern = '(?m)^.*BinderLab:\s+' `
        + [regex]::Escape($Marker) `
        + '\s+(?<detail>[^\r\n]*)$'
    $markerLines = [regex]::Matches($Log, $pattern)
    if ($markerLines.Count -eq 0) {
        return $null
    }
    $fields = [ordered]@{}
    $fieldPattern = '(?<key>[A-Za-z][A-Za-z0-9]*)=(?<value>.*?)(?=\s+[A-Za-z][A-Za-z0-9]*=|$)'
    foreach ($match in [regex]::Matches(
            $markerLines[$markerLines.Count - 1].Groups['detail'].Value,
            $fieldPattern)) {
        $key = $match.Groups['key'].Value
        if ($fields.Contains($key)) {
            throw "Duplicate field $key in terminal marker $Marker"
        }
        $fields[$key] = $match.Groups['value'].Value.Trim()
    }
    return $fields
}

function Test-TerminalMarker {
    param(
        [string]$Log,
        [string]$ExperimentMode
    )

    switch ($ExperimentMode) {
        { $_ -in @("handler-latency-baseline", "handler-latency-blocked") } {
            return $Log -match '\bC1\b.*requestId=\d+.*(?:result|error)='
        }
        "sync-reentry" {
            return $Log -match '\bC_SYNC_CALL_END\b.*requestId=\d+'
        }
        "oneway-same-node" {
            $release = Get-MarkerFields -Log $Log -Marker "C_ONEWAY_BURST_BEGIN"
            if ($null -eq $release -or
                    -not $release.Contains("requestIds") -or
                    $release.requestIds -notmatch '^(?<one>\d+),(?<two>\d+),(?<three>\d+)$') {
                return $false
            }
            foreach ($requestId in @($Matches.one, $Matches.two, $Matches.three)) {
                if ($Log -notmatch ("\bS_ONEWAY_EXIT\b.*requestId=" + $requestId + "\b")) {
                    return $false
                }
            }
            return $true
        }
        "oneway-cross-node" {
            $release = Get-MarkerFields -Log $Log -Marker "C_CROSS_NODE_RELEASE"
            if ($null -eq $release -or
                    -not $release.Contains("n1RequestIds") -or
                    -not $release.Contains("n2RequestIds") -or
                    $release.n1RequestIds -notmatch '^(?<one>\d+),(?<two>\d+)$') {
                return $false
            }
            $requestIds = @($Matches.one, $Matches.two)
            if ($release.n2RequestIds -notmatch '^(?<three>\d+),(?<four>\d+)$') {
                return $false
            }
            $requestIds += @($Matches.three, $Matches.four)
            foreach ($requestId in $requestIds) {
                if ($Log -notmatch ("\bS_ASYNC_WORKER_EXIT\b.*requestId=" + $requestId + "\b")) {
                    return $false
                }
            }
            return $true
        }
        "async-callback" {
            return $Log -match '\bC_ASYNC_CALLBACK_OBSERVED\b.*requestId=\d+'
        }
        "binder-death" {
            $activeCount = [regex]::Matches(
                $Log,
                '\bC_GENERATION_STATE\b.*newState=ACTIVE').Count
            $notRestartedCount = [regex]::Matches(
                $Log,
                '\bC_EXPERIMENT_NOT_RESTARTED\b').Count
            return $activeCount -eq 2 `
                    -and $notRestartedCount -eq 1 `
                    -and $Log -match '\bC_GENERATION_INVALID\b.*reason=binderDied' `
                    -and $Log -match '\bC_OLD_PROXY_DEAD_OBJECT\b' `
                    -and $Log -match '\bC_EXPERIMENT_NOT_RESTARTED\b'
        }
        default {
            return $false
        }
    }
}

function Wait-ForLogCondition {
    param(
        [scriptblock]$Condition,
        [string]$Description
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastLog = ""
    while ([DateTime]::UtcNow -lt $deadline) {
        $lastLog = Read-BinderLabLog
        if (& $Condition $lastLog) {
            return $lastLog
        }
        if ($lastLog -match '\b(?:C_CALL_FAILED|C_EXPERIMENT_INTERRUPTED|C_SERVICE_ERROR)\b' `
                -or $lastLog -match 'FATAL EXCEPTION') {
            throw "Experiment $Mode failed before $Description was observed:`n$lastLog"
        }
        Start-Sleep -Milliseconds 200
    }
    throw "Timed out after $TimeoutSeconds seconds waiting for ${Description}:`n$lastLog"
}

$state = (Invoke-AdbChecked -Arguments @("get-state") | Select-Object -Last 1).Trim()
if ($state -ne "device") {
    throw "adb device is not ready: $state"
}

if (-not $SkipInstall) {
    [void](Invoke-AdbChecked -Arguments @("install", "-r", $apk))
}

[void](Invoke-AdbChecked -Arguments @("shell", "am", "force-stop", $packageName))
[void](Invoke-AdbChecked -Arguments @("logcat", "-c"))
$startedAt = [DateTimeOffset]::Now
[void](Invoke-AdbChecked -Arguments @(
    "shell", "am", "start", "-W",
    "-n", $component,
    "--es", "experiment", $Mode
))

if ($Mode -eq "binder-death") {
    [void](Wait-ForLogCondition `
        -Description "C_DEATH_EXPERIMENT_ARMED" `
        -Condition { param($log) $log -match '\bC_DEATH_EXPERIMENT_ARMED\b' })

    $remotePid = (Invoke-AdbChecked -Arguments @(
        "shell", "pidof", "$packageName`:remote"
    ) | Select-Object -Last 1).Trim()
    if ($remotePid -notmatch '^\d+$') {
        throw "Could not resolve the remote process PID: $remotePid"
    }
    [void](Invoke-AdbChecked -Arguments @(
        "shell", "run-as", $packageName, "kill", "-9", $remotePid
    ))
}

$log = Wait-ForLogCondition `
    -Description "the terminal marker for $Mode" `
    -Condition { param($candidate) Test-TerminalMarker -Log $candidate -ExperimentMode $Mode }

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutputPath, $log + "`n", $utf8NoBom)

[pscustomobject]@{
    Mode = $Mode
    StartedAt = $startedAt.ToString("o")
    CompletedAt = [DateTimeOffset]::Now.ToString("o")
    OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path
    TerminalCondition = "passed"
}
