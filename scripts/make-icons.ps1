# Regenerates the icons in Resources/ from icon/make_icon.py.
#
#   .\scripts\make-icons.ps1
#
# Needs Python 3 with Pillow (and arabic-reshaper + python-bidi for joined Persian letters):
#   python -m pip install pillow arabic-reshaper python-bidi

param([string]$Python = "python")

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

& $Python -c "import PIL" 1>$null 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Pillow is missing. Run: $Python -m pip install pillow arabic-reshaper python-bidi"
}

& $Python icon/make_icon.py .
if ($LASTEXITCODE -ne 0) { throw "icon generation failed" }

Write-Host "icons updated"
