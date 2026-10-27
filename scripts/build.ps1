# Builds the Windows app: LayoutFixer.exe in build\publish, and a release zip in build\.
#
#   .\scripts\build.ps1                    self-contained single exe, win-x64 (nothing to install)
#   .\scripts\build.ps1 -Arch arm64        the same, for Windows on Arm
#   .\scripts\build.ps1 -FrameworkDependent  a few hundred KB, but needs the .NET 8 Desktop Runtime
#   .\scripts\build.ps1 -Zip -Icons        regenerate the .ico files first, then build and zip
#   .\scripts\build.ps1 -Test              build, then print what the detector makes of a sample
#   .\scripts\build.ps1 -Open              build and start it
#
# Needs the .NET 8 SDK and nothing else:  winget install Microsoft.DotNet.SDK.8
# Visual Studio is not required; the app has no designer files and no NuGet dependencies.

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

# pwsh turns a native command's stderr into a terminating error while $ErrorActionPreference is
# Stop, and MSBuild writes plenty to stderr on a build that is perfectly fine. So the tool is
# judged by its exit code, and its whole output is kept in build\publish-win-<arch>.log for CI to
# point at.
function Invoke-DotNet {
    param([string[]]$Arguments, [string]$LogFile)
    $output = @()
    $code = 0
    $global:ErrorActionPreference = "Continue"
    # Same trap, newer pwsh: this preference makes a nonzero native exit code a PowerShell error.
    $global:PSNativeCommandUseErrorActionPreference = $false
    try {
        $output = & dotnet @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $global:ErrorActionPreference = "Stop"
    }
    if ($LogFile) { $output | Set-Content -LiteralPath $LogFile -Encoding utf8 }
    $output | ForEach-Object { Write-Host $_ }
    return $code
}
$Root = Split-Path -Parent $PSScriptRoot
$Project = Join-Path $Root "Sources/LayoutFixer/LayoutFixer.csproj"
$BuildDir = Join-Path $Root "build"
$PublishDir = Join-Path $BuildDir "publish-win-$Arch"

Set-Location $Root

if ($Icons) { & (Join-Path $Root "scripts/make-icons.ps1") }

# The word lists and the tray icon are embedded, so they must exist before the compile.
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
    $arguments += "-p:FrameworkDependent=true"
} else {
    # One file, no runtime to install: the .NET host is packed inside the exe.
    $arguments += @("-p:PublishSingleFile=true", "-p:IncludeNativeLibrariesForSelfExtract=true")
}

Write-Host "dotnet $($arguments -join ' ')" -ForegroundColor DarkGray
$publishLog = Join-Path $BuildDir "publish-win-$Arch.log"
$code = Invoke-DotNet -Arguments $arguments -LogFile $publishLog
if ($code -ne 0) { throw "dotnet publish failed with exit code $code; see $publishLog" }

$exe = Join-Path $PublishDir "LayoutFixer.exe"
if (-not (Test-Path $exe)) { throw "no LayoutFixer.exe in $PublishDir" }
$size = [math]::Round((Get-Item $exe).Length / 1MB, 1)
Write-Host "built $exe  ($size MB)" -ForegroundColor Green

if ($Zip) {
    $zip = Join-Path $BuildDir "LayoutFixer-$Version-win-$Arch.zip"
    if (Test-Path $zip) { Remove-Item -Force $zip }
    if ($FrameworkDependent) {
        # A framework-dependent build is a handful of files that belong next to each other.
        Compress-Archive -Path (Join-Path $PublishDir "*") -DestinationPath $zip
    } else {
        # Single file: the zip holds exactly one exe, like the macOS build's zip holds one .app.
        Compress-Archive -Path $exe -DestinationPath $zip
    }
    Write-Host "built $zip" -ForegroundColor Green
}

if ($Test) {
    $log = Join-Path $env:TEMP "layoutfixer-test.txt"
    # A windowless exe is not waited for by PowerShell, so go through Start-Process.
    Start-Process -FilePath $exe -ArgumentList ('--test "{0}"' -f $TestText) `
                  -NoNewWindow -Wait -RedirectStandardOutput $log
    Get-Content $log
}

if ($Open) { Start-Process $exe }
