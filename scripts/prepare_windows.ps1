[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $ProjectRoot

$DownloadsDir = Join-Path $ProjectRoot ".downloads"
$RuntimeDir = Join-Path $ProjectRoot "runtime\python-win"
$FfmpegDir = Join-Path $ProjectRoot "runtime\ffmpeg-win"
$ResourcesDir = Join-Path $ProjectRoot "resources"
$SitePackagesDir = Join-Path $RuntimeDir "Lib\site-packages"

$PythonVersion = "3.11.9"
$PythonBuildTag = "20240415"
$PythonArchiveName = "cpython-$PythonVersion+$PythonBuildTag-x86_64-pc-windows-msvc-install_only.tar.gz"
$PythonArchiveUrl = "https://github.com/astral-sh/python-build-standalone/releases/download/$PythonBuildTag/$PythonArchiveName"
$ResourceUrl = "https://image-url-2-feature-1251524319.cos.ap-shanghai.myqcloud.com/openstoryline/resource.zip"
$FfmpegUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )

    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

function Invoke-Download {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        Write-Host "Using cached download: $Destination"
        return
    }

    $Parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    $Partial = "$Destination.part"

    Write-Host "Downloading $Url"
    Invoke-CheckedCommand "Download $Url" {
        curl.exe -fL --retry 5 --retry-delay 3 --retry-all-errors -C - -o $Partial $Url
    }
    Move-Item -LiteralPath $Partial -Destination $Destination -Force
}

New-Item -ItemType Directory -Force -Path $DownloadsDir | Out-Null

Write-Host "== [1/4] Static resources =="
$HasResources = (Test-Path -LiteralPath $ResourcesDir) -and
    ($null -ne (Get-ChildItem -LiteralPath $ResourcesDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1))
if (-not $HasResources) {
    $ResourceArchive = Join-Path $DownloadsDir "resource.zip"
    Invoke-Download -Url $ResourceUrl -Destination $ResourceArchive
    New-Item -ItemType Directory -Force -Path $ResourcesDir | Out-Null
    Invoke-CheckedCommand "Extract resources" {
        tar.exe -xf $ResourceArchive -C $ResourcesDir
    }
}
else {
    Write-Host "Resources already exist; skipping."
}

Write-Host "== [2/4] Embedded Python =="
$EmbeddedPython = Join-Path $RuntimeDir "python.exe"
if (-not (Test-Path -LiteralPath $EmbeddedPython)) {
    $PythonArchive = Join-Path $DownloadsDir $PythonArchiveName
    $PythonExtractDir = Join-Path $DownloadsDir "python-win-extracted"
    Invoke-Download -Url $PythonArchiveUrl -Destination $PythonArchive

    if (Test-Path -LiteralPath $PythonExtractDir) {
        Remove-Item -LiteralPath $PythonExtractDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $PythonExtractDir, $RuntimeDir | Out-Null
    Invoke-CheckedCommand "Extract embedded Python" {
        tar.exe -xzf $PythonArchive -C $PythonExtractDir
    }
    Copy-Item -Path (Join-Path $PythonExtractDir "python\*") -Destination $RuntimeDir -Recurse -Force
}
else {
    Write-Host "Embedded Python already exists; skipping."
}

Write-Host "== [3/4] Python dependencies =="
if (Test-Path -LiteralPath $SitePackagesDir) {
    Remove-Item -LiteralPath $SitePackagesDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $SitePackagesDir | Out-Null

Invoke-CheckedCommand "Install Windows Python dependencies" {
    python -m pip install `
        --disable-pip-version-check `
        --target $SitePackagesDir `
        --extra-index-url "https://download.pytorch.org/whl/cpu" `
        -r (Join-Path $ProjectRoot "requirements-win.txt")
}

Write-Host "== [4/4] FFmpeg =="
$FfmpegExe = Join-Path $FfmpegDir "ffmpeg.exe"
$FfprobeExe = Join-Path $FfmpegDir "ffprobe.exe"
if (-not ((Test-Path -LiteralPath $FfmpegExe) -and (Test-Path -LiteralPath $FfprobeExe))) {
    $FfmpegArchive = Join-Path $DownloadsDir "ffmpeg-release-essentials.zip"
    $FfmpegExtractDir = Join-Path $DownloadsDir "ffmpeg-win-extracted"
    Invoke-Download -Url $FfmpegUrl -Destination $FfmpegArchive

    if (Test-Path -LiteralPath $FfmpegExtractDir) {
        Remove-Item -LiteralPath $FfmpegExtractDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $FfmpegExtractDir, $FfmpegDir | Out-Null
    Invoke-CheckedCommand "Extract FFmpeg" {
        tar.exe -xf $FfmpegArchive -C $FfmpegExtractDir
    }

    $DownloadedFfmpeg = Get-ChildItem -LiteralPath $FfmpegExtractDir -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
    $DownloadedFfprobe = Get-ChildItem -LiteralPath $FfmpegExtractDir -Recurse -Filter "ffprobe.exe" | Select-Object -First 1
    if (($null -eq $DownloadedFfmpeg) -or ($null -eq $DownloadedFfprobe)) {
        throw "The FFmpeg archive did not contain ffmpeg.exe and ffprobe.exe"
    }
    Copy-Item -LiteralPath $DownloadedFfmpeg.FullName -Destination $FfmpegExe -Force
    Copy-Item -LiteralPath $DownloadedFfprobe.FullName -Destination $FfprobeExe -Force
}
else {
    Write-Host "FFmpeg already exists; skipping."
}

Write-Host "== Verification =="
Invoke-CheckedCommand "Verify embedded Python imports" {
    & $EmbeddedPython -c "import av, fastapi, langchain, moviepy, pystray, torch, uvicorn, webview; print('Embedded runtime imports OK')"
}

foreach ($RequiredPath in @(
    $EmbeddedPython,
    (Join-Path $RuntimeDir "pythonw.exe"),
    $FfmpegExe,
    $FfprobeExe,
    (Join-Path $ResourcesDir "script_templates\meta.json")
)) {
    if (-not (Test-Path -LiteralPath $RequiredPath)) {
        throw "Missing required build input: $RequiredPath"
    }
}

Write-Host "Windows build inputs are ready."
