[CmdletBinding()]
param(
    [string]$OutputDirectory = "",
    [string]$PackagePath = "",
    [switch]$AllowMissingPackage,
    [switch]$CreateZip
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $projectRoot `
        "artifacts\VirtualCamPro-Windows-Control-Center-2.24.3-standalone"
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($outputRoot) | Out-Null

$controlCenterRoot = "VirtualCamPro-Windows-Control-Center"
$copyMap = [ordered]@{
    "$controlCenterRoot\VirtualCamPro-Windows控制中心.bat" = "VirtualCamPro-Windows控制中心.bat"
    "$controlCenterRoot\start-obs-vcam.bat" = "start-obs-vcam.bat"
    "$controlCenterRoot\start-stream.bat" = "start-stream.bat"
    "$controlCenterRoot\install-phone.bat" = "install-phone.bat"
    "$controlCenterRoot\standalone-self-test.bat" = "standalone-self-test.bat"
    "$controlCenterRoot\obs-vcam-config.cmd" = "obs-vcam-config.cmd"
    "$controlCenterRoot\WINDOWS_TOOLS.md" = "WINDOWS_TOOLS.md"
    "$controlCenterRoot\DEPLOYMENT.md" = "DEPLOYMENT.md"
    "$controlCenterRoot\使用说明.txt" = "使用说明.txt"
    "$controlCenterRoot\scripts\windows-vcam.ps1" = "scripts\windows-vcam.ps1"
    "$controlCenterRoot\scripts\launch-control-center.ps1" = "scripts\launch-control-center.ps1"
    "$controlCenterRoot\scripts\obs-websocket.ps1" = "scripts\obs-websocket.ps1"
    "$controlCenterRoot\scripts\hls-server.ps1" = "scripts\hls-server.ps1"
    "$controlCenterRoot\scripts\deep-self-test.ps1" = "scripts\deep-self-test.ps1"
    "$controlCenterRoot\scripts\install-ios.ps1" = "scripts\install-ios.ps1"
    "$controlCenterRoot\scripts\install-ios-gui.ps1" = "scripts\install-ios-gui.ps1"
    "$controlCenterRoot\scripts\verify-standalone.ps1" = "scripts\verify-standalone.ps1"
}

$deliveredPaths = New-Object Collections.Generic.List[string]
foreach ($sourceRelative in $copyMap.Keys) {
    $sourcePath = Join-Path $projectRoot $sourceRelative
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Standalone source file is missing: $sourceRelative"
    }
    $destinationRelative = $copyMap[$sourceRelative]
    $destinationPath = Join-Path $outputRoot $destinationRelative
    [IO.Directory]::CreateDirectory((Split-Path -Parent $destinationPath)) | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    $deliveredPaths.Add($destinationRelative)
}

$packageRelative = ""
if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $candidate = Get-ChildItem -LiteralPath (Join-Path $projectRoot "$controlCenterRoot\packages") `
        -Filter "com.murkaska.virtualcampro_*_iphoneos-arm64.deb" `
        -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc, FullName -Descending |
        Select-Object -First 1
    if ($candidate) { $PackagePath = $candidate.FullName }
}
if (-not [string]::IsNullOrWhiteSpace($PackagePath)) {
    if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
        throw "Package does not exist: $PackagePath"
    }
    $package = Get-Item -LiteralPath $PackagePath
    if ($package.Name -notmatch '^com\.murkaska\.virtualcampro_[0-9A-Za-z.+~_-]+_iphoneos-arm64\.deb$') {
        throw "Unexpected package filename: $($package.Name)"
    }
    $packageRelative = "packages\$($package.Name)"
    $packageDestination = Join-Path $outputRoot $packageRelative
    [IO.Directory]::CreateDirectory((Join-Path $outputRoot "packages")) | Out-Null
    if (-not [IO.Path]::GetFullPath($package.FullName).Equals(
            [IO.Path]::GetFullPath($packageDestination),
            [StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $package.FullName `
            -Destination $packageDestination -Force
    }
    $deliveredPaths.Add($packageRelative)
} elseif (-not $AllowMissingPackage) {
    throw "No VirtualCamPro .deb was found. Pass -PackagePath or -AllowMissingPackage."
}

$sourceCommit = "unavailable"
$sourceDirty = $true
try {
    $sourceCommit = (& git -C $projectRoot rev-parse HEAD 2>$null | Select-Object -First 1).Trim()
    $sourceDirty = @(& git -C $projectRoot status --porcelain 2>$null).Count -gt 0
} catch {
    # A source archive can build the companion tool without Git metadata.
}

$manifestFiles = @($deliveredPaths | Sort-Object -Unique | ForEach-Object {
    $path = Join-Path $outputRoot $_
    $file = Get-Item -LiteralPath $path
    [ordered]@{
        path = $_
        bytes = [long]$file.Length
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        mutable = $_ -eq "obs-vcam-config.cmd"
    }
})
$manifest = [ordered]@{
    schemaVersion = 1
    toolName = "VirtualCamPro Windows Control Center"
    toolVersion = "2.24.3"
    generatedAtUtc = [DateTime]::UtcNow.ToString("o")
    sourceCommit = $sourceCommit
    sourceDirty = [bool]$sourceDirty
    packageIncluded = -not [string]::IsNullOrWhiteSpace($packageRelative)
    files = $manifestFiles
}
$manifestPath = Join-Path $outputRoot "standalone-manifest.json"
$manifestJson = ($manifest | ConvertTo-Json -Depth 6).Replace("`r`n", "`n")
[IO.File]::WriteAllText(
    $manifestPath,
    $manifestJson,
    (New-Object Text.UTF8Encoding($true))
)

& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $outputRoot "scripts\verify-standalone.ps1") `
    -RootPath $outputRoot
if ($LASTEXITCODE -ne 0) { throw "Generated standalone verification failed." }

if ($CreateZip) {
    $zipPath = "$outputRoot.zip"
    if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $outputRoot "*") `
        -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Host "Created archive: $zipPath" -ForegroundColor Green
}
Write-Host "Created standalone companion tool: $outputRoot" -ForegroundColor Green
