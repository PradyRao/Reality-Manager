#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -d .venv ]; then python3 -m venv .venv; fi
. .venv/bin/activate
python -m pip install --upgrade pip
pip install -r requirements.txt
pyinstaller --noconfirm --clean RealityManager.spec
printf '\nBuilt: dist/Reality Manager.app\n'
printf 'For distribution to other Macs, sign/notarize the app with your Apple Developer certificate.\n'
