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
# Every line this script writes also goes to build\build-win-<arch>.log, and a failure is recorded
# there with its exception text - which matters, because a build that dies quietly is useless.

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

function Say {
    param([string]$Message, [string]$Color)
    if ($Color) { Write-Host $Message -ForegroundColor $Color } else { Write-Host $Message }
    Add-Content -LiteralPath $Transcript -Value $Message -Encoding utf8
}

# pwsh makes a native command's stderr a terminating error while $ErrorActionPreference is Stop, and
# MSBuild writes plenty of harmless things there. So the tool is judged only by its exit code, and
# its output goes through Say, so that the log holds what the console held.
function Invoke-Tool {
    param([string]$Exe, [string[]]$Arguments)
    $output = @()
    $code = 1
    $previous = $ErrorActionPreference
    $global:ErrorActionPreference = "Continue"
    try {
        $output = & $Exe @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $global:ErrorActionPreference = $previous
    }
    foreach ($line in $output) { Say "$line" }
    return $code
}

function New-Zip {
    param([string]$Source, [string]$Destination, [string[]]$Names)
    # Two ways to build the archive. Compress-Archive is in every PowerShell, and on a 140 MB exe
    # that was published a second ago it sometimes fails because Windows Defender still has the file
    # open - so it is retried. tar.exe is bsdtar, which ships with Windows 10 and later and knows
    # how to write a zip; it is the fallback.
    foreach ($name in $Names) { Say "  adding $name" "DarkGray" }
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        try {
            if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
            $paths = @($Names | ForEach-Object { Join-Path $Source $_ })
            # -LiteralPath only exists in PowerShell 6 and later, and people do run this script from
            # the Windows PowerShell that is on every desktop, so ask before using it.
            $params = @{ DestinationPath = $Destination; CompressionLevel = "Optimal" }
            if ((Get-Command Compress-Archive).Parameters.ContainsKey("LiteralPath")) {
                $params["LiteralPath"] = $paths
            } else {
                $params["Path"] = $paths
            }
            Compress-Archive @params
            Say "  Compress-Archive done (attempt $attempt)" "DarkGray"
            return
        } catch {
            Say "  Compress-Archive attempt $attempt failed: $($_.Exception.Message)" "DarkGray"
            Start-Sleep -Milliseconds 1000
        }
    }
    if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
        throw "no way to write ${Destination}: Compress-Archive failed and tar.exe is not installed"
    }
    $arguments = @("-a", "-c", "-f", $Destination, "-C", $Source, "--") + $Names
    $code = Invoke-Tool -Exe "tar.exe" -Arguments $arguments
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $Destination)) { throw "tar.exe failed with exit code $code" }
    Say "  tar.exe done" "DarkGray"
}

try {
    Set-Location $Root
    Say "build-win-$Arch $(Get-Date -Format 'o')"

    if ($Icons) { & (Join-Path $Root "scripts/make-icons.ps1") }

    # The word lists and the tray icons are embedded, so they must exist before the compile.
    foreach ($required in @("Resources/en_50k.txt", "Resources/fa_50k.txt", "Resources/AppIcon.ico",
                            "Resources/TrayIcon.ico", "Resources/TrayIconPaused.ico")) {
        if (-not (Test-Path (Join-Path $Root $required))) {
            throw "$required is missing. Run .\scripts\make-icons.ps1 to generate the icons."
        }
    }
    Say "required assets present"

    if (Test-Path $PublishDir) { Remove-Item -Recurse -Force $PublishDir }

    $arguments = @("publish", $Project, "-c", $Configuration, "-r", "win-$Arch", "-o", $PublishDir,
                   "--nologo", "-v", "minimal")
    if ($FrameworkDependent) {
        # -r alone means self-contained in .NET 8, so say otherwise, and keep the csproj's own
        # PublishSingleFile condition off: this build is a folder of small files.
        $arguments += @("--self-contained", "false", "-p:FrameworkDependent=true")
    } else {
        # One file, no runtime to install: the .NET host is packed inside the exe.
        $arguments += @("-p:PublishSingleFile=true", "-p:IncludeNativeLibrariesForSelfExtract=true")
    }

    Say "dotnet $($arguments -join ' ')" "DarkGray"
    $code = Invoke-Tool -Exe "dotnet" -Arguments $arguments
    if ($code -ne 0) { throw "dotnet publish failed with exit code $code" }

    $exe = Join-Path $PublishDir "LayoutFixer.exe"
    if (-not (Test-Path -LiteralPath $exe)) { throw "no LayoutFixer.exe in $PublishDir" }
    Say "built $PublishDir\LayoutFixer.exe ($([math]::Round((Get-Item -LiteralPath $exe).Length / 1MB, 1)) MB)" "Green"

    if ($Zip) {
        $zip = Join-Path $BuildDir "LayoutFixer-$Version-win-$Arch.zip"
        $names = @("LayoutFixer.exe")
        if ($FrameworkDependent) {
            # A framework-dependent build is a handful of files that belong next to each other.
            $names = @(Get-ChildItem -LiteralPath $PublishDir -File | ForEach-Object { $_.Name })
        }
        New-Zip -Source $PublishDir -Destination $zip -Names $names
        Say "built $zip ($([math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1)) MB)" "Green"
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
    Say "FAILED: $($_.Exception.Message)" "Red"
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Say "  $($_.InvocationInfo.PositionMessage)" "DarkGray"
    }
    if ($_.ScriptStackTrace) { Say "  stack: $($_.ScriptStackTrace)" "DarkGray" }
    Say "  transcript: $Transcript" "DarkGray"
    throw
}
