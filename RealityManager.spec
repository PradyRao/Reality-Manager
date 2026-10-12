# -*- mode: python ; coding: utf-8 -*-
from pathlib import Path
import sys

root = Path(SPECPATH)
res = root / "reality_manager" / "resources"

a = Analysis(
    [str(root / "run.py")],
    pathex=[str(root)],
    binaries=[],
    datas=[(str(res / "reality-deploy.sh"), "resources")],
    hiddenimports=["keyring.backends.Windows", "keyring.backends.macOS"],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name="Reality Manager",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,
)

if sys.platform == "darwin":
    app = BUNDLE(
        exe,
        name="Reality Manager.app",
        bundle_identifier="com.realitymanager.desktop",
        info_plist={
            "NSHighResolutionCapable": True,
            "LSMinimumSystemVersion": "12.0",
        },
    )
