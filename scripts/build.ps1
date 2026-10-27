# Builds the Windows app: LayoutFixer.exe in build\publish-win-<arch>\, and a release zip in build\.
#
#   .\scripts\build.ps1                      self-contained single exe, win-x64 (nothing to install)
#   .\scripts\build.ps1 -Arch arm64          the same, for Windows on Arm
#   .\scripts\build.ps1 -FrameworkDependent  a few hundred KB, but needs the .NET 8 Desktop Runtime
#   .\scripts\build.ps1 -Zip -Icons          regenerate the .ico files first, then build and zip
#   .\scripts\build.ps1 -Test                build, then print what the detector makes of a sample
#   .\scripts\build.ps1 -Open                build and start it
#
# Needs the .NET 8 SDK and nothing else:  winget install Microsoft.DotNet.SDK.8
# Visual Studio is not required; the app has no designer files and no NuGet dependencies.
#
# Every message this script writes goes to build\build-win-<arch>.log as well as to the console, and
# a failure is recorded there with its full exception, because a build that dies quietly is useless.

param(
    [ValidateSet("x64", "arm64")]
    [string]$Arch = "x64",
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [switch]$FrameworkDependent,
    [switch]$Zip,
    [switch]$Icons,
    [switch]$Test,
    [switch]$Open,
    [string]$TestText = "صشدف فخ لقشذ معدزا"
)

$ErrorActionPreference = "Stop"
$Version = "0.1.0"

$Root = Split-Path -Parent $PSScriptRoot
$Project = Join-Path $Root "Sources/LayoutFixer/LayoutFixer.csproj"
$BuildDir = Join-Path $Root "build"
$PublishDir = Join-Path $BuildDir "publish-win-$Arch"
$Transcript = Join-Path $BuildDir "build-win-$Arch.log"
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
Set-Content -LiteralPath $Transcript -Value "build-win-$Arch : $(Get-Date -Format 'o')" -Encoding utf8

function Say {
    param([string]$Message, [string]$Color)
    if ($Color) { Write-Host $Message -ForegroundColor $Color } else { Write-Host $Message }
    Add-Content -LiteralPath $Transcript -Value $Message -Encoding utf8
}

# pwsh makes a native command's stderr a terminating error while $ErrorActionPreference is Stop, and
# MSBuild writes plenty of harmless things there. So dotnet is judged only by its exit code, and its
# output is kept in the same log for CI to point at.
function Invoke-DotNet {
    param([string[]]$Arguments)
    $output = @()
    $code = 1
    $previous = $ErrorActionPreference
    $global:ErrorActionPreference = "Continue"
    try {
        $output = & dotnet @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $global:ErrorActionPreference = $previous
    }
    foreach ($line in $output) { Say $line }
    return $code
}

# A freshly published 140 MB exe is often still being scanned by Windows Defender, which keeps a
# plain open-for-read from succeeding for a moment. Share::ReadWrite plus retries is what survives
# that; Compress-Archive just fails, and says so only on a stream the caller cannot see.
function Open-ForRead {
    param([string]$Path)
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            return [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                                          [System.IO.FileShare]::ReadWrite)
        } catch {
            if ($attempt -eq 20) { throw "cannot open $Path for reading: $($_.Exception.Message)" }
            Start-Sleep -Milliseconds 500
        }
    }
}

function New-Zip {
    param([string]$Source, [string]$Destination, [string[]]$Names)
    # PowerShell 7 has ZipFile in its shared framework already; the Add-Type lines are for the
    # shells and self-built runtimes that do not, and are harmless where it is already there.
    if (-not ("System.IO.Compression.ZipFile" -as [type])) {
        foreach ($assembly in "System.IO.Compression.ZipFile", "System.IO.Compression",
                              "System.IO.Compression.FileSystem") {
            try { Add-Type -AssemblyName $assembly -ErrorAction Stop; break } catch { }
        }
    }
    if (-not ("System.IO.Compression.ZipFile" -as [type])) {
        throw "no System.IO.Compression.ZipFile available to build $Destination with"
    }
    $archive = [System.IO.Compression.ZipFile]::Open($Destination, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Names) {
            $path = Join-Path $Source $name
            $entry = $archive.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            try {
                $fileStream = Open-ForRead $path
                try { $fileStream.CopyTo($entryStream) } finally { $fileStream.Dispose() }
            } finally {
                $entryStream.Dispose()
            }
            Say "  + $name"
        }
    } finally {
        $archive.Dispose()
    }
}

function Set-LastExitCodeOne { $global:LASTEXITCODE = 1 }

try {
    Set-Location $Root

    if ($Icons) { & (Join-Path $Root "scripts/make-icons.ps1") }

    # The word lists and the tray icons are embedded, so they must exist before the compile.
    foreach ($required in @("Resources/en_50k.txt", "Resources/fa_50k.txt", "Resources/AppIcon.ico",
                            "Resources/TrayIcon.ico", "Resources/TrayIconPaused.ico")) {
        if (-not (Test-Path (Join-Path $Root $required))) {
            throw "$required is missing. Run .\scripts\make-icons.ps1 to generate the icons."
        }
    }

    if (Test-Path $PublishDir) { Remove-Item -Recurse -Force $PublishDir }

    $arguments = @("publish", $Project, "-c", $Configuration, "-r", "win-$Arch", "-o", $PublishDir,
                   "--nologo", "-v", "minimal")
    if ($FrameworkDependent) {
        # -r alone means self-contained in .NET 8, so say otherwise, and keep the csproj's own
        # PublishSingleFile condition off: a framework-dependent build is a folder of small files.
        $arguments += @("--self-contained", "false", "-p:FrameworkDependent=true")
    } else {
        # One file, no runtime to install: the .NET host is packed inside the exe.
        $arguments += @("-p:PublishSingleFile=true", "-p:IncludeNativeLibrariesForSelfExtract=true")
    }
    Say "dotnet $($arguments -join ' ')" "DarkGray"
    $code = Invoke-DotNet -Arguments $arguments
    if ($code -ne 0) { throw "dotnet publish failed with exit code $code" }

    $exe = Join-Path $PublishDir "LayoutFixer.exe"
    if (-not (Test-Path $exe)) { throw "no LayoutFixer.exe in $PublishDir" }
    $size = [math]::Round((Get-Item $exe).Length / 1MB, 1)
    Say "built $PublishDir\LayoutFixer.exe ($size MB)" "Green"

    if ($Zip) {
        $zip = Join-Path $BuildDir "LayoutFixer-$Version-win-$Arch.zip"
        if (Test-Path $zip) { Remove-Item -Force $zip }
        if ($FrameworkDependent) {
            # A framework-dependent build is a handful of files that belong next to each other.
            $names = @(Get-ChildItem -Path $PublishDir -File | ForEach-Object { $_.Name })
            New-Zip -Source $PublishDir -Destination $zip -Names $names
        } else {
            # Single file: the zip holds exactly one exe, like the macOS build's zip held one .app.
            New-Zip -Source $PublishDir -Destination $zip -Names @("LayoutFixer.exe")
        }
        Say "built $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)" "Green"
    }

    if ($Test) {
        $log = Join-Path $env:TEMP "layoutfixer-test.txt"
        # A windowless exe is not waited for by PowerShell, so go through Start-Process.
        Start-Process -FilePath $exe -ArgumentList ('--test "{0}"' -f $TestText) `
                      -NoNewWindow -Wait -RedirectStandardOutput $log
        foreach ($line in (Get-Content -LiteralPath $log)) { Say $line }
    }

    if ($Open) { Start-Process $exe }
} catch {
    Say "FAILED: $($_.Exception.ToString())" "Red"
    if ($_.ScriptStackTrace) { Say "at: $($_.ScriptStackTrace)" "DarkGray" }
    Set-LastExitCodeOne
    throw
}
