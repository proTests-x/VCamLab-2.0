[CmdletBinding()]
param(
    [string]$Mode = "Obs",
    [string]$Source = "",
    [string]$Orientation = "",
    [string]$Resolution = "",
    [string]$Quality = "",
    [string]$FramesPerSecond = "",
    [string]$Port = "",
    [string]$BindAddress = "",
    [string]$FfmpegPath = "",
    [string]$ObsPath = "",
    [string]$Scene = "",
    [string]$ObsWaitSeconds = "",
    [string]$RestartOnDisconnect = "",
    [string]$DeviceName = "",
    [string]$ScaleMode = "",
    [string]$RealtimeBufferMB = "",
    [string]$ThreadQueueSize = "",
    [string]$EncoderThreads = "",
    [string]$OutputQueueSize = "",
    [string]$TcpSendBufferMB = "",
    [string]$RequireObsModeMatch = "",
    [string]$AutoRefreshObsVirtualCamera = "",
    [string]$FfmpegLogLevel = "",
    [string]$Transport = "",
    [string]$HlsSegmentSeconds = "",
    [string]$HlsListSize = "",
    [string]$HlsVideoBitrateKbps = "",
    [string]$HlsMaxrateKbps = "",
    [string]$HlsBufsizeKbps = "",
    [string]$HlsPreset = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$script:VCamBridgeMutex = $null
$script:VCamBridgeMutexHeld = $false
$obsWebSocketHelpers = Join-Path $PSScriptRoot "obs-websocket.ps1"
if (Test-Path -LiteralPath $obsWebSocketHelpers -PathType Leaf) {
    . $obsWebSocketHelpers
}

function Write-VcamStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $color = switch ($Level) {
        "OK" { "Green" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host ("[{0}] {1}" -f $Level, $Message) -ForegroundColor $color
}

function Stop-Vcam {
    param(
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$Message
    )
    Write-VcamStatus -Level "ERROR" -Message $Message
    exit $ExitCode
}

function Enter-VcamBridgeMutex {
    param([Parameter(Mandatory = $true)][int]$ListenPort)
    $mutexName = "Local\VirtualCamProBridge-$ListenPort"
    $script:VCamBridgeMutex = [Threading.Mutex]::new($false, $mutexName)
    try {
        $script:VCamBridgeMutexHeld = $script:VCamBridgeMutex.WaitOne(0)
    } catch [Threading.AbandonedMutexException] {
        $script:VCamBridgeMutexHeld = $true
    }
    if (-not $script:VCamBridgeMutexHeld) {
        $script:VCamBridgeMutex.Dispose()
        $script:VCamBridgeMutex = $null
        Stop-Vcam -ExitCode 4 -Message (
            "Another VirtualCamPro bridge already owns TCP port $ListenPort. " +
            "Use its existing window or stop it before starting another copy."
        )
    }
}

function Get-VcamSetting {
    param(
        [string]$ExplicitValue,
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$DefaultValue
    )
    if (-not [string]::IsNullOrWhiteSpace($ExplicitValue)) {
        return $ExplicitValue.Trim()
    }
    $environmentValue = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if (-not [string]::IsNullOrWhiteSpace($environmentValue)) {
        return $environmentValue.Trim()
    }
    return $DefaultValue
}

function ConvertTo-VcamInteger {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Minimum,
        [Parameter(Mandatory = $true)][int]$Maximum
    )
    $parsed = 0
    $valid = [int]::TryParse(
        $Value,
        [Globalization.NumberStyles]::Integer,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsed
    )
    if (-not $valid -or $parsed -lt $Minimum -or $parsed -gt $Maximum) {
        Stop-Vcam -ExitCode 64 -Message (
            "{0} must be an integer from {1} through {2}; received '{3}'." -f
            $Name, $Minimum, $Maximum, $Value
        )
    }
    return $parsed
}

function ConvertTo-VcamFrameRate {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][double]$Minimum,
        [Parameter(Mandatory = $true)][double]$Maximum
    )
    $text = $Value.Trim()
    $parsed = 0.0
    $fraction = [regex]::Match(
        $text,
        '^(?<numerator>[0-9]+(?:[.][0-9]+)?)/(?<denominator>[0-9]+(?:[.][0-9]+)?)$'
    )
    if ($fraction.Success) {
        $numerator = 0.0
        $denominator = 0.0
        $validNumerator = [double]::TryParse(
            $fraction.Groups["numerator"].Value,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$numerator
        )
        $validDenominator = [double]::TryParse(
            $fraction.Groups["denominator"].Value,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$denominator
        )
        if ($validNumerator -and $validDenominator -and $denominator -gt 0) {
            $parsed = $numerator / $denominator
        } else {
            $parsed = [double]::NaN
        }
    } else {
        $valid = [double]::TryParse(
            $text,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed
        )
        if (-not $valid) { $parsed = [double]::NaN }
    }
    if ([double]::IsNaN($parsed) -or [double]::IsInfinity($parsed) -or
        $parsed -lt $Minimum -or $parsed -gt $Maximum) {
        Stop-Vcam -ExitCode 64 -Message ((
            "{0} must be from {1} through {2}, using a decimal such as 29.97 " +
            "or a fraction such as 30000/1001; received '{3}'."
        ) -f $Name, $Minimum, $Maximum, $Value)
    }
    return [double]$parsed
}

function Format-VcamFrameRate {
    param([Parameter(Mandatory = $true)][double]$Value)
    return $Value.ToString("0.######", [Globalization.CultureInfo]::InvariantCulture)
}

function Get-VcamAdaptiveQueueSettings {
    param(
        [Parameter(Mandatory = $true)][double]$FPS,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $true)][int]$RealtimeBufferMinimum,
        [Parameter(Mandatory = $true)][int]$PacketQueueMinimum,
        [Parameter(Mandatory = $true)][int]$NetworkQueueMinimum
    )
    # Absorb ordinary scheduler/Wi-Fi bursts without turning the bridge into a
    # seconds-long stale-frame queue. The FIFO still drops the oldest overflow
    # under sustained backpressure, preserving real-time recovery.
    $packetQueue = [Math]::Max(
        $PacketQueueMinimum,
        [Math]::Min(60, [int][Math]::Ceiling($FPS * 0.25))
    )
    $networkQueue = [Math]::Max(
        $NetworkQueueMinimum,
        [Math]::Min(36, [int][Math]::Ceiling($FPS * 0.15))
    )
    # Roughly 250 ms at two bytes/pixel, capped to avoid a hidden long queue.
    $rawBurstMiB = [Math]::Ceiling(
        ([double]$Width * [double]$Height * $FPS * 0.50) / 1MB
    )
    $realtimeBuffer = [Math]::Max(
        $RealtimeBufferMinimum,
        [Math]::Min(256, [int]$rawBurstMiB)
    )
    return [pscustomobject]@{
        RealtimeBuffer = [int]$realtimeBuffer
        PacketQueue = [int]$packetQueue
        NetworkQueue = [int]$networkQueue
    }
}

function Test-VcamFrameRateMatch {
    param(
        [Parameter(Mandatory = $true)][double]$Actual,
        [Parameter(Mandatory = $true)][double]$Requested
    )
    return [Math]::Abs($Actual - $Requested) -le 0.01
}

function ConvertFrom-VcamIniText {
    param([Parameter(Mandatory = $true)][string]$Text)
    $values = @{}
    $section = ""
    foreach ($rawLine in [regex]::Split($Text, "`r?`n")) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or
            $line.StartsWith(";") -or $line.StartsWith("#")) { continue }
        $sectionMatch = [regex]::Match($line, '^\[(?<name>[^\]]+)\]$')
        if ($sectionMatch.Success) {
            $section = $sectionMatch.Groups["name"].Value.Trim()
            continue
        }
        $separator = $line.IndexOf('=')
        if ($separator -le 0) { continue }
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        $values["$section.$key"] = $value
    }
    return $values
}

function Get-VcamObsSavedVideoSettings {
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) { return $null }
    $userConfigPath = Join-Path $env:APPDATA "obs-studio\user.ini"
    if (-not (Test-Path -LiteralPath $userConfigPath -PathType Leaf)) { return $null }
    try {
        $userValues = ConvertFrom-VcamIniText -Text (
            Get-Content -LiteralPath $userConfigPath -Raw -Encoding UTF8
        )
        $profileDirectory = [string]$userValues["Basic.ProfileDir"]
        $profileName = [string]$userValues["Basic.Profile"]
        if ([string]::IsNullOrWhiteSpace($profileDirectory) -or
            [IO.Path]::GetFileName($profileDirectory) -ne $profileDirectory -or
            $profileDirectory -in @(".", "..")) { return $null }
        $profilePath = Join-Path $env:APPDATA (
            "obs-studio\basic\profiles\{0}\basic.ini" -f $profileDirectory
        )
        if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) { return $null }
        $profileValues = ConvertFrom-VcamIniText -Text (
            Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8
        )
        $baseWidth = ConvertTo-VcamInteger -Value ([string]$profileValues["Video.BaseCX"]) `
            -Name "OBS base width" -Minimum 16 -Maximum 8192
        $baseHeight = ConvertTo-VcamInteger -Value ([string]$profileValues["Video.BaseCY"]) `
            -Name "OBS base height" -Minimum 16 -Maximum 8192
        $outputWidth = ConvertTo-VcamInteger -Value ([string]$profileValues["Video.OutputCX"]) `
            -Name "OBS output width" -Minimum 16 -Maximum 8192
        $outputHeight = ConvertTo-VcamInteger -Value ([string]$profileValues["Video.OutputCY"]) `
            -Name "OBS output height" -Minimum 16 -Maximum 8192
        $fpsType = ConvertTo-VcamInteger -Value ([string]$profileValues["Video.FPSType"]) `
            -Name "OBS FPS type" -Minimum 0 -Maximum 2
        $fpsExpression = switch ($fpsType) {
            0 { [string]$profileValues["Video.FPSCommon"] }
            1 { [string]$profileValues["Video.FPSInt"] }
            2 {
                "{0}/{1}" -f $profileValues["Video.FPSNum"],
                    $profileValues["Video.FPSDen"]
            }
        }
        $fps = ConvertTo-VcamFrameRate -Value $fpsExpression -Name "OBS saved frame rate" `
            -Minimum 1 -Maximum 240
        return [pscustomobject]@{
            ProfileName = $(if ([string]::IsNullOrWhiteSpace($profileName)) {
                $profileDirectory
            } else { $profileName })
            ProfileDirectory = $profileDirectory
            ProfilePath = $profilePath
            BaseWidth = $baseWidth
            BaseHeight = $baseHeight
            OutputWidth = $outputWidth
            OutputHeight = $outputHeight
            FPS = $fps
            FPSExpression = $fpsExpression
            LastWriteTimeUtc = (Get-Item -LiteralPath $profilePath).LastWriteTimeUtc
        }
    } catch {
        Write-VcamStatus -Level "WARN" -Message (
            "Could not read the saved OBS video profile: {0}" -f $_.Exception.Message
        )
        return $null
    }
}

function ConvertTo-VcamBoolean {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )
    switch ($Value.Trim().ToLowerInvariant()) {
        { $_ -in @("1", "true", "yes", "on") } { return $true }
        { $_ -in @("0", "false", "no", "off") } { return $false }
        default {
            Stop-Vcam -ExitCode 64 -Message (
                "{0} must be true/false, yes/no, on/off, or 1/0; received '{1}'." -f
                $Name, $Value
            )
        }
    }
}

function Get-VcamCanvas {
    param(
        [Parameter(Mandatory = $true)][string]$Preset,
        [Parameter(Mandatory = $true)][string]$CanvasOrientation
    )
    $dimensions = switch ($Preset.ToLowerInvariant()) {
        "720p" { @(1280, 720) }
        "1080p" { @(1920, 1080) }
        "1440p" { @(2560, 1440) }
        "2160p" { @(3840, 2160) }
        default {
            Stop-Vcam -ExitCode 64 -Message (
                "Resolution must be 720p, 1080p, 1440p, or 2160p; received '{0}'." -f $Preset
            )
        }
    }
    if ($CanvasOrientation -eq "portrait") {
        return [pscustomobject]@{ Width = $dimensions[1]; Height = $dimensions[0] }
    }
    return [pscustomobject]@{ Width = $dimensions[0]; Height = $dimensions[1] }
}

function New-VcamVideoFilter {
    param(
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $true)][double]$FPS,
        [Parameter(Mandatory = $true)][string]$ScaleMode
    )
    $geometryFilter = switch ($ScaleMode) {
        "fill" {
            "scale={0}:{1}:flags=lanczos:force_original_aspect_ratio=increase," +
            "crop={0}:{1}"
        }
        "fit" {
            "scale={0}:{1}:flags=lanczos:force_original_aspect_ratio=decrease," +
            "pad={0}:{1}:(ow-iw)/2:(oh-ih)/2"
        }
        "stretch" { "scale={0}:{1}:flags=lanczos" }
        default {
            Stop-Vcam -ExitCode 64 -Message "Scale mode must be fill, fit, or stretch."
        }
    }
    return ("fps={0}:round=near,{1},setsar=1" -f
        (Format-VcamFrameRate -Value $FPS), ($geometryFilter -f $Width, $Height))
}

function ConvertFrom-VcamObsModeListing {
    param([string[]]$Lines)
    $modes = New-Object Collections.Generic.List[object]
    $seen = @{}
    foreach ($line in $Lines) {
        $match = [regex]::Match(
            [string]$line,
            'pixel_format=(?<format>\S+)\s+min s=(?<width>\d+)x(?<height>\d+)\s+fps=(?<fps>[0-9.]+)',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if (-not $match.Success) { continue }
        $fps = 0.0
        if (-not [double]::TryParse(
                $match.Groups["fps"].Value,
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$fps)) { continue }
        $mode = [pscustomobject]@{
            PixelFormat = $match.Groups["format"].Value.ToLowerInvariant()
            Width = [int]$match.Groups["width"].Value
            Height = [int]$match.Groups["height"].Value
            FPS = $fps
        }
        $key = "{0}|{1}|{2}|{3}" -f
            $mode.PixelFormat, $mode.Width, $mode.Height,
            $mode.FPS.ToString("0.####", [Globalization.CultureInfo]::InvariantCulture)
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $modes.Add($mode)
    }
    return @($modes | ForEach-Object { $_ })
}

function Get-VcamObsVideoModes {
    param(
        [Parameter(Mandatory = $true)][string]$Ffmpeg,
        [Parameter(Mandatory = $true)][string]$CaptureDevice
    )
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $listing = & $Ffmpeg -hide_banner -list_options true -f dshow `
            -i ("video={0}" -f $CaptureDevice) 2>&1 |
            ForEach-Object { $_.ToString() }
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return @(ConvertFrom-VcamObsModeListing -Lines $listing)
}

function Select-VcamObsVideoMode {
    param(
        [object[]]$Modes,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $true)][double]$FPS,
        [Parameter(Mandatory = $true)][bool]$RequireExact
    )
    $dimensionMatches = @($Modes | Where-Object {
        $_.Width -eq $Width -and $_.Height -eq $Height
    })
    $rateMatches = @($dimensionMatches | Where-Object {
        Test-VcamFrameRateMatch -Actual $_.FPS -Requested $FPS
    })
    $preferred = @($rateMatches | Sort-Object `
        @{ Expression = { if ($_.PixelFormat -eq "nv12") { 0 } else { 1 } } }, `
        @{ Expression = { [Math]::Abs($_.FPS - $FPS) } }) | Select-Object -First 1
    if ($preferred) { return $preferred }
    if ($RequireExact) { return $null }

    $fallback = @($Modes | Sort-Object `
        @{ Expression = { if ($_.PixelFormat -eq "nv12") { 0 } else { 1 } } }, `
        @{ Expression = { [Math]::Abs(($_.Width * $_.Height) - ($Width * $Height)) } }, `
        @{ Expression = { [Math]::Abs($_.FPS - $FPS) } }) | Select-Object -First 1
    return $fallback
}

function Format-VcamObsVideoModes {
    param([object[]]$Modes)
    if (-not $Modes -or $Modes.Count -eq 0) { return "none reported" }
    return (($Modes | ForEach-Object {
        "{0}x{1}@{2} {3}" -f $_.Width, $_.Height,
            (Format-VcamFrameRate -Value $_.FPS),
            $_.PixelFormat
    } | Sort-Object -Unique) -join ", ")
}

function Get-VcamObsSceneWarnings {
    $warnings = New-Object Collections.Generic.List[string]
    try {
        if ([string]::IsNullOrWhiteSpace($env:APPDATA)) { return @() }
        $userConfig = Join-Path $env:APPDATA "obs-studio\user.ini"
        if (-not (Test-Path -LiteralPath $userConfig -PathType Leaf)) { return @() }
        $configText = Get-Content -LiteralPath $userConfig -Raw -Encoding UTF8
        $collectionMatch = [regex]::Match(
            $configText,
            '(?m)^SceneCollectionFile=(?<file>[^\r\n]+)$'
        )
        if (-not $collectionMatch.Success) { return @() }
        $collectionFile = $collectionMatch.Groups["file"].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($collectionFile) -or
            [IO.Path]::GetFileName($collectionFile) -ne $collectionFile) { return @() }
        $collectionPath = Join-Path $env:APPDATA (
            "obs-studio\basic\scenes\{0}" -f $collectionFile
        )
        if (-not (Test-Path -LiteralPath $collectionPath -PathType Leaf)) { return @() }
        $collection = Get-Content -LiteralPath $collectionPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        $sceneName = [string]$collection.current_program_scene
        if ([string]::IsNullOrWhiteSpace($sceneName)) {
            $sceneName = [string]$collection.current_scene
        }
        $scene = $collection.sources | Where-Object {
            $_.id -eq "scene" -and $_.name -eq $sceneName
        } | Select-Object -First 1
        if (-not $scene) { return @() }

        $sourcesByUuid = @{}
        foreach ($source in $collection.sources) {
            if ($source.uuid) { $sourcesByUuid[[string]$source.uuid] = $source }
        }
        foreach ($item in $scene.settings.items) {
            if (-not $item.visible) { continue }
            $source = $null
            if ($item.source_uuid -and $sourcesByUuid.ContainsKey([string]$item.source_uuid)) {
                $source = $sourcesByUuid[[string]$item.source_uuid]
            }
            if (-not $source) {
                $source = $collection.sources | Where-Object {
                    $_.name -eq $item.name
                } | Select-Object -First 1
            }
            if ($source -and $source.id -eq "image_source" -and
                [int]$item.bounds_type -eq 0) {
                $warnings.Add((
                    "Visible OBS image source '{0}' uses a free transform, so it will not auto-fill " +
                    "a resized canvas. In OBS use Transform > Edit Transform > Bounds Type " +
                    "'Scale to outer bounds' and set bounds to the canvas size."
                ) -f $item.name)
            }
        }
    } catch {
        $warnings.Add("Could not inspect the active OBS scene layout: $($_.Exception.Message)")
    }
    return @($warnings | ForEach-Object { $_ })
}

function Test-VcamInterruptedExitCode {
    param([Parameter(Mandatory = $true)][int]$ExitCode)
    return $ExitCode -in @(130, 255, -1073741510)
}

function Resolve-VcamExecutable {
    param(
        [string]$ConfiguredPath,
        [Parameter(Mandatory = $true)][string]$CommandName,
        [string[]]$CommonPaths = @(),
        [Parameter(Mandatory = $true)][string]$InstallHint
    )
    if (-not [string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        $expandedPath = [Environment]::ExpandEnvironmentVariables($ConfiguredPath.Trim().Trim('"'))
        if (-not (Test-Path -LiteralPath $expandedPath -PathType Leaf)) {
            Stop-Vcam -ExitCode 3 -Message (
                "Configured {0} path does not exist: {1}" -f $CommandName, $expandedPath
            )
        }
        return (Resolve-Path -LiteralPath $expandedPath).Path
    }

    foreach ($candidate in $CommonPaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    Stop-Vcam -ExitCode 3 -Message ("{0} was not found. {1}" -f $CommandName, $InstallHint)
}

function Get-VcamPortOwner {
    param([Parameter(Mandatory = $true)][int]$ListenPort)
    $listeners = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    if (-not ($listeners | Where-Object { $_.Port -eq $ListenPort } | Select-Object -First 1)) {
        return $null
    }

    $description = "another process"
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $connection = Get-NetTCPConnection -LocalPort $ListenPort -State Listen -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($connection) {
            $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
            if ($process) {
                $description = "{0} (PID {1})" -f $process.ProcessName, $connection.OwningProcess
            } else {
                $description = "PID {0}" -f $connection.OwningProcess
            }
        }
    }
    return $description
}

function Test-VcamPrivateIPv4 {
    param([Parameter(Mandatory = $true)][Net.IPAddress]$Address)
    $bytes = $Address.GetAddressBytes()
    return $bytes[0] -eq 10 -or
        ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
}

function Get-VcamLanAddresses {
    $addresses = New-Object Collections.Generic.List[object]
    foreach ($networkInterface in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($networkInterface.OperationalStatus -ne [Net.NetworkInformation.OperationalStatus]::Up) { continue }
        if ($networkInterface.NetworkInterfaceType -in @(
                [Net.NetworkInformation.NetworkInterfaceType]::Loopback,
                [Net.NetworkInformation.NetworkInterfaceType]::Tunnel
            )) { continue }
        foreach ($unicast in $networkInterface.GetIPProperties().UnicastAddresses) {
            $address = $unicast.Address
            if ($address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { continue }
            $text = $address.ToString()
            if ($text.StartsWith("127.") -or $text.StartsWith("169.254.")) { continue }
            $addresses.Add([pscustomobject]@{
                Address = $text
                Private = Test-VcamPrivateIPv4 -Address $address
                Interface = $networkInterface.Name
            })
        }
    }
    return @($addresses | Sort-Object @{ Expression = "Private"; Descending = $true }, Address -Unique)
}

function Show-VcamEndpoints {
    param(
        [Parameter(Mandatory = $true)][int]$ListenPort,
        [Parameter(Mandatory = $true)][string]$ListenerAddress,
        [Parameter(Mandatory = $true)][string]$EndpointPath,
        [Parameter(Mandatory = $true)][string]$TransportName
    )
    if ($ListenerAddress -ne "0.0.0.0") {
        Write-Host ("Listener URL ({0}): http://{1}:{2}/{3}" -f
            $TransportName, $ListenerAddress, $ListenPort, $EndpointPath)
        if ($ListenerAddress.StartsWith("127.")) {
            Write-VcamStatus -Level "WARN" -Message (
                "The listener is bound to loopback and is not reachable from a phone over Wi-Fi."
            )
        }
        return
    }
    $addresses = @(Get-VcamLanAddresses)
    if ($addresses.Count -eq 0) {
        Write-VcamStatus -Level "WARN" -Message "No active LAN IPv4 address was found."
        return
    }
    Write-Host ("Phone URL candidates ({0}):" -f $TransportName)
    foreach ($entry in $addresses) {
        $suffix = if ($entry.Private) { "" } else { " (VPN/public; verify reachability)" }
        Write-Host ("  http://{0}:{1}/{2}  [{3}]{4}" -f
            $entry.Address, $ListenPort, $EndpointPath, $entry.Interface, $suffix)
    }
}

function Test-VcamFfmpegEncoder {
    param(
        [Parameter(Mandatory = $true)][string]$Ffmpeg,
        [Parameter(Mandatory = $true)][string]$Encoder
    )
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $listing = & $Ffmpeg -hide_banner -encoders 2>&1 | ForEach-Object { $_.ToString() }
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return (($listing -join "`n") -match ("(?im)^\s*V\S*\s+{0}\s" -f [regex]::Escape($Encoder)))
}

function Measure-VcamMjpegEncoderCapacity {
    param(
        [Parameter(Mandatory = $true)][string]$Ffmpeg,
        [Parameter(Mandatory = $true)][ValidateSet("mjpeg", "mjpeg_qsv")][string]$Encoder,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $true)][double]$FPS,
        [Parameter(Mandatory = $true)][int]$Quality,
        [Parameter(Mandatory = $true)][int]$Threads,
        [ValidateSet("optimal", "default")][string]$Huffman = "optimal"
    )
    # Benchmark the complete system-memory upload/encode path. Encoder listing
    # alone is insufficient: FFmpeg builds often expose QSV on machines whose
    # active driver cannot create a hardware session.
    $frameCount = [Math]::Max(30, [Math]::Min(180, [int][Math]::Ceiling($FPS * 1.5)))
    $rateText = Format-VcamFrameRate -Value $FPS
    $encoderArguments = if ($Encoder -eq "mjpeg_qsv") {
        @("-c:v", "mjpeg_qsv", "-pix_fmt", "nv12", "-global_quality", [string]$Quality,
          "-async_depth", "4")
    } else {
        @("-c:v", "mjpeg", "-threads", [string]$Threads, "-pix_fmt", "yuvj420p",
          "-q:v", [string]$Quality, "-huffman", $Huffman)
    }
    $arguments = @(
        "-hide_banner", "-loglevel", "info",
        "-f", "lavfi", "-i", ("testsrc2=size={0}x{1}:rate={2}" -f $Width, $Height, $rateText),
        "-frames:v", [string]$frameCount, "-an"
    ) + $encoderArguments + @("-f", "null", "-")
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Ffmpeg
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = (($arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"{0}"' -f ($_ -replace '"', '\"') } else { $_ }
    }) -join ' ')
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw "process did not start" }
        $standardError = $process.StandardError.ReadToEnd()
        $null = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        $stopwatch.Stop()
        $exitCode = $process.ExitCode
        $process.Dispose()
    } catch {
        $stopwatch.Stop()
        return [pscustomobject]@{
            Available = $false; Encoder = $Encoder; Huffman = $Huffman
            RealtimeFactor = 0.0; EstimatedMbps = 0.0; Error = $_.Exception.Message
        }
    }
    if ($exitCode -ne 0 -or $stopwatch.Elapsed.TotalSeconds -le 0) {
        $lastError = (($standardError -split "`r?`n") |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Last 1)
        return [pscustomobject]@{
            Available = $false; Encoder = $Encoder; Huffman = $Huffman
            RealtimeFactor = 0.0; EstimatedMbps = 0.0; Error = [string]$lastError
        }
    }
    $encodedFPS = $frameCount / $stopwatch.Elapsed.TotalSeconds
    $sizeMatch = [regex]::Match($standardError, 'video:\s*(?<kib>[0-9]+)KiB')
    $estimatedMbps = 0.0
    if ($sizeMatch.Success) {
        $encodedKiB = [double]$sizeMatch.Groups["kib"].Value
        $mediaSeconds = $frameCount / $FPS
        $estimatedMbps = ($encodedKiB * 1024.0 * 8.0) / ($mediaSeconds * 1000000.0)
    }
    return [pscustomobject]@{
        Available = $true
        Encoder = $Encoder
        Huffman = $Huffman
        RealtimeFactor = [double]($encodedFPS / $FPS)
        EstimatedMbps = [double]$estimatedMbps
        Error = ""
    }
}

function Select-VcamMjpegEncoderProfile {
    param(
        [Parameter(Mandatory = $true)][string]$Ffmpeg,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $true)][double]$FPS,
        [Parameter(Mandatory = $true)][int]$Quality,
        [Parameter(Mandatory = $true)][int]$Threads
    )
    $software = Measure-VcamMjpegEncoderCapacity -Ffmpeg $Ffmpeg -Encoder "mjpeg" `
        -Width $Width -Height $Height -FPS $FPS -Quality $Quality -Threads $Threads `
        -Huffman "optimal"
    if (-not $software.Available) {
        return [pscustomobject]@{
            Encoder = "mjpeg"; Huffman = "optimal"; Capacity = $software
            SoftwareCapacity = $software; HardwareCapacity = $null
        }
    }
    if ($software.RealtimeFactor -lt 1.5) {
        $defaultTables = Measure-VcamMjpegEncoderCapacity -Ffmpeg $Ffmpeg -Encoder "mjpeg" `
            -Width $Width -Height $Height -FPS $FPS -Quality $Quality -Threads $Threads `
            -Huffman "default"
        if ($defaultTables.Available -and
            $defaultTables.RealtimeFactor -ge $software.RealtimeFactor * 1.10) {
            $software = $defaultTables
        }
    }

    $hardware = $null
    if (Test-VcamFfmpegEncoder -Ffmpeg $Ffmpeg -Encoder "mjpeg_qsv") {
        $hardware = Measure-VcamMjpegEncoderCapacity -Ffmpeg $Ffmpeg -Encoder "mjpeg_qsv" `
            -Width $Width -Height $Height -FPS $FPS -Quality $Quality -Threads $Threads
    }
    $useHardware = $hardware -and $hardware.Available -and
        ($hardware.RealtimeFactor -ge 2.0 -or
         ($software.RealtimeFactor -lt 1.5 -and $hardware.RealtimeFactor -gt $software.RealtimeFactor))
    $selected = if ($useHardware) { $hardware } else { $software }
    return [pscustomobject]@{
        Encoder = $selected.Encoder
        Huffman = $selected.Huffman
        Capacity = $selected
        SoftwareCapacity = $software
        HardwareCapacity = $hardware
    }
}

function Wait-VcamTcpListener {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutSeconds = 5
    )
    $connectAddress = if ($Address -eq "0.0.0.0") { "127.0.0.1" } else { $Address }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $client = New-Object Net.Sockets.TcpClient
        try {
            $task = $client.ConnectAsync($connectAddress, $Port)
            if ($task.Wait(350) -and $client.Connected) { return $true }
        } catch {
        } finally {
            $client.Dispose()
        }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Start-VcamHlsServer {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$BindAddress,
        [Parameter(Mandatory = $true)][int]$Port
    )
    $serverScript = Join-Path $PSScriptRoot "hls-server.ps1"
    if (-not (Test-Path -LiteralPath $serverScript -PathType Leaf)) {
        Stop-Vcam -ExitCode 70 -Message "HLS HTTP server helper is missing: $serverScript"
    }
    $powershell = Join-Path $PSHOME "powershell.exe"
    if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) {
        $powershell = "powershell.exe"
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershell
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.Arguments = (
        '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -RootPath "{1}" ' +
        '-BindAddress "{2}" -Port {3} -PlaylistName "live.m3u8"'
    ) -f $serverScript, $RootPath, $BindAddress, $Port
    try {
        $process = [Diagnostics.Process]::Start($startInfo)
        if (-not $process) {
            Stop-Vcam -ExitCode 70 -Message "Could not start the HLS HTTP server."
        }
        if (-not (Wait-VcamTcpListener -Address $BindAddress -Port $Port -TimeoutSeconds 5)) {
            $process.Refresh()
            $state = if ($process.HasExited) {
                " The server process exited with code $($process.ExitCode)."
            } else { "" }
            try { if (-not $process.HasExited) { $process.Kill() } } catch {}
            $process.Dispose()
            Stop-Vcam -ExitCode 4 -Message (
                "HLS HTTP server did not begin listening on ${BindAddress}:$Port.$state"
            )
        }
        return $process
    } catch {
        Stop-Vcam -ExitCode 70 -Message ("Failed to start HLS HTTP server: {0}" -f $_.Exception.Message)
    }
}

function Stop-VcamChildProcess {
    param([object]$Process)
    if (-not $Process) { return }
    try {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            $Process.Kill()
            [void]$Process.WaitForExit(3000)
        }
    } catch {
    } finally {
        try { $Process.Dispose() } catch {}
    }
}

function Test-VcamObsDeviceRegistered {
    param(
        [Parameter(Mandatory = $true)][string]$Ffmpeg,
        [Parameter(Mandatory = $true)][string]$CaptureDevice
    )
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $listing = & $Ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 |
            ForEach-Object { $_.ToString() }
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return (($listing -join "`n").IndexOf($CaptureDevice,
        [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Test-VcamObsFrame {
    param(
        [Parameter(Mandatory = $true)][string]$Ffmpeg,
        [Parameter(Mandatory = $true)][string]$CaptureDevice,
        [int]$TimeoutSeconds = 3
    )
    if ($CaptureDevice.Contains('"')) { return $false }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Ffmpeg
    $startInfo.Arguments = (
        '-hide_banner -loglevel error -f dshow -rtbufsize 32M -i video="{0}" ' +
        '-frames:v 1 -f null -'
    ) -f $CaptureDevice
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { return $false }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            $process.WaitForExit()
            $stdoutTask.Wait()
            $stderrTask.Wait()
            return $false
        }
        $stdoutTask.Wait()
        $stderrTask.Wait()
        return $process.ExitCode -eq 0
    } catch {
        return $false
    } finally {
        $process.Dispose()
    }
}

function Wait-VcamObsFrame {
    param(
        [Parameter(Mandatory = $true)][string]$Ffmpeg,
        [Parameter(Mandatory = $true)][string]$CaptureDevice,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (Test-VcamObsFrame -Ffmpeg $Ffmpeg -CaptureDevice $CaptureDevice -TimeoutSeconds 2) {
            return $true
        }
        Start-Sleep -Milliseconds 750
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Start-VcamObs {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [AllowEmptyString()][string]$SelectedScene
    )
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.WorkingDirectory = Split-Path -Parent $Executable
    $startInfo.UseShellExecute = $false
    $startInfo.Arguments = "--startvirtualcam"
    if (-not [string]::IsNullOrWhiteSpace($SelectedScene)) {
        $startInfo.Arguments += ' --scene "' + $SelectedScene + '"'
    }
    try {
        $process = [Diagnostics.Process]::Start($startInfo)
        if (-not $process) { return $false }
        $process.Dispose()
        return $true
    } catch {
        Write-VcamStatus -Level "WARN" -Message ("OBS launch failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Request-VcamObsVirtualCameraRecovery {
    param(
        [switch]$Restart,
        [int]$TimeoutSeconds = 5
    )
    if (-not (Get-Command Invoke-VcamObsVirtualCameraControl -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Available = $false
            Success = $false
            Reason = "OBS WebSocket control helper is unavailable."
            Responses = @{}
        }
    }
    $action = if ($Restart) { "refreshing" } else { "starting" }
    Write-VcamStatus -Level "INFO" -Message (
        "OBS is already running; {0} Virtual Camera through the local authenticated control interface..." -f
        $action
    )
    $result = Invoke-VcamObsVirtualCameraControl -Restart:$Restart `
        -TimeoutSeconds $TimeoutSeconds
    if ($result.Success) {
        Write-VcamStatus -Level "OK" -Message "OBS Virtual Camera control request completed."
    } else {
        Write-VcamStatus -Level "WARN" -Message $result.Reason
    }
    return $result
}

function Test-VcamFileSource {
    param(
        [Parameter(Mandatory = $true)][string]$Ffmpeg,
        [Parameter(Mandatory = $true)][string]$InputPath
    )
    $ffprobe = Join-Path (Split-Path -Parent $Ffmpeg) "ffprobe.exe"
    if (-not (Test-Path -LiteralPath $ffprobe -PathType Leaf)) {
        $command = Get-Command ffprobe.exe -ErrorAction SilentlyContinue
        if ($command) { $ffprobe = $command.Source }
    }
    if (-not (Test-Path -LiteralPath $ffprobe -PathType Leaf)) {
        Stop-Vcam -ExitCode 3 -Message "ffprobe.exe was not found next to FFmpeg or in PATH."
    }

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $streamIndex = & $ffprobe -v error -select_streams v:0 `
            -show_entries stream=index -of csv=p=0 -- $InputPath 2>$null |
            Select-Object -First 1
        $probeExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($probeExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$streamIndex)) {
        Stop-Vcam -ExitCode 2 -Message "The input file does not contain a readable video stream: $InputPath"
    }
}

function New-VcamFfmpegArguments {
    param(
        [Parameter(Mandatory = $true)][string]$InputSource,
        [Parameter(Mandatory = $true)][int]$CanvasWidth,
        [Parameter(Mandatory = $true)][int]$CanvasHeight,
        [Parameter(Mandatory = $true)][double]$OutputFPS,
        [Parameter(Mandatory = $true)][string]$OutputScaleMode,
        [Parameter(Mandatory = $true)][int]$OutputQuality,
        [Parameter(Mandatory = $true)][string]$ListenerURL,
        [Parameter(Mandatory = $true)][string]$CaptureDevice,
        [object]$ObsMode,
        [Parameter(Mandatory = $true)][int]$RealtimeBuffer,
        [Parameter(Mandatory = $true)][int]$PacketQueueSize,
        [Parameter(Mandatory = $true)][int]$MjpegEncoderThreads,
        [Parameter(Mandatory = $true)][int]$NetworkQueueSize,
        [Parameter(Mandatory = $true)][int]$NetworkSendBufferMB,
        [Parameter(Mandatory = $true)][string]$LogLevel,
        [string]$Transport = "mjpeg",
        [string]$OutputPath = "",
        [double]$HlsSegmentDuration = 0.25,
        [int]$HlsPlaylistSize = 6,
        [int]$HlsBitrateKbps = 12000,
        [int]$HlsPeakBitrateKbps = 16000,
        [int]$HlsBufferKbps = 12000,
        [string]$HlsEncoderPreset = "ultrafast",
        [ValidateSet("optimal", "default")][string]$MjpegHuffman = "optimal",
        [ValidateSet("mjpeg", "mjpeg_qsv")][string]$MjpegEncoder = "mjpeg"
    )
    $normalizedTransport = $Transport.Trim().ToLowerInvariant()
    if ($normalizedTransport -notin @("mjpeg", "hls")) {
        Stop-Vcam -ExitCode 64 -Message "Transport must be mjpeg or hls."
    }

    $exactObsRate = $InputSource -eq "obs" -and $ObsMode -and
        (Test-VcamFrameRateMatch -Actual $ObsMode.FPS -Requested $OutputFPS)
    $filter = if ($exactObsRate -and $ObsMode.Width -eq $CanvasWidth -and
        $ObsMode.Height -eq $CanvasHeight) {
        "setsar=1"
    } else {
        $requestedFilter = New-VcamVideoFilter -Width $CanvasWidth -Height $CanvasHeight `
            -FPS $OutputFPS -ScaleMode $OutputScaleMode
        if ($exactObsRate) {
            $requestedFilter -replace '^fps=[^,]+,', ''
        } else {
            $requestedFilter
        }
    }

    $inputArguments = if ($InputSource -eq "obs") {
        if (-not $ObsMode) {
            Stop-Vcam -ExitCode 70 -Message "Cannot build OBS arguments without an active video mode."
        }
        $captureFPS = if (Test-VcamFrameRateMatch -Actual $ObsMode.FPS `
                -Requested $OutputFPS) { $OutputFPS } else { [double]$ObsMode.FPS }
        @(
            "-fflags", "nobuffer+discardcorrupt",
            "-use_wallclock_as_timestamps", "1",
            "-f", "dshow",
            "-rtbufsize", ("{0}M" -f $RealtimeBuffer),
            "-thread_queue_size", [string]$PacketQueueSize,
            "-video_size", ("{0}x{1}" -f $ObsMode.Width, $ObsMode.Height),
            "-framerate", (Format-VcamFrameRate -Value $captureFPS),
            "-pixel_format", $ObsMode.PixelFormat,
            "-i", ("video={0}" -f $CaptureDevice)
        )
    } else {
        @("-re", "-stream_loop", "-1", "-i", $InputSource)
    }

    $commonPrefix = @(
        "-hide_banner",
        "-loglevel", $LogLevel,
        "-map", "0:v:0",
        "-an", "-sn", "-dn",
        "-vf", $filter
    )

    if ($normalizedTransport -eq "mjpeg") {
        $encoderArguments = if ($MjpegEncoder -eq "mjpeg_qsv") {
            @(
                "-c:v", "mjpeg_qsv",
                "-pix_fmt", "nv12",
                "-global_quality", [string]$OutputQuality,
                "-async_depth", "4"
            )
        } else {
            @(
                "-c:v", "mjpeg",
                "-threads", [string]$MjpegEncoderThreads,
                "-pix_fmt", "yuvj420p",
                "-q:v", [string]$OutputQuality,
                "-huffman", $MjpegHuffman
            )
        }
        $outputArguments = @($encoderArguments + @(
            "-fps_mode", "passthrough",
            "-flush_packets", "1",
            "-f", "fifo",
            "-fifo_format", "mpjpeg",
            "-queue_size", [string]$NetworkQueueSize,
            "-drop_pkts_on_overflow", "1",
            "-format_opts", (("listen=1:flush_packets=1:send_buffer_size={0}:" +
                "tcp_nodelay=1:" +
                "content_type=multipart/x-mixed-replace;boundary=ffmpeg") -f ($NetworkSendBufferMB * 1MB)),
            $ListenerURL
        ))
        return @($inputArguments + $commonPrefix + $outputArguments)
    }

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        Stop-Vcam -ExitCode 70 -Message "HLS output path is required."
    }
    $segmentDirectory = Split-Path -Parent $OutputPath
    if ([string]::IsNullOrWhiteSpace($segmentDirectory)) {
        Stop-Vcam -ExitCode 70 -Message "HLS output directory is invalid."
    }
    $segmentPattern = Join-Path $segmentDirectory "segment_%06d.ts"
    $segmentText = $HlsSegmentDuration.ToString("0.###", [Globalization.CultureInfo]::InvariantCulture)
    $keyFrameInterval = [Math]::Max(1, [int][Math]::Round($OutputFPS * $HlsSegmentDuration))
    $outputArguments = @(
        "-c:v", "libx264",
        "-preset", $HlsEncoderPreset,
        "-tune", "zerolatency",
        "-bf", "0",
        "-refs", "1",
        "-pix_fmt", "yuv420p",
        "-b:v", ("{0}k" -f $HlsBitrateKbps),
        "-maxrate", ("{0}k" -f $HlsPeakBitrateKbps),
        "-bufsize", ("{0}k" -f $HlsBufferKbps),
        "-g", [string]$keyFrameInterval,
        "-keyint_min", [string]$keyFrameInterval,
        "-sc_threshold", "0",
        "-force_key_frames", ("expr:gte(t,n_forced*{0})" -f $segmentText),
        "-fps_mode", "cfr",
        "-r", (Format-VcamFrameRate -Value $OutputFPS),
        "-muxdelay", "0",
        "-muxpreload", "0",
        "-f", "hls",
        "-hls_time", $segmentText,
        "-hls_list_size", [string]$HlsPlaylistSize,
        "-hls_delete_threshold", "2",
        "-hls_flags", "delete_segments+independent_segments+omit_endlist+temp_file+program_date_time",
        "-hls_segment_filename", $segmentPattern,
        $OutputPath
    )
    return @($inputArguments + $commonPrefix + $outputArguments)
}

function Invoke-VcamSelfTest {
    $landscape = Get-VcamCanvas -Preset "1080p" -CanvasOrientation "landscape"
    $portrait = Get-VcamCanvas -Preset "720p" -CanvasOrientation "portrait"
    if ($landscape.Width -ne 1920 -or $landscape.Height -ne 1080) {
        Stop-Vcam -ExitCode 70 -Message "Landscape resolution self-test failed."
    }
    if ($portrait.Width -ne 720 -or $portrait.Height -ne 1280) {
        Stop-Vcam -ExitCode 70 -Message "Portrait resolution self-test failed."
    }
    $fillFilter = New-VcamVideoFilter -Width 1920 -Height 1080 -FPS 29.97 -ScaleMode "fill"
    $fitFilter = New-VcamVideoFilter -Width 1920 -Height 1080 -FPS 30 -ScaleMode "fit"
    if ($fillFilter -notlike "fps=29.97:round=near,scale=1920:1080:flags=lanczos*increase,crop=1920:1080*") {
        Stop-Vcam -ExitCode 70 -Message "Fill-filter construction self-test failed."
    }
    if ($fitFilter -notlike "fps=30:round=near,scale=1920:1080:flags=lanczos*decrease,pad=1920:1080*") {
        Stop-Vcam -ExitCode 70 -Message "Fit-filter construction self-test failed."
    }
    if ((ConvertTo-VcamInteger -Value "31" -Name "quality" -Minimum 1 -Maximum 31) -ne 31) {
        Stop-Vcam -ExitCode 70 -Message "Integer validation self-test failed."
    }
    $decimalFPS = ConvertTo-VcamFrameRate -Value "29.97" -Name "frame rate" `
        -Minimum 1 -Maximum 240
    $fractionalFPS = ConvertTo-VcamFrameRate -Value "30000/1001" -Name "frame rate" `
        -Minimum 1 -Maximum 240
    $highFPS = ConvertTo-VcamFrameRate -Value "240" -Name "frame rate" `
        -Minimum 1 -Maximum 240
    if ([Math]::Abs($decimalFPS - 29.97) -gt 0.000001 -or
        [Math]::Abs($fractionalFPS - 29.97002997) -gt 0.000001 -or
        $highFPS -ne 240) {
        Stop-Vcam -ExitCode 70 -Message "Custom frame-rate parsing self-test failed."
    }
    $adaptiveQueues = Get-VcamAdaptiveQueueSettings -FPS $highFPS `
        -Width 1920 -Height 1080 -RealtimeBufferMinimum 64 `
        -PacketQueueMinimum 4 -NetworkQueueMinimum 3
    if ($adaptiveQueues.RealtimeBuffer -ne 238 -or
        $adaptiveQueues.PacketQueue -ne 60 -or
        $adaptiveQueues.NetworkQueue -ne 36) {
        Stop-Vcam -ExitCode 70 -Message "High frame-rate queue scaling self-test failed."
    }
    $sampleIni = ConvertFrom-VcamIniText -Text @"
[Basic]
ProfileDir=Custom Profile
[Video]
BaseCX=1920
BaseCY=1080
FPSType=2
FPSNum=30000
FPSDen=1001
"@
    if ($sampleIni["Basic.ProfileDir"] -ne "Custom Profile" -or
        $sampleIni["Video.BaseCX"] -ne "1920" -or
        $sampleIni["Video.FPSNum"] -ne "30000") {
        Stop-Vcam -ExitCode 70 -Message "OBS INI parsing self-test failed."
    }
    if (-not (ConvertTo-VcamBoolean -Value "yes" -Name "restart")) {
        Stop-Vcam -ExitCode 70 -Message "Boolean validation self-test failed."
    }
    $privateAddress = [Net.IPAddress]::Parse("192.168.1.10")
    $publicAddress = [Net.IPAddress]::Parse("8.8.8.8")
    if (-not (Test-VcamPrivateIPv4 -Address $privateAddress) -or
        (Test-VcamPrivateIPv4 -Address $publicAddress)) {
        Stop-Vcam -ExitCode 70 -Message "IPv4 classification self-test failed."
    }
    $sampleModes = @(ConvertFrom-VcamObsModeListing -Lines @(
        'pixel_format=nv12 min s=1920x1080 fps=30.0003 max s=1920x1080 fps=30.0003',
        'pixel_format=yuv420p min s=1920x1080 fps=30.0003 max s=1920x1080 fps=30.0003',
        'pixel_format=nv12 min s=1920x1080 fps=29.9700 max s=1920x1080 fps=29.9700',
        'pixel_format=nv12 min s=1020x1344 fps=60.0002 max s=1020x1344 fps=60.0002'
    ))
    $selectedMode = Select-VcamObsVideoMode -Modes $sampleModes `
        -Width 1920 -Height 1080 -FPS $fractionalFPS -RequireExact $true
    if (-not $selectedMode -or $selectedMode.PixelFormat -ne "nv12" -or
        $selectedMode.Width -ne 1920 -or
        -not (Test-VcamFrameRateMatch -Actual $selectedMode.FPS -Requested $fractionalFPS)) {
        Stop-Vcam -ExitCode 70 -Message "OBS mode parsing and selection self-test failed."
    }
    $integerMode = Select-VcamObsVideoMode -Modes $sampleModes `
        -Width 1920 -Height 1080 -FPS 30 -RequireExact $true
    if (-not $integerMode -or [Math]::Abs($integerMode.FPS - 30.0003) -gt 0.000001) {
        Stop-Vcam -ExitCode 70 -Message "Integer frame-rate mode matching self-test failed."
    }
    $argumentTest = @(New-VcamFfmpegArguments -InputSource "obs" `
        -CanvasWidth 1920 -CanvasHeight 1080 -OutputFPS $fractionalFPS `
        -OutputScaleMode "fill" -OutputQuality 5 `
        -ListenerURL "http://127.0.0.1:18888/live.mjpg" `
        -CaptureDevice "OBS Virtual Camera" -ObsMode $selectedMode `
        -RealtimeBuffer 256 -PacketQueueSize 32 `
        -MjpegEncoderThreads 4 -NetworkQueueSize 64 `
        -NetworkSendBufferMB 4 -LogLevel "error" -MjpegHuffman "default")
    $argumentText = $argumentTest -join "`n"
    if ($argumentText -like "*fps=*" -or
        $argumentText -notlike "*-vf`nsetsar=1*" -or
        $argumentText -like "*scale=1920:1080*" -or
        $argumentText -notlike "*-loglevel`nerror*" -or
        $argumentText -like "*-flags`nlow_delay*" -or
        $argumentText -notlike "*-fps_mode`npassthrough*" -or
        $argumentText -notlike "*-huffman`ndefault*" -or
        $argumentText -notlike "*-threads`n4*" -or
        $argumentText -notlike "*-fifo_format`nmpjpeg*" -or
        $argumentText -notlike "*-drop_pkts_on_overflow`n1*" -or
        $argumentText -notlike "*-format_opts`nlisten=1:flush_packets=1:send_buffer_size=4194304:tcp_nodelay=1:content_type=multipart/x-mixed-replace;boundary=ffmpeg*" -or
        $argumentText -like "*tcp_keepalive*" -or
        $argumentTest -notcontains "1920x1080" -or
        $argumentTest -notcontains "nv12") {
        Stop-Vcam -ExitCode 70 -Message "Dynamic FFmpeg argument self-test failed."
    }
    $integerArgumentTest = @(New-VcamFfmpegArguments -InputSource "obs" `
        -CanvasWidth 1920 -CanvasHeight 1080 -OutputFPS 30 `
        -OutputScaleMode "fill" -OutputQuality 5 `
        -ListenerURL "http://127.0.0.1:18888/live.mjpg" `
        -CaptureDevice "OBS Virtual Camera" -ObsMode $integerMode `
        -RealtimeBuffer 256 -PacketQueueSize 32 `
        -MjpegEncoderThreads 4 -NetworkQueueSize 64 `
        -NetworkSendBufferMB 4 -LogLevel "error")
    $frameRateIndex = [Array]::IndexOf($integerArgumentTest, "-framerate")
    if ($frameRateIndex -lt 0 -or $integerArgumentTest[$frameRateIndex + 1] -ne "30") {
        Stop-Vcam -ExitCode 70 -Message "OBS capture frame-rate normalization self-test failed."
    }
    $qsvArgumentTest = @(New-VcamFfmpegArguments -InputSource "obs" `
        -CanvasWidth 1920 -CanvasHeight 1080 -OutputFPS 30 `
        -OutputScaleMode "fill" -OutputQuality 5 `
        -ListenerURL "http://127.0.0.1:18888/live.mjpg" `
        -CaptureDevice "OBS Virtual Camera" -ObsMode $integerMode `
        -RealtimeBuffer 256 -PacketQueueSize 32 `
        -MjpegEncoderThreads 4 -NetworkQueueSize 64 `
        -NetworkSendBufferMB 4 -LogLevel "error" -MjpegEncoder "mjpeg_qsv")
    $qsvArgumentText = $qsvArgumentTest -join "`n"
    if ($qsvArgumentText -notlike "*-c:v`nmjpeg_qsv*" -or
        $qsvArgumentText -notlike "*-global_quality`n5*" -or
        $qsvArgumentText -like "*-huffman*") {
        Stop-Vcam -ExitCode 70 -Message "QSV MJPEG argument self-test failed."
    }
    $fallbackMode = [pscustomobject]@{
        PixelFormat = "nv12"; Width = 1920; Height = 1080; FPS = [double]60
    }
    $fallbackArgumentTest = @(New-VcamFfmpegArguments -InputSource "obs" `
        -CanvasWidth 1920 -CanvasHeight 1080 -OutputFPS 30 `
        -OutputScaleMode "fill" -OutputQuality 5 `
        -ListenerURL "http://127.0.0.1:18888/live.mjpg" `
        -CaptureDevice "OBS Virtual Camera" -ObsMode $fallbackMode `
        -RealtimeBuffer 256 -PacketQueueSize 32 `
        -MjpegEncoderThreads 4 -NetworkQueueSize 64 `
        -NetworkSendBufferMB 4 -LogLevel "warning")
    $fallbackFrameRateIndex = [Array]::IndexOf($fallbackArgumentTest, "-framerate")
    if ($fallbackFrameRateIndex -lt 0 -or
        $fallbackArgumentTest[$fallbackFrameRateIndex + 1] -ne "60") {
        Stop-Vcam -ExitCode 70 -Message "OBS fallback capture frame-rate self-test failed."
    }
    $hlsArgumentTest = @(New-VcamFfmpegArguments -InputSource "obs" `
        -CanvasWidth 1920 -CanvasHeight 1080 -OutputFPS 30 `
        -OutputScaleMode "fill" -OutputQuality 5 `
        -ListenerURL "http://127.0.0.1:18888/live.mjpg" `
        -CaptureDevice "OBS Virtual Camera" -ObsMode $integerMode `
        -RealtimeBuffer 256 -PacketQueueSize 32 `
        -MjpegEncoderThreads 4 -NetworkQueueSize 64 `
        -NetworkSendBufferMB 4 -LogLevel "error" `
        -Transport "hls" -OutputPath "C:\Temp\VirtualCamPro\live.m3u8" `
        -HlsSegmentDuration 0.25 -HlsPlaylistSize 6 `
        -HlsBitrateKbps 12000 -HlsPeakBitrateKbps 16000 `
        -HlsBufferKbps 24000 -HlsEncoderPreset "ultrafast")
    $hlsArgumentText = $hlsArgumentTest -join "`n"
    if ($hlsArgumentText -notlike "*-c:v`nlibx264*" -or
        $hlsArgumentText -notlike "*-f`nhls*" -or
        $hlsArgumentText -notlike "*-hls_time`n0.25*" -or
        $hlsArgumentText -notlike "*-hls_list_size`n6*" -or
        $hlsArgumentText -notlike "*-hls_segment_filename`nC:\Temp\VirtualCamPro\segment_%06d.ts*" -or
        $hlsArgumentTest[-1] -ne "C:\Temp\VirtualCamPro\live.m3u8") {
        Stop-Vcam -ExitCode 70 -Message "HLS FFmpeg argument self-test failed."
    }
    if (-not (Test-VcamInterruptedExitCode -ExitCode -1073741510) -or
        (Test-VcamInterruptedExitCode -ExitCode 0) -or
        (Test-VcamInterruptedExitCode -ExitCode 1)) {
        Stop-Vcam -ExitCode 70 -Message "Interrupt exit-code self-test failed."
    }
    if (-not (Get-Command Test-VcamObsWebSocketAuthentication -ErrorAction SilentlyContinue) -or
        -not (Test-VcamObsWebSocketAuthentication)) {
        Stop-Vcam -ExitCode 70 -Message "OBS WebSocket authentication self-test failed."
    }
    $selfTestFfmpeg = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($selfTestFfmpeg) {
        $capacityTest = Measure-VcamMjpegEncoderCapacity -Ffmpeg $selfTestFfmpeg.Source `
            -Encoder "mjpeg" -Width 640 -Height 360 -FPS 30 -Quality 5 -Threads 2
        if (-not $capacityTest.Available -or $capacityTest.RealtimeFactor -le 0) {
            Stop-Vcam -ExitCode 70 -Message "MJPEG encoder-capacity self-test failed."
        }
        $profileTest = Select-VcamMjpegEncoderProfile -Ffmpeg $selfTestFfmpeg.Source `
            -Width 640 -Height 360 -FPS 30 -Quality 5 -Threads 2
        if ($profileTest.Encoder -notin @("mjpeg", "mjpeg_qsv") -or
            $profileTest.Huffman -notin @("optimal", "default")) {
            Stop-Vcam -ExitCode 70 -Message "MJPEG adaptive encoder selection self-test failed."
        }
    }
    Write-VcamStatus -Level "OK" -Message "Windows tooling self-test passed."
    exit 0
}

$normalizedMode = $Mode.Trim().ToLowerInvariant()
if ($normalizedMode -eq "selftest") { Invoke-VcamSelfTest }
if ($normalizedMode -notin @("obs", "stream", "check")) {
    Stop-Vcam -ExitCode 64 -Message "Mode must be Obs, Stream, Check, or SelfTest."
}
$needsObs = $normalizedMode -in @("obs", "check") -or
    ($normalizedMode -eq "stream" -and $Source.Trim().ToLowerInvariant() -eq "obs")

$effectiveOrientation = (Get-VcamSetting -ExplicitValue $Orientation `
    -EnvironmentName "VCAM_ORIENTATION" -DefaultValue "landscape").ToLowerInvariant()
if ($effectiveOrientation -notin @("landscape", "portrait")) {
    Stop-Vcam -ExitCode 64 -Message "Orientation must be landscape or portrait."
}
$effectiveResolution = (Get-VcamSetting -ExplicitValue $Resolution `
    -EnvironmentName "VCAM_RESOLUTION" -DefaultValue "auto").ToLowerInvariant()
$fpsSetting = (Get-VcamSetting -ExplicitValue $FramesPerSecond `
    -EnvironmentName "VCAM_FPS" -DefaultValue "auto").ToLowerInvariant()
$automaticResolution = $effectiveResolution -eq "auto"
$automaticFPS = $fpsSetting -eq "auto"
$obsSavedSettings = $null
if ($needsObs -and ($automaticResolution -or $automaticFPS)) {
    $obsSavedSettings = Get-VcamObsSavedVideoSettings
    if (-not $obsSavedSettings) {
        Stop-Vcam -ExitCode 5 -Message (
            "OBS automatic settings are enabled, but the current saved OBS profile could not be read. " +
            "Set VCAM_RESOLUTION and VCAM_FPS explicitly or repair the OBS profile."
        )
    }
}
if ($automaticResolution) {
    $canvas = if ($obsSavedSettings) {
        [pscustomobject]@{
            Width = [int]$obsSavedSettings.BaseWidth
            Height = [int]$obsSavedSettings.BaseHeight
        }
    } else {
        Get-VcamCanvas -Preset "1080p" -CanvasOrientation $effectiveOrientation
    }
} else {
    $canvas = Get-VcamCanvas -Preset $effectiveResolution -CanvasOrientation $effectiveOrientation
}
$effectiveScaleMode = (Get-VcamSetting -ExplicitValue $ScaleMode `
    -EnvironmentName "VCAM_SCALE_MODE" -DefaultValue "fill").ToLowerInvariant()
if ($effectiveScaleMode -notin @("fill", "fit", "stretch")) {
    Stop-Vcam -ExitCode 64 -Message "Scale mode must be fill, fit, or stretch."
}
$effectiveTransport = (Get-VcamSetting -ExplicitValue $Transport `
    -EnvironmentName "VCAM_TRANSPORT" -DefaultValue "mjpeg").ToLowerInvariant()
if ($effectiveTransport -notin @("mjpeg", "hls")) {
    Stop-Vcam -ExitCode 64 -Message "Transport must be mjpeg or hls."
}
$effectiveHlsSegmentSeconds = ConvertTo-VcamFrameRate `
    -Value (Get-VcamSetting -ExplicitValue $HlsSegmentSeconds `
        -EnvironmentName "VCAM_HLS_SEGMENT_SECONDS" -DefaultValue "0.25") `
    -Name "HLS segment duration" -Minimum 0.2 -Maximum 10
$effectiveHlsListSize = ConvertTo-VcamInteger `
    -Value (Get-VcamSetting -ExplicitValue $HlsListSize `
        -EnvironmentName "VCAM_HLS_LIST_SIZE" -DefaultValue "6") `
    -Name "HLS playlist size" -Minimum 6 -Maximum 30
$effectiveHlsVideoBitrateKbps = ConvertTo-VcamInteger `
    -Value (Get-VcamSetting -ExplicitValue $HlsVideoBitrateKbps `
        -EnvironmentName "VCAM_HLS_VIDEO_BITRATE_KBPS" -DefaultValue "12000") `
    -Name "HLS video bitrate" -Minimum 500 -Maximum 100000
$effectiveHlsMaxrateKbps = ConvertTo-VcamInteger `
    -Value (Get-VcamSetting -ExplicitValue $HlsMaxrateKbps `
        -EnvironmentName "VCAM_HLS_MAXRATE_KBPS" -DefaultValue "16000") `
    -Name "HLS maximum bitrate" -Minimum 500 -Maximum 120000
$effectiveHlsBufsizeKbps = ConvertTo-VcamInteger `
    -Value (Get-VcamSetting -ExplicitValue $HlsBufsizeKbps `
        -EnvironmentName "VCAM_HLS_BUFSIZE_KBPS" -DefaultValue "12000") `
    -Name "HLS VBV buffer" -Minimum 500 -Maximum 200000
if ($effectiveHlsMaxrateKbps -lt $effectiveHlsVideoBitrateKbps) {
    Stop-Vcam -ExitCode 64 -Message "HLS maximum bitrate must be greater than or equal to the target bitrate."
}
$effectiveHlsPreset = (Get-VcamSetting -ExplicitValue $HlsPreset `
    -EnvironmentName "VCAM_HLS_PRESET" -DefaultValue "ultrafast").ToLowerInvariant()
if ($effectiveHlsPreset -notin @("ultrafast", "superfast", "veryfast", "faster", "fast", "medium")) {
    Stop-Vcam -ExitCode 64 -Message (
        "HLS preset must be ultrafast, superfast, veryfast, faster, fast, or medium."
    )
}
$effectiveQuality = ConvertTo-VcamInteger `
    -Value (Get-VcamSetting -ExplicitValue $Quality -EnvironmentName "VCAM_QUALITY" -DefaultValue "1") `
    -Name "MJPEG quality" -Minimum 1 -Maximum 31
$effectiveFPS = if ($automaticFPS) {
    if ($obsSavedSettings) { [double]$obsSavedSettings.FPS } else { [double]30 }
} else {
    ConvertTo-VcamFrameRate -Value $fpsSetting -Name "frame rate" -Minimum 1 -Maximum 240
}
$effectiveFPSText = Format-VcamFrameRate -Value $effectiveFPS
$effectivePort = ConvertTo-VcamInteger `
    -Value (Get-VcamSetting -ExplicitValue $Port -EnvironmentName "VCAM_PORT" -DefaultValue "8888") `
    -Name "TCP port" -Minimum 1024 -Maximum 65535
$effectiveWait = ConvertTo-VcamInteger `
    -Value (Get-VcamSetting -ExplicitValue $ObsWaitSeconds `
        -EnvironmentName "VCAM_OBS_WAIT_SECONDS" -DefaultValue "15") `
    -Name "OBS wait time" -Minimum 1 -Maximum 120
$effectiveRestart = ConvertTo-VcamBoolean `
    -Value (Get-VcamSetting -ExplicitValue $RestartOnDisconnect `
        -EnvironmentName "VCAM_RESTART_ON_DISCONNECT" -DefaultValue "true") `
    -Name "restart-on-disconnect"
$effectiveRealtimeBufferMB = ConvertTo-VcamInteger `
    -Value (Get-VcamSetting -ExplicitValue $RealtimeBufferMB `
        -EnvironmentName "VCAM_RT_BUFFER_MB" -DefaultValue "64") `
    -Name "DirectShow real-time buffer" -Minimum 16 -Maximum 1024
$effectiveThreadQueueSize = ConvertTo-VcamInteger `
    -Value (Get-VcamSetting -ExplicitValue $ThreadQueueSize `
        -EnvironmentName "VCAM_THREAD_QUEUE_SIZE" -DefaultValue "4") `
    -Name "DirectShow packet queue" -Minimum 1 -Maximum 256
$effectiveEncoderThreads = ConvertTo-VcamInteger `
    -Value (Get-VcamSetting -ExplicitValue $EncoderThreads `
        -EnvironmentName "VCAM_ENCODER_THREADS" -DefaultValue "4") `
    -Name "MJPEG encoder threads" -Minimum 1 -Maximum 16
$effectiveOutputQueueSize = ConvertTo-VcamInteger `
    -Value (Get-VcamSetting -ExplicitValue $OutputQueueSize `
        -EnvironmentName "VCAM_OUTPUT_QUEUE_SIZE" -DefaultValue "3") `
    -Name "MJPEG network queue" -Minimum 1 -Maximum 600
$adaptiveQueues = Get-VcamAdaptiveQueueSettings -FPS $effectiveFPS `
    -Width $canvas.Width -Height $canvas.Height `
    -RealtimeBufferMinimum $effectiveRealtimeBufferMB `
    -PacketQueueMinimum $effectiveThreadQueueSize `
    -NetworkQueueMinimum $effectiveOutputQueueSize
$effectiveTcpSendBufferMB = ConvertTo-VcamInteger `
    -Value (Get-VcamSetting -ExplicitValue $TcpSendBufferMB `
        -EnvironmentName "VCAM_TCP_SEND_BUFFER_MB" -DefaultValue "1") `
    -Name "TCP send buffer" -Minimum 1 -Maximum 16
$effectiveRequireObsModeMatch = ConvertTo-VcamBoolean `
    -Value (Get-VcamSetting -ExplicitValue $RequireObsModeMatch `
        -EnvironmentName "VCAM_REQUIRE_OBS_MODE_MATCH" -DefaultValue "true") `
    -Name "require-OBS-mode-match"
$effectiveAutoRefreshObs = ConvertTo-VcamBoolean `
    -Value (Get-VcamSetting -ExplicitValue $AutoRefreshObsVirtualCamera `
        -EnvironmentName "VCAM_AUTO_REFRESH_OBS_VIRTUAL_CAMERA" -DefaultValue "true") `
    -Name "auto-refresh-OBS-virtual-camera"
$effectiveFfmpegLogLevel = (Get-VcamSetting -ExplicitValue $FfmpegLogLevel `
    -EnvironmentName "VCAM_FFMPEG_LOG_LEVEL" -DefaultValue "error").ToLowerInvariant()
if ($effectiveFfmpegLogLevel -notin @("error", "warning", "info")) {
    Stop-Vcam -ExitCode 64 -Message "FFmpeg log level must be error, warning, or info."
}
$effectiveBindAddress = Get-VcamSetting -ExplicitValue $BindAddress `
    -EnvironmentName "VCAM_BIND_ADDRESS" -DefaultValue "0.0.0.0"
$parsedBindAddress = $null
if (-not [Net.IPAddress]::TryParse($effectiveBindAddress, [ref]$parsedBindAddress) -or
    $parsedBindAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
    Stop-Vcam -ExitCode 64 -Message "Bind address must be an IPv4 literal, such as 0.0.0.0 or 127.0.0.1."
}
$endpointPath = if ($effectiveTransport -eq "hls") { "live.m3u8" } else { "live.mjpg" }
$transportDisplay = if ($effectiveTransport -eq "hls") { "HLS/H.264" } else { "MJPEG" }
$effectiveDeviceName = Get-VcamSetting -ExplicitValue $DeviceName `
    -EnvironmentName "VCAM_DEVICE_NAME" -DefaultValue "OBS Virtual Camera"
if ($effectiveDeviceName.IndexOfAny(@([char]'"', [char]"`r", [char]"`n")) -ge 0) {
    Stop-Vcam -ExitCode 64 -Message "Capture device name contains an unsupported quote or newline."
}
$effectiveScene = Get-VcamSetting -ExplicitValue $Scene `
    -EnvironmentName "VCAM_OBS_SCENE" -DefaultValue ""
if ($effectiveScene.IndexOfAny(@([char]'"', [char]"`r", [char]"`n")) -ge 0) {
    Stop-Vcam -ExitCode 64 -Message "OBS scene name contains an unsupported quote or newline."
}
$effectiveFfmpegPath = Get-VcamSetting -ExplicitValue $FfmpegPath `
    -EnvironmentName "VCAM_FFMPEG_PATH" -DefaultValue ""
$ffmpeg = Resolve-VcamExecutable -ConfiguredPath $effectiveFfmpegPath `
    -CommandName "ffmpeg.exe" `
    -InstallHint "Install it with: winget install -e --id Gyan.FFmpeg"
if ($effectiveTransport -eq "hls" -and
    -not (Test-VcamFfmpegEncoder -Ffmpeg $ffmpeg -Encoder "libx264")) {
    Stop-Vcam -ExitCode 3 -Message (
        "The selected HLS mode requires FFmpeg with the libx264 encoder. " +
        "Install a standard Gyan FFmpeg build or switch VCAM_TRANSPORT to mjpeg."
    )
}
$mjpegEncoderProfile = $null
if ($effectiveTransport -eq "mjpeg") {
    $mjpegEncoderProfile = Select-VcamMjpegEncoderProfile -Ffmpeg $ffmpeg `
        -Width $canvas.Width -Height $canvas.Height -FPS $effectiveFPS `
        -Quality $effectiveQuality -Threads $effectiveEncoderThreads
}

Write-Host ""
Write-Host "============================================================"
Write-Host " VirtualCamPro Windows streaming tool"
Write-Host "============================================================"
Write-VcamStatus -Level "OK" -Message "FFmpeg: $ffmpeg"
if ($mjpegEncoderProfile) {
    $capacity = $mjpegEncoderProfile.Capacity
    if ($capacity.Available) {
        $encoderDisplay = if ($mjpegEncoderProfile.Encoder -eq "mjpeg_qsv") {
            "Intel Quick Sync MJPEG"
        } else {
            "software MJPEG / Huffman $($mjpegEncoderProfile.Huffman)"
        }
        Write-VcamStatus -Level "OK" -Message ((
            "Encoder preflight selected {0}; measured reserve {1:0.00}x real-time; " +
            "synthetic stream estimate {2:0.0} Mbit/s."
        ) -f $encoderDisplay, $capacity.RealtimeFactor, $capacity.EstimatedMbps)
        if ($capacity.RealtimeFactor -lt 1.25) {
            Write-VcamStatus -Level "WARN" -Message (
                "Encoder reserve is below 1.25x at the current OBS resolution/FPS/quality. " +
                "The bridge will preserve those OBS settings, but sustained CPU/GPU load can still drop frames."
            )
        }
    } else {
        Write-VcamStatus -Level "WARN" -Message (
            "Encoder preflight could not run; using the compatible software MJPEG path. " +
            $capacity.Error
        )
    }
}
if ($obsSavedSettings) {
    Write-VcamStatus -Level "OK" -Message ((
        "Saved OBS profile '{0}': base {1}x{2}, output {3}x{4}, {5} FPS"
    ) -f $obsSavedSettings.ProfileName,
        $obsSavedSettings.BaseWidth, $obsSavedSettings.BaseHeight,
        $obsSavedSettings.OutputWidth, $obsSavedSettings.OutputHeight,
        (Format-VcamFrameRate -Value $obsSavedSettings.FPS))
    if ($obsSavedSettings.BaseWidth -ne $obsSavedSettings.OutputWidth -or
        $obsSavedSettings.BaseHeight -ne $obsSavedSettings.OutputHeight) {
        Write-VcamStatus -Level "WARN" -Message (
            "OBS base and scaled output resolutions differ. Virtual Camera follows the base canvas; " +
            "source transforms may need adjustment after a canvas change."
        )
    }
}
if ($effectiveTransport -eq "mjpeg") {
    Write-Host ((
        "Canvas: {0}x{1} at {2} FPS; transport MJPEG; quality {3}; encoder threads {4}; scale mode {5}"
    ) -f $canvas.Width, $canvas.Height, $effectiveFPSText,
        $effectiveQuality, $effectiveEncoderThreads, $effectiveScaleMode)
    Write-Host ((
        "Buffers: DirectShow {0} MiB; input queue {1} frames; network FIFO {2} frames; TCP send {3} MiB"
    ) -f $adaptiveQueues.RealtimeBuffer, $adaptiveQueues.PacketQueue,
        $adaptiveQueues.NetworkQueue, $effectiveTcpSendBufferMB)
} else {
    Write-Host ((
        "Canvas: {0}x{1} at {2} FPS; transport HLS/H.264; {3} kbps target / {4} kbps max; scale mode {5}"
    ) -f $canvas.Width, $canvas.Height, $effectiveFPSText,
        $effectiveHlsVideoBitrateKbps, $effectiveHlsMaxrateKbps, $effectiveScaleMode)
    Write-Host ((
        "HLS: {0}s segments; playlist {1} segments; x264 preset {2}; DirectShow buffer {3} MiB; input queue {4}"
    ) -f (Format-VcamFrameRate -Value $effectiveHlsSegmentSeconds),
        $effectiveHlsListSize, $effectiveHlsPreset,
        $adaptiveQueues.RealtimeBuffer, $adaptiveQueues.PacketQueue)
}

$portOwner = Get-VcamPortOwner -ListenPort $effectivePort
if ($portOwner) {
    Stop-Vcam -ExitCode 4 -Message (
        "TCP port {0} is already in use by {1}. Stop that listener or choose another port." -f
        $effectivePort, $portOwner
    )
}
Write-VcamStatus -Level "OK" -Message "TCP port $effectivePort is available."
Show-VcamEndpoints -ListenPort $effectivePort -ListenerAddress $effectiveBindAddress `
    -EndpointPath $endpointPath -TransportName $transportDisplay
if ($effectiveTransport -eq "mjpeg") {
    Write-Host "If the phone cannot connect, allow FFmpeg through Windows Firewall on private networks."
} else {
    Write-Host "If the phone cannot connect, allow Windows PowerShell through Windows Firewall on private networks."
}

$obs = $null
$obsModes = @()
$selectedObsMode = $null
if ($needsObs) {
    $effectiveObsPath = Get-VcamSetting -ExplicitValue $ObsPath `
        -EnvironmentName "VCAM_OBS_PATH" -DefaultValue ""
    $obsCandidates = @(
        $(if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
            Join-Path $env:ProgramFiles "obs-studio\bin\64bit\obs64.exe"
        }),
        $(if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
            Join-Path ${env:ProgramFiles(x86)} "obs-studio\bin\64bit\obs64.exe"
        }),
        $(if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            Join-Path $env:LOCALAPPDATA "Programs\obs-studio\bin\64bit\obs64.exe"
        })
    ) | Where-Object { $_ }
    $obs = Resolve-VcamExecutable -ConfiguredPath $effectiveObsPath `
        -CommandName "obs64.exe" -CommonPaths $obsCandidates `
        -InstallHint "Install it with: winget install -e --id OBSProject.OBSStudio"
    Write-VcamStatus -Level "OK" -Message "OBS: $obs"
    if (Get-Command Get-VcamObsWebSocketConfig -ErrorAction SilentlyContinue) {
        $obsControlConfig = Get-VcamObsWebSocketConfig
        if ($obsControlConfig.Enabled) {
            Write-VcamStatus -Level "OK" -Message (
                "OBS local control is enabled on port {0}; Virtual Camera can self-recover safely." -f
                $obsControlConfig.Port
            )
        } elseif ($effectiveAutoRefreshObs) {
            Write-VcamStatus -Level "INFO" -Message $obsControlConfig.Reason
        }
    }
    if (-not (Test-VcamObsDeviceRegistered -Ffmpeg $ffmpeg -CaptureDevice $effectiveDeviceName)) {
        Stop-Vcam -ExitCode 5 -Message (
            "DirectShow device '$effectiveDeviceName' is not registered. Repair or reinstall OBS Studio."
        )
    }
    Write-VcamStatus -Level "OK" -Message "DirectShow device '$effectiveDeviceName' is registered."
    foreach ($sceneWarning in @(Get-VcamObsSceneWarnings)) {
        Write-VcamStatus -Level "WARN" -Message $sceneWarning
    }
    $obsModes = @(Get-VcamObsVideoModes -Ffmpeg $ffmpeg -CaptureDevice $effectiveDeviceName)
    Write-Host ("OBS DirectShow modes: {0}" -f (Format-VcamObsVideoModes -Modes $obsModes))
    $selectedObsMode = Select-VcamObsVideoMode -Modes $obsModes `
        -Width $canvas.Width -Height $canvas.Height -FPS $effectiveFPS `
        -RequireExact $effectiveRequireObsModeMatch
    if (-not $selectedObsMode) {
        Write-VcamStatus -Level "WARN" -Message ((
            "OBS Virtual Camera does not currently publish {0}x{1}@{2}. " +
            "Set the OBS base/output resolution and FPS to match, then stop and restart Virtual Camera."
        ) -f $canvas.Width, $canvas.Height, $effectiveFPSText)
    }
}

if ($normalizedMode -eq "check") {
    if ($needsObs -and -not $selectedObsMode) {
        Stop-Vcam -ExitCode 5 -Message (
            "OBS Virtual Camera does not publish the requested resolution and frame rate."
        )
    }
    Write-VcamStatus -Level "OK" -Message "Configuration and dependency preflight passed."
    exit 0
}

# FFmpeg's listen socket becomes an established connection while the phone is
# attached, so a normal port-listener check alone cannot detect another active
# bridge. Keep a per-port mutex for the lifetime of this launcher.
Enter-VcamBridgeMutex -ListenPort $effectivePort

if ($normalizedMode -eq "obs") {
    $runningObs = Get-Process -Name "obs64" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $runningObs) {
        Write-VcamStatus -Level "INFO" -Message "Starting OBS with Virtual Camera enabled..."
        if (-not (Start-VcamObs -Executable $obs -SelectedScene $effectiveScene)) {
            Stop-Vcam -ExitCode 5 -Message "OBS could not be started. Open it manually and review its startup error."
        }
        if (-not (Wait-VcamObsFrame -Ffmpeg $ffmpeg -CaptureDevice $effectiveDeviceName `
                -TimeoutSeconds $effectiveWait)) {
            Stop-Vcam -ExitCode 5 -Message (
                "OBS started, but '$effectiveDeviceName' did not produce a frame within $effectiveWait seconds. " +
                "Open OBS, verify the selected scene, and click Start Virtual Camera."
            )
        }
    } else {
        $obsHasFrame = Wait-VcamObsFrame -Ffmpeg $ffmpeg -CaptureDevice $effectiveDeviceName `
            -TimeoutSeconds ([Math]::Min(5, $effectiveWait))
        if (-not $obsHasFrame -and $effectiveAutoRefreshObs) {
            $controlResult = Request-VcamObsVirtualCameraRecovery `
                -TimeoutSeconds ([Math]::Min(8, $effectiveWait))
            if ($controlResult.Success) {
                $obsHasFrame = Wait-VcamObsFrame -Ffmpeg $ffmpeg `
                    -CaptureDevice $effectiveDeviceName -TimeoutSeconds $effectiveWait
            }
        }
        if (-not $obsHasFrame) {
            Stop-Vcam -ExitCode 5 -Message (
                "OBS is already running, but its Virtual Camera is not producing frames. " +
                "If local control is disabled, enable it once or click Start Virtual Camera in OBS."
            )
        }
    }
    Write-VcamStatus -Level "OK" -Message "OBS Virtual Camera is producing frames."
    $obsModes = @(Get-VcamObsVideoModes -Ffmpeg $ffmpeg -CaptureDevice $effectiveDeviceName)
    $selectedObsMode = Select-VcamObsVideoMode -Modes $obsModes `
        -Width $canvas.Width -Height $canvas.Height -FPS $effectiveFPS `
        -RequireExact $effectiveRequireObsModeMatch
    if (-not $selectedObsMode -and $runningObs -and $effectiveAutoRefreshObs) {
        $controlResult = Request-VcamObsVirtualCameraRecovery -Restart `
            -TimeoutSeconds ([Math]::Min(8, $effectiveWait))
        if ($controlResult.Success -and
            (Wait-VcamObsFrame -Ffmpeg $ffmpeg -CaptureDevice $effectiveDeviceName `
                -TimeoutSeconds $effectiveWait)) {
            $obsModes = @(Get-VcamObsVideoModes -Ffmpeg $ffmpeg `
                -CaptureDevice $effectiveDeviceName)
            $selectedObsMode = Select-VcamObsVideoMode -Modes $obsModes `
                -Width $canvas.Width -Height $canvas.Height -FPS $effectiveFPS `
                -RequireExact $effectiveRequireObsModeMatch
        }
    }
    if (-not $selectedObsMode) {
        Stop-Vcam -ExitCode 5 -Message ((
            "OBS publishes [{0}], but the requested stream is {1}x{2}@{3}. " +
            "In OBS Settings > Video, set both resolutions and FPS, apply, then restart Virtual Camera."
        ) -f (Format-VcamObsVideoModes -Modes $obsModes),
            $canvas.Width, $canvas.Height, $effectiveFPSText)
    }
    if ($selectedObsMode.Width -ne $canvas.Width -or
        $selectedObsMode.Height -ne $canvas.Height -or
        -not (Test-VcamFrameRateMatch -Actual $selectedObsMode.FPS -Requested $effectiveFPS)) {
        Write-VcamStatus -Level "WARN" -Message ((
            "Using mismatched OBS mode {0}x{1}@{2}; output scaling may reduce quality or increase buffering."
        ) -f $selectedObsMode.Width, $selectedObsMode.Height,
            (Format-VcamFrameRate -Value $selectedObsMode.FPS))
    }
    $effectiveSource = "obs"
} else {
    if ([string]::IsNullOrWhiteSpace($Source)) {
        Write-Host "Usage:"
        Write-Host "  start-stream.bat obs [landscape|portrait] [720p|1080p|1440p|2160p] [quality] [fps] [port]"
        Write-Host '  start-stream.bat "D:\Videos\demo.mp4" landscape 1080p 1 30 8888'
        Write-Host "  start-stream.bat --check"
        exit 64
    }
    $effectiveSource = $Source.Trim()
    if ($effectiveSource.ToLowerInvariant() -eq "obs") {
        if (-not (Test-VcamObsFrame -Ffmpeg $ffmpeg -CaptureDevice $effectiveDeviceName -TimeoutSeconds 3)) {
            Stop-Vcam -ExitCode 5 -Message (
                "'$effectiveDeviceName' is installed but not producing frames. Start OBS Virtual Camera first."
            )
        }
        Write-VcamStatus -Level "OK" -Message "OBS Virtual Camera is producing frames."
        $obsModes = @(Get-VcamObsVideoModes -Ffmpeg $ffmpeg -CaptureDevice $effectiveDeviceName)
        $selectedObsMode = Select-VcamObsVideoMode -Modes $obsModes `
            -Width $canvas.Width -Height $canvas.Height -FPS $effectiveFPS `
            -RequireExact $effectiveRequireObsModeMatch
        if (-not $selectedObsMode) {
            Stop-Vcam -ExitCode 5 -Message ((
                "OBS publishes [{0}], but the requested stream is {1}x{2}@{3}. " +
                "Match OBS Settings > Video and restart Virtual Camera."
            ) -f (Format-VcamObsVideoModes -Modes $obsModes),
                $canvas.Width, $canvas.Height, $effectiveFPSText)
        }
    } else {
        if (-not (Test-Path -LiteralPath $effectiveSource -PathType Leaf)) {
            Stop-Vcam -ExitCode 2 -Message "Input file does not exist: $effectiveSource"
        }
        $effectiveSource = (Resolve-Path -LiteralPath $effectiveSource).Path
        Test-VcamFileSource -Ffmpeg $ffmpeg -InputPath $effectiveSource
        Write-VcamStatus -Level "OK" -Message "Video source: $effectiveSource"
    }
}

$outputURL = "http://{0}:{1}/{2}" -f $effectiveBindAddress, $effectivePort, $endpointPath
$hlsRoot = $null
$hlsOutputPath = ""
$hlsServerProcess = $null
if ($effectiveTransport -eq "hls") {
    $hlsRoot = Join-Path ([IO.Path]::GetTempPath()) ("VirtualCamPro\hls-{0}" -f $effectivePort)
    [IO.Directory]::CreateDirectory($hlsRoot) | Out-Null
    Get-ChildItem -LiteralPath $hlsRoot -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $hlsOutputPath = Join-Path $hlsRoot "live.m3u8"
}

Write-Host ""
if ($effectiveTransport -eq "mjpeg") {
    Write-VcamStatus -Level "INFO" -Message "Starting the MJPEG bridge. Press Ctrl+C to stop."
    Write-Host "The FFmpeg HTTP listener serves one phone connection at a time."
    if ($effectiveRestart) {
        Write-Host "The listener will restart automatically after a disconnect."
    }
} else {
    Write-VcamStatus -Level "INFO" -Message "Starting the HLS/H.264 bridge. Press Ctrl+C to stop."
    Write-Host "The built-in HLS HTTP server can serve repeated playlist and segment requests."
    if ($effectiveRestart) {
        Write-Host "FFmpeg will restart automatically after an encoder failure; phone disconnects do not stop HLS."
    }
}

$shortFailureCount = 0
$launchCount = 0
$modeWaitStartedAt = $null
$lastAutoRefreshSignature = ""

try {
    if ($effectiveTransport -eq "hls") {
        $hlsServerProcess = Start-VcamHlsServer -RootPath $hlsRoot `
            -BindAddress $effectiveBindAddress -Port $effectivePort
        Write-VcamStatus -Level "OK" -Message "HLS HTTP server is listening."
    }

    while ($true) {
        if ($effectiveSource -eq "obs" -and $launchCount -gt 0) {
            if ($automaticResolution -or $automaticFPS) {
                $latestSavedSettings = Get-VcamObsSavedVideoSettings
                if ($latestSavedSettings) {
                    $obsSavedSettings = $latestSavedSettings
                    if ($automaticResolution) {
                        $canvas = [pscustomobject]@{
                            Width = [int]$latestSavedSettings.BaseWidth
                            Height = [int]$latestSavedSettings.BaseHeight
                        }
                    }
                    if ($automaticFPS) {
                        $effectiveFPS = [double]$latestSavedSettings.FPS
                        $effectiveFPSText = Format-VcamFrameRate -Value $effectiveFPS
                    }
                }
            }
            $obsModes = @(Get-VcamObsVideoModes -Ffmpeg $ffmpeg -CaptureDevice $effectiveDeviceName)
            $refreshedMode = Select-VcamObsVideoMode -Modes $obsModes `
                -Width $canvas.Width -Height $canvas.Height -FPS $effectiveFPS `
                -RequireExact $effectiveRequireObsModeMatch
            if (-not $refreshedMode) {
                $desiredModeSignature = "{0}x{1}@{2}" -f
                    $canvas.Width, $canvas.Height, $effectiveFPSText
                if ($effectiveAutoRefreshObs -and
                    $lastAutoRefreshSignature -ne $desiredModeSignature) {
                    $lastAutoRefreshSignature = $desiredModeSignature
                    $controlResult = Request-VcamObsVirtualCameraRecovery -Restart `
                        -TimeoutSeconds ([Math]::Min(8, $effectiveWait))
                    if ($controlResult.Success) {
                        Start-Sleep -Seconds 1
                        continue
                    }
                }
                if (-not $modeWaitStartedAt) {
                    $modeWaitStartedAt = [DateTime]::UtcNow
                    Write-VcamStatus -Level "WARN" -Message ((
                        "Saved OBS settings are now {0}x{1}@{2}, but Virtual Camera publishes [{3}]. " +
                        "Waiting up to {4} seconds for the active mode to refresh..."
                    ) -f $canvas.Width, $canvas.Height, $effectiveFPSText,
                        (Format-VcamObsVideoModes -Modes $obsModes), $effectiveWait)
                }
                if (([DateTime]::UtcNow - $modeWaitStartedAt).TotalSeconds -ge $effectiveWait) {
                    Stop-Vcam -ExitCode 5 -Message (
                        "OBS saved settings were detected automatically, but Virtual Camera did not " +
                        "publish them before the timeout. Stop and restart Virtual Camera once."
                    )
                }
                Start-Sleep -Seconds 1
                continue
            }
            $modeWaitStartedAt = $null
            $lastAutoRefreshSignature = ""
            $settingsChanged = $selectedObsMode.Width -ne $refreshedMode.Width -or
                $selectedObsMode.Height -ne $refreshedMode.Height -or
                -not (Test-VcamFrameRateMatch -Actual $selectedObsMode.FPS -Requested $refreshedMode.FPS)
            $selectedObsMode = $refreshedMode
            if ($settingsChanged) {
                Write-VcamStatus -Level "OK" -Message ((
                    "Applied refreshed OBS settings automatically: {0}x{1}@{2}"
                ) -f $canvas.Width, $canvas.Height, $effectiveFPSText)
            }
        }

        $adaptiveQueues = Get-VcamAdaptiveQueueSettings -FPS $effectiveFPS `
            -Width $canvas.Width -Height $canvas.Height `
            -RealtimeBufferMinimum $effectiveRealtimeBufferMB `
            -PacketQueueMinimum $effectiveThreadQueueSize `
            -NetworkQueueMinimum $effectiveOutputQueueSize

        if ($effectiveTransport -eq "hls") {
            Get-ChildItem -LiteralPath $hlsRoot -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }

        $ffmpegArguments = @(New-VcamFfmpegArguments `
            -InputSource $effectiveSource `
            -CanvasWidth $canvas.Width -CanvasHeight $canvas.Height `
            -OutputFPS $effectiveFPS -OutputScaleMode $effectiveScaleMode `
            -OutputQuality $effectiveQuality -ListenerURL $outputURL `
            -CaptureDevice $effectiveDeviceName -ObsMode $selectedObsMode `
            -RealtimeBuffer $adaptiveQueues.RealtimeBuffer `
            -PacketQueueSize $adaptiveQueues.PacketQueue `
            -MjpegEncoderThreads $effectiveEncoderThreads `
            -NetworkQueueSize $adaptiveQueues.NetworkQueue `
            -NetworkSendBufferMB $effectiveTcpSendBufferMB `
            -LogLevel $effectiveFfmpegLogLevel `
            -Transport $effectiveTransport -OutputPath $hlsOutputPath `
            -HlsSegmentDuration $effectiveHlsSegmentSeconds `
            -HlsPlaylistSize $effectiveHlsListSize `
            -HlsBitrateKbps $effectiveHlsVideoBitrateKbps `
            -HlsPeakBitrateKbps $effectiveHlsMaxrateKbps `
            -HlsBufferKbps $effectiveHlsBufsizeKbps `
            -HlsEncoderPreset $effectiveHlsPreset `
            -MjpegEncoder $(if ($mjpegEncoderProfile) { $mjpegEncoderProfile.Encoder } else { "mjpeg" }) `
            -MjpegHuffman $(if ($mjpegEncoderProfile) { $mjpegEncoderProfile.Huffman } else { "optimal" }))

        $startedAt = [DateTime]::UtcNow
        & $ffmpeg @ffmpegArguments
        $ffmpegExitCode = $LASTEXITCODE
        $launchCount++
        $runSeconds = ([DateTime]::UtcNow - $startedAt).TotalSeconds

        if (Test-VcamInterruptedExitCode -ExitCode $ffmpegExitCode) {
            Write-VcamStatus -Level "INFO" -Message ("{0} bridge stopped by the user." -f $transportDisplay)
            exit 0
        }
        if (-not $effectiveRestart) { exit $ffmpegExitCode }

        if ($runSeconds -lt 5) {
            $shortFailureCount++
        } else {
            $shortFailureCount = 0
        }
        if ($shortFailureCount -ge 3) {
            Stop-Vcam -ExitCode 70 -Message (
                "FFmpeg exited three times in under five seconds. Last exit code: $ffmpegExitCode"
            )
        }

        $restartReason = if ($effectiveTransport -eq "mjpeg") {
            "restarting the listener"
        } else {
            "restarting the HLS encoder"
        }
        Write-VcamStatus -Level "WARN" -Message (
            "FFmpeg stopped with exit code {0}; {1} in 1 second..." -f
            $ffmpegExitCode, $restartReason
        )
        Start-Sleep -Seconds 1
    }
} finally {
    if ($hlsServerProcess) {
        Stop-VcamChildProcess -Process $hlsServerProcess
    }
    if ($hlsRoot -and (Test-Path -LiteralPath $hlsRoot -PathType Container)) {
        Remove-Item -LiteralPath $hlsRoot -Force -Recurse -ErrorAction SilentlyContinue
    }
    if ($script:VCamBridgeMutexHeld -and $script:VCamBridgeMutex) {
        try { $script:VCamBridgeMutex.ReleaseMutex() } catch {}
        $script:VCamBridgeMutexHeld = $false
    }
    if ($script:VCamBridgeMutex) {
        $script:VCamBridgeMutex.Dispose()
        $script:VCamBridgeMutex = $null
    }
}
