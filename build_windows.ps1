$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
if (!(Test-Path .venv)) { py -3 -m venv .venv }
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\pip.exe install -r requirements.txt
.\.venv\Scripts\pyinstaller.exe --noconfirm --clean RealityManager.spec
Write-Host "Built: dist\Reality Manager.exe"
