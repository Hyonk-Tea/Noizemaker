param(
    [string]$LoveVersion = "11.5",
    [string]$OutputDir = "dist"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $repoRoot ".build\windows"
$downloadZip = Join-Path $buildRoot "love-win64.zip"
$gameZip = Join-Path $buildRoot "noizemaker.zip"
$gameLove = Join-Path $buildRoot "noizemaker.love"
$outputRoot = Join-Path $repoRoot $OutputDir
$packageRoot = Join-Path $outputRoot "noizemaker-windows"
$packageZip = Join-Path $outputRoot "noizemaker-windows.zip"

function Reset-Dir([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path | Out-Null
}

function Copy-FileBytes([string]$SourcePath, [string]$DestinationPath) {
    $bufferSize = 65536
    $source = [System.IO.File]::OpenRead($SourcePath)
    try {
        $dest = [System.IO.File]::Create($DestinationPath)
        try {
            $buffer = New-Object byte[] $bufferSize
            while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $dest.Write($buffer, 0, $read)
            }
        }
        finally {
            $dest.Dispose()
        }
    }
    finally {
        $source.Dispose()
    }
}

function Append-FileBytes([string]$DestinationPath, [string]$SourcePath) {
    $bufferSize = 65536
    $source = [System.IO.File]::OpenRead($SourcePath)
    try {
        $dest = [System.IO.File]::Open($DestinationPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
        try {
            $buffer = New-Object byte[] $bufferSize
            while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $dest.Write($buffer, 0, $read)
            }
        }
        finally {
            $dest.Dispose()
        }
    }
    finally {
        $source.Dispose()
    }
}

function Assert-PathExists([string]$Path, [string]$Message) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw $Message
    }
}

Reset-Dir $buildRoot
Reset-Dir $outputRoot
New-Item -ItemType Directory -Path $packageRoot | Out-Null

$loveUrl = "https://github.com/love2d/love/releases/download/$LoveVersion/love-$LoveVersion-win64.zip"
Write-Host "Downloading LOVE $LoveVersion from $loveUrl"
Invoke-WebRequest -Uri $loveUrl -OutFile $downloadZip

Expand-Archive -LiteralPath $downloadZip -DestinationPath $buildRoot -Force
$loveExtracted = Get-ChildItem -LiteralPath $buildRoot -Directory | Where-Object { $_.Name -like "love-*-win64" } | Select-Object -First 1
if (-not $loveExtracted) {
    throw "Could not find the extracted LOVE runtime folder."
}

$archiveItems = @(
    (Join-Path $repoRoot "main.lua"),
    (Join-Path $repoRoot "core"),
    (Join-Path $repoRoot "ui"),
    (Join-Path $repoRoot "README.md")
)

Compress-Archive -Path $archiveItems -DestinationPath $gameZip -Force
Move-Item -LiteralPath $gameZip -Destination $gameLove -Force

Copy-Item -Path (Join-Path $loveExtracted.FullName "*") -Destination $packageRoot -Recurse -Force

$loveExeSource = Join-Path $loveExtracted.FullName "love.exe"
$loveExePackaged = Join-Path $packageRoot "love.exe"
Assert-PathExists $loveExeSource "The downloaded LOVE runtime did not contain love.exe."
Assert-PathExists $loveExePackaged "The LOVE runtime files were not copied into the package folder."

Copy-FileBytes $loveExeSource (Join-Path $packageRoot "noizemaker.exe")
Append-FileBytes (Join-Path $packageRoot "noizemaker.exe") $gameLove

Remove-Item -LiteralPath $loveExePackaged -Force
Copy-Item -LiteralPath $gameLove -Destination (Join-Path $packageRoot "noizemaker.love") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "README.md") -Destination (Join-Path $packageRoot "README.md") -Force

if (Test-Path -LiteralPath $packageZip) {
    Remove-Item -LiteralPath $packageZip -Force
}
Compress-Archive -Path (Join-Path $packageRoot "*") -DestinationPath $packageZip -Force

Write-Host "Windows package written to $packageZip"
