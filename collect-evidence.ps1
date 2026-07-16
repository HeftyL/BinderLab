param(
    [string]$SdkRoot = $(if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { "D:\Android" }),
    [string]$CompileSdkPlatform = "36.1",
    [string]$BuildToolsVersion = "36.0.0",
    [string]$EvidenceDir = (Join-Path $PSScriptRoot "evidence"),
    [string]$DeviceSerial,
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

if ($SkipBuild) {
    throw "Public evidence capture must rebuild the APK; -SkipBuild is not supported."
}

$projectRoot = $PSScriptRoot
$adb = Join-Path $SdkRoot "platform-tools\adb.exe"
$toolsDir = Join-Path $SdkRoot "build-tools\$BuildToolsVersion"
$aapt2 = Join-Path $toolsDir "aapt2.exe"
$apksigner = Join-Path $toolsDir "apksigner.bat"
$apk = Join-Path $projectRoot "build\BinderLab-debug.apk"
$packageName = "com.example.binderdemo"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$captureStartedAt = [DateTimeOffset]::Now
$captureId = "{0}-{1}" -f $captureStartedAt.ToString("yyyyMMddTHHmmssfff"), ([guid]::NewGuid().ToString("N").Substring(0, 12))

$evidencePath = [System.IO.Path]::GetFullPath($EvidenceDir)
$evidenceParent = Split-Path -Parent $evidencePath
$evidenceLeaf = Split-Path -Leaf $evidencePath
$stagingContainer = Join-Path $evidenceParent ".$evidenceLeaf-staging"
$stagingDir = Join-Path $stagingContainer $captureId
$backupDir = Join-Path $evidenceParent ".$evidenceLeaf-backup-$captureId"
$published = $false

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [object[]]$Lines
    )

    [System.IO.File]::WriteAllText(
        $Path,
        (($Lines | ForEach-Object { $_.ToString() }) -join "`n") + "`n",
        $utf8NoBom)
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

function Invoke-AdbCapture {
    param([string[]]$Arguments)

    [string[]]$effectiveArguments = if ([string]::IsNullOrWhiteSpace($DeviceSerial)) {
        [string[]]$Arguments
    } else {
        [string[]](@("-s", $DeviceSerial) + $Arguments)
    }
    return @(Invoke-NativeCapture `
        -Executable $adb `
        -Arguments $effectiveArguments)
}

function Assert-ChildDirectory {
    param(
        [string]$Path,
        [string]$Parent,
        [string]$Description
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
    $prefix = $fullParent + "\"
    if (-not $fullPath.StartsWith(
            $prefix,
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description escaped its expected parent: $fullPath"
    }
    return $fullPath
}

function Remove-SafeDirectory {
    param(
        [string]$Path,
        [string]$Parent,
        [string]$Description
    )

    $safePath = Assert-ChildDirectory -Path $Path -Parent $Parent -Description $Description
    if (Test-Path -LiteralPath $safePath -PathType Container) {
        Remove-Item -LiteralPath $safePath -Recurse -Force
    }
}

function Get-SourceManifestLines {
    [string[]]@(& (Join-Path $projectRoot "source-manifest.ps1") `
        -ProjectRoot $projectRoot |
        ForEach-Object { "$($_.Hash)  $($_.Path)" })
}

function Assert-SourceManifestUnchanged {
    param(
        [string[]]$Expected,
        [string]$Stage
    )

    [string[]]$current = @(Get-SourceManifestLines)
    if (($Expected -join "`n") -cne ($current -join "`n")) {
        throw "BinderLab source inputs changed after the capture snapshot ($Stage); refusing to publish evidence"
    }
}

foreach ($required in @($adb, $aapt2, $apksigner)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing evidence dependency: $required"
    }
}

if (-not (Test-Path -LiteralPath $evidenceParent -PathType Container)) {
    throw "Evidence parent directory does not exist: $evidenceParent"
}
[void](Assert-ChildDirectory -Path $stagingDir -Parent $evidenceParent -Description "Evidence staging directory")
[void](Assert-ChildDirectory -Path $backupDir -Parent $evidenceParent -Description "Evidence backup directory")

$residualPublicationPaths = New-Object System.Collections.Generic.List[string]
if (Test-Path -LiteralPath $stagingContainer) {
    $residualPublicationPaths.Add($stagingContainer)
}
Get-ChildItem `
    -LiteralPath $evidenceParent `
    -Directory `
    -Force `
    -Filter ".$evidenceLeaf-backup-*" | ForEach-Object {
        $residualPublicationPaths.Add($_.FullName)
    }
if ($residualPublicationPaths.Count -gt 0) {
    throw "Residual evidence staging/backup directories require manual recovery before a new capture:`n$($residualPublicationPaths -join "`n")"
}

$git = (Get-Command git.exe -ErrorAction Stop).Source
$gitRoot = (Invoke-NativeCapture -Executable $git -Arguments @(
    "-C", $projectRoot, "rev-parse", "--show-toplevel"
) | Select-Object -Last 1).Trim()
$gitCommit = (Invoke-NativeCapture -Executable $git -Arguments @(
    "-C", $gitRoot, "rev-parse", "HEAD"
) | Select-Object -Last 1).Trim()
$gitBranchOutput = @(Invoke-NativeCapture -Executable $git -Arguments @(
    "-C", $gitRoot, "branch", "--show-current"
))
$gitBranch = if ($gitBranchOutput.Count -eq 0) {
    "detached"
} else {
    ($gitBranchOutput | Select-Object -Last 1).Trim()
}
[string[]]$sourceManifestAtStart = @(Get-SourceManifestLines)
$gitStatusAtStart = @(Invoke-NativeCapture -Executable $git -Arguments @(
    "-C", $gitRoot, "status", "--porcelain=v1"
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$gitDirtyAtStart = $gitStatusAtStart.Count -gt 0
if ($gitDirtyAtStart) {
    throw "Public evidence capture requires a clean Git working tree; commit or remove all repository changes first.`n$($gitStatusAtStart -join "`n")"
}
Assert-SourceManifestUnchanged `
    -Expected $sourceManifestAtStart `
    -Stage "immediately before build"

try {
    & (Join-Path $projectRoot "build.ps1") `
        -SdkRoot $SdkRoot `
        -CompileSdkPlatform $CompileSdkPlatform `
        -BuildToolsVersion $BuildToolsVersion
    if ($LASTEXITCODE -ne 0) {
        throw "BinderLab build failed"
    }
    if (-not (Test-Path -LiteralPath $apk -PathType Leaf)) {
        throw "Missing APK: $apk"
    }

    New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null
    $evidenceReadme = Join-Path $evidencePath "README.md"
    if (-not (Test-Path -LiteralPath $evidenceReadme -PathType Leaf)) {
        throw "Missing evidence README template: $evidenceReadme"
    }
    Copy-Item `
        -LiteralPath $evidenceReadme `
        -Destination (Join-Path $stagingDir "README.md")

    $state = (Invoke-AdbCapture -Arguments @("get-state") |
        Select-Object -Last 1).Trim()
    if ($state -ne "device") {
        throw "adb device is not ready: $state"
    }
    [void](Invoke-AdbCapture -Arguments @("install", "-r", $apk))

    function Read-DeviceValue {
        param([string[]]$Arguments)

        return (Invoke-AdbCapture -Arguments $Arguments |
            Select-Object -Last 1).Trim()
    }

    $androidVersion = Read-DeviceValue -Arguments @(
        "shell", "getprop", "ro.build.version.release"
    )
    $apiLevel = Read-DeviceValue -Arguments @(
        "shell", "getprop", "ro.build.version.sdk"
    )
    $buildType = Read-DeviceValue -Arguments @(
        "shell", "getprop", "ro.build.type"
    )
    $kernelRelease = Read-DeviceValue -Arguments @("shell", "uname", "-r")
    $kernelVersion = if ($kernelRelease -match '^(?<major>\d+)\.(?<minor>\d+)') {
        "$($Matches.major).$($Matches.minor)"
    } else {
        "redacted"
    }
    $deviceDate = Read-DeviceValue -Arguments @(
        "shell", "date", "+%Y-%m-%dT%H:%M:%S%z"
    )
    $deviceTimeZone = Read-DeviceValue -Arguments @(
        "shell", "getprop", "persist.sys.timezone"
    )
    if ([string]::IsNullOrWhiteSpace($deviceTimeZone)) {
        $deviceTimeZone = "not-reported"
    }
    $deviceUptime = Read-DeviceValue -Arguments @(
        "shell", "cat", "/proc/uptime"
    )
    $deviceElapsedRealtimeSeconds = ($deviceUptime -split '\s+')[0]
    $hostOffset = $captureStartedAt.ToString("zzz")

    $deviceLines = @(
        "captureId=$captureId"
        "hostCapturedAt=$($captureStartedAt.ToString('o'))"
        "hostTimeZoneId=$([System.TimeZoneInfo]::Local.Id)"
        "hostUtcOffset=$hostOffset"
        "deviceDate=$deviceDate"
        "deviceTimeZone=$deviceTimeZone"
        "deviceElapsedRealtimeSeconds=$deviceElapsedRealtimeSeconds"
        "adbState=$state"
        "AndroidVersion=$androidVersion"
        "ApiLevel=$apiLevel"
        "BuildType=$buildType"
        "KernelVersion=$kernelVersion"
        "Model=redacted"
        "Fingerprint=redacted"
        "Carrier=redacted"
        "deviceAlias=device-01"
        "serialHash=not-recorded"
    )
    Write-Utf8NoBom -Path (Join-Path $stagingDir "device.txt") -Lines $deviceLines

    $serviceList = Invoke-AdbCapture -Arguments @(
        "shell", "service", "list"
    )
    $activityService = @($serviceList | Where-Object {
        $_ -match '^\d+\s+activity:\s+\[android\.app\.IActivityManager\]'
    })
    if ($activityService.Count -ne 1) {
        throw "Expected exactly one activity service entry, found $($activityService.Count)"
    }
    $serviceManagerLines = @(
        "command=adb shell service check activity"
        Invoke-AdbCapture -Arguments @(
            "shell", "service", "check", "activity"
        )
        ""
        "command=adb shell service list (activity entry only)"
        $activityService[0]
        ""
        "command=adb shell dumpsys --pid activity"
        Invoke-AdbCapture -Arguments @(
            "shell", "dumpsys", "--pid", "activity"
        )
    )
    Write-Utf8NoBom `
        -Path (Join-Path $stagingDir "service-manager.txt") `
        -Lines $serviceManagerLines

    $toolchainLines = @(
        Get-Content `
            -LiteralPath (Join-Path $projectRoot "build\toolchain.txt") `
            -Encoding UTF8
        "platformPackage=$((Get-Content -LiteralPath (Join-Path $SdkRoot "platforms\android-$CompileSdkPlatform\source.properties") -Encoding UTF8 | Where-Object { $_ -match '^Pkg\.(Revision|Desc)=' }) -join '; ')"
        Invoke-NativeCapture -Executable $adb -Arguments @("version")
    )
    Write-Utf8NoBom `
        -Path (Join-Path $stagingDir "toolchain.txt") `
        -Lines $toolchainLines

    $apkHash = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).
        Hash.ToLowerInvariant()
    $badgingLines = @(
        "apkFile=BinderLab-debug.apk"
        "apkSha256=$apkHash"
        Invoke-NativeCapture -Executable $aapt2 -Arguments @(
            "dump", "badging", $apk
        )
    )
    Write-Utf8NoBom `
        -Path (Join-Path $stagingDir "apk-badging.txt") `
        -Lines $badgingLines

    $signatureLines = Invoke-NativeCapture `
        -Executable $apksigner `
        -Arguments @("verify", "--verbose", "--print-certs", $apk)
    Write-Utf8NoBom `
        -Path (Join-Path $stagingDir "apk-signature.txt") `
        -Lines $signatureLines

    $deviceSerialArgument = if ([string]::IsNullOrWhiteSpace($DeviceSerial)) {
        ""
    } else {
        " -DeviceSerial '<deviceSerial>'"
    }
    $adbSerialArgument = if ([string]::IsNullOrWhiteSpace($DeviceSerial)) {
        ""
    } else {
        "-s '<deviceSerial>' "
    }
    $commandLines = @(
        "# Commands used for this evidence package."
        "# The public metadata intentionally omits the adb serial and product identity."
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -SdkRoot '$SdkRoot' -CompileSdkPlatform '$CompileSdkPlatform' -BuildToolsVersion '$BuildToolsVersion'"
        "& '$adb' ${adbSerialArgument}install -r .\build\BinderLab-debug.apk"
        ""
        "# run-experiment.ps1 performs force-stop, logcat -c, am start -W, then polls the mode-specific terminal marker."
    )
    $modes = @(
        "sync-reentry",
        "oneway-same-node",
        "oneway-cross-node",
        "async-callback",
        "binder-death"
    )
    $handlerModeNames = @(
        "handler-latency-baseline",
        "handler-latency-blocked"
    )
    $handlerRuns = New-Object System.Collections.Generic.List[object]
    foreach ($handlerMode in $handlerModeNames) {
        for ($run = 1; $run -le 5; $run++) {
            $handlerRuns.Add([pscustomobject]@{
                Mode = $handlerMode
                File = ("{0}-run-{1:d2}.log" -f $handlerMode, $run)
            })
        }
    }
    $handlerFiles = @($handlerRuns | ForEach-Object { $_.File })
    foreach ($handlerRun in $handlerRuns) {
        $commandLines += "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run-experiment.ps1 -Mode '$($handlerRun.Mode)' -SdkRoot '$SdkRoot'$deviceSerialArgument -OutputPath '.\evidence\$($handlerRun.File)' -SkipInstall"
    }
    foreach ($mode in $modes) {
        $commandLines += "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run-experiment.ps1 -Mode '$mode' -SdkRoot '$SdkRoot'$deviceSerialArgument -OutputPath '.\evidence\$mode.log' -SkipInstall"
    }
    $commandLines += @(
        ""
        "# binder-death additionally resolves only the remote PID, then runs:"
        "& '$adb' ${adbSerialArgument}shell run-as $packageName kill -9 `<remotePid`>"
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\analyze-evidence.ps1 -CaptureId '$captureId' -CaptureStartedAt '$($captureStartedAt.ToString('o'))'"
    )
    Write-Utf8NoBom `
        -Path (Join-Path $stagingDir "commands.txt") `
        -Lines $commandLines

    foreach ($handlerRun in $handlerRuns) {
        & (Join-Path $projectRoot "run-experiment.ps1") `
            -Mode $handlerRun.Mode `
            -SdkRoot $SdkRoot `
            -DeviceSerial $DeviceSerial `
            -OutputPath (Join-Path $stagingDir $handlerRun.File) `
            -SkipInstall
        if ($LASTEXITCODE -ne 0) {
            throw "Evidence collection failed for $($handlerRun.File)"
        }
    }

    foreach ($mode in $modes) {
        & (Join-Path $projectRoot "run-experiment.ps1") `
            -Mode $mode `
            -SdkRoot $SdkRoot `
            -DeviceSerial $DeviceSerial `
            -OutputPath (Join-Path $stagingDir "$mode.log") `
            -SkipInstall
        if ($LASTEXITCODE -ne 0) {
            throw "Evidence collection failed for $mode"
        }
    }

    & (Join-Path $projectRoot "analyze-evidence.ps1") `
        -EvidenceDir $stagingDir `
        -OutputPath (Join-Path $stagingDir "analysis.json") `
        -CaptureId $captureId `
        -CaptureStartedAt ($captureStartedAt.ToString("o")) `
        -AnalysisMode Capture | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Evidence analysis failed"
    }

    Assert-SourceManifestUnchanged `
        -Expected $sourceManifestAtStart `
        -Stage "after build, device runs, and analysis"
    $sourceManifestPath = Join-Path $stagingDir "source-manifest.sha256"
    Write-Utf8NoBom `
        -Path $sourceManifestPath `
        -Lines $sourceManifestAtStart
    $sourceManifestHash = (Get-FileHash `
        -LiteralPath $sourceManifestPath `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    $captureCompletedAt = [DateTimeOffset]::Now
    $analysisJson = Get-Content `
        -LiteralPath (Join-Path $stagingDir "analysis.json") `
        -Raw `
        -Encoding UTF8
    $analysisCaptureId = Get-JsonPlainStringProperty `
        -Json $analysisJson `
        -PropertyName "captureId" `
        -Description "analysis.captureId"
    $analysisMode = Get-JsonPlainStringProperty `
        -Json $analysisJson `
        -PropertyName "analysisMode" `
        -Description "analysis.analysisMode"
    $analysisCaptureStartedAt = Get-JsonPlainStringProperty `
        -Json $analysisJson `
        -PropertyName "captureStartedAt" `
        -Description "analysis.captureStartedAt"
    $analysisGeneratedAtText = Get-JsonPlainStringProperty `
        -Json $analysisJson `
        -PropertyName "generatedAt" `
        -Description "analysis.generatedAt"
    try {
        $analysisGeneratedAt = [DateTimeOffset]::ParseExact(
            $analysisGeneratedAtText,
            "o",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None)
    } catch {
        throw "analysis.generatedAt is not a round-trip ISO-8601 timestamp: $analysisGeneratedAtText"
    }
    if ($analysisMode -cne "capture" -or
            $analysisCaptureId -cne $captureId -or
            $analysisCaptureStartedAt -cne $captureStartedAt.ToString("o")) {
        throw "analysis capture metadata does not match the active capture"
    }
    if ($analysisGeneratedAt -le $captureStartedAt -or
            $analysisGeneratedAt -ge $captureCompletedAt) {
        throw "analysis.generatedAt must fall strictly inside the capture interval"
    }
    $sourceLines = @(
        "captureId=$captureId"
        "captureStartedAt=$($captureStartedAt.ToString('o'))"
        "captureCompletedAt=$($captureCompletedAt.ToString('o'))"
        "gitCommit=$gitCommit"
        "gitBranch=$gitBranch"
        "gitDirty=$($gitDirtyAtStart.ToString().ToLowerInvariant())"
        "gitDirtyScope=repository-at-capture-start"
        "sourceManifestSha256=$sourceManifestHash"
        "apkSha256=$apkHash"
    )
    Write-Utf8NoBom `
        -Path (Join-Path $stagingDir "source.txt") `
        -Lines $sourceLines

    $evidenceManifestPath = Join-Path $stagingDir "evidence-manifest.sha256"
    $evidenceManifestLines = @(Get-ChildItem -LiteralPath $stagingDir -File |
        Where-Object { $_.Name -ne "evidence-manifest.sha256" } |
        Sort-Object Name |
        ForEach-Object {
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).
                Hash.ToLowerInvariant()
            "$hash  $($_.Name)"
        })
    Write-Utf8NoBom `
        -Path $evidenceManifestPath `
        -Lines $evidenceManifestLines

    $expectedFiles = @(
        "analysis.json",
        "apk-badging.txt",
        "apk-signature.txt",
        "async-callback.log",
        "binder-death.log",
        "commands.txt",
        "device.txt",
        "evidence-manifest.sha256"
    ) + $handlerFiles + @(
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
    $actualFiles = @(Get-ChildItem -LiteralPath $stagingDir -File |
        ForEach-Object { $_.Name } |
        Sort-Object)
    if (($expectedFiles -join "`n") -ne ($actualFiles -join "`n")) {
        throw "Evidence file set is incomplete or contains extras.`nExpected:`n$($expectedFiles -join "`n")`nActual:`n$($actualFiles -join "`n")"
    }

    Assert-SourceManifestUnchanged `
        -Expected $sourceManifestAtStart `
        -Stage "immediately before publication"
    $gitCommitBeforePublish = (Invoke-NativeCapture -Executable $git -Arguments @(
        "-C", $gitRoot, "rev-parse", "HEAD"
    ) | Select-Object -Last 1).Trim()
    if ($gitCommitBeforePublish -ne $gitCommit) {
        throw "Git HEAD changed during evidence capture; refusing to publish evidence"
    }
    $gitBranchBeforePublishOutput = @(Invoke-NativeCapture -Executable $git -Arguments @(
        "-C", $gitRoot, "branch", "--show-current"
    ))
    $gitBranchBeforePublish = if ($gitBranchBeforePublishOutput.Count -eq 0) {
        "detached"
    } else {
        ($gitBranchBeforePublishOutput | Select-Object -Last 1).Trim()
    }
    if ($gitBranchBeforePublish -ne $gitBranch) {
        throw "Git branch changed during evidence capture; refusing to publish evidence"
    }

    if (Test-Path -LiteralPath $backupDir) {
        throw "Refusing to overwrite evidence backup: $backupDir"
    }
    if (Test-Path -LiteralPath $evidencePath -PathType Container) {
        [System.IO.Directory]::Move($evidencePath, $backupDir)
    }
    try {
        [System.IO.Directory]::Move($stagingDir, $evidencePath)
        $published = $true
    } catch {
        if ((Test-Path -LiteralPath $backupDir -PathType Container) -and
                -not (Test-Path -LiteralPath $evidencePath)) {
            [System.IO.Directory]::Move($backupDir, $evidencePath)
        }
        throw
    }
    if (Test-Path -LiteralPath $backupDir -PathType Container) {
        Remove-SafeDirectory `
            -Path $backupDir `
            -Parent $evidenceParent `
            -Description "Evidence backup cleanup"
    }

    [void](Invoke-AdbCapture -Arguments @(
        "shell", "am", "force-stop", $packageName
    ))

    [pscustomobject]@{
        EvidenceDir = $evidencePath
        CaptureId = $captureId
        DeviceApi = $apiLevel
        BuildTools = $BuildToolsVersion
        ApkSha256 = $apkHash
        GitCommit = $gitCommit
        GitDirty = $gitDirtyAtStart
        Modes = $modes.Count + $handlerModeNames.Count
        HandlerRuns = $handlerFiles.Count
        Analysis = "passed"
        EvidenceManifest = "passed"
        PublishedTransactionally = $published
    }
} finally {
    if (-not $published -and (Test-Path -LiteralPath $stagingDir)) {
        Remove-SafeDirectory `
            -Path $stagingDir `
            -Parent $evidenceParent `
            -Description "Failed evidence staging cleanup"
    }
    if ((Test-Path -LiteralPath $stagingContainer -PathType Container) -and
            @(Get-ChildItem -LiteralPath $stagingContainer -Force).Count -eq 0) {
        Remove-Item -LiteralPath $stagingContainer -Force
    }
}
