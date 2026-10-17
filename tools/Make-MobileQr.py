"""Make-MobileQr.py -- QR codes for installing RustDesk on a phone or tablet.

Writes src/mobile/rustdesk-android.png and rustdesk-ios.png (shown by Desk Console) and the
same at installer size in installer/mobile/*.png; tools/Convert-QrBmp.ps1 then turns those into
the .bmp files the installer page shows. Needs the pure-Python 'segno' package:
    python -m pip install segno            (or --target <dir> and set PYTHONPATH)
    python tools/Make-MobileQr.py
    powershell -ExecutionPolicy Bypass -File tools/Convert-QrBmp.ps1

RustDesk is NOT on Google Play (removed in 2023); Android installs come from RustDesk's
GitHub release (the APK) or F-Droid. Keep the APK version equal to the bundled RustDesk MSI
(tools/Get-Redist.ps1); tools/Test-Pins.ps1 checks this link and decodes the images to compare.
"""
import io
import pathlib
import segno

LINKS = {
    # arm64: every current phone and foldable; same version as the PCs' RustDesk
    "android": "https://github.com/rustdesk/rustdesk/releases/download/1.5.0/rustdesk-1.5.0-aarch64-signed.apk",
    "ios": "https://apps.apple.com/app/rustdesk-remote-desktop/id1581225015",
}

root = pathlib.Path(__file__).resolve().parent.parent
out = root / "src" / "mobile"            # Desk Console: 5 px per module
inst = root / "installer" / "mobile"     # installer page: 3 px per module (the page is small); exact
out.mkdir(parents=True, exist_ok=True)   # integer scales only -- a resized QR code scans badly
inst.mkdir(parents=True, exist_ok=True)
for name, url in LINKS.items():
    qr = segno.make(url, error="m")
    qr.save(str(out / f"rustdesk-{name}.png"), scale=5, border=3)
    qr.save(str(inst / f"rustdesk-{name}.png"), scale=3, border=2)
    print(f"{name}: version {qr.designator}  {url}")
print("Then convert installer\\mobile\\*.png to 24-bit .bmp (tools\\Convert-QrBmp.ps1) for the Inno page.")
