#!/usr/bin/env python3
"""Cuts Fusion Pixel down to the characters the app is likely to show, for the 像素 theme.

Keeps ASCII and Latin-1, general and CJK punctuation, full-width forms, arrows / box drawing / geometric shapes,
every GB2312 character (6,763 common hanzi), and every character that appears in Sources/. Anything else
(rare hanzi in a file name, say) falls back to the system font. The font declares no Reserved Font Name, so the
OFL allows this cut under the same name; the license files ship with the app as before.

  python3 -m venv /tmp/fontenv && /tmp/fontenv/bin/pip install fonttools==4.55.3
  /tmp/fontenv/bin/python scripts/subset-pixel-font.py
"""
import pathlib, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
source = root / "third_party/fonts/fusion-pixel-12px-monospaced-zh_hans.otf"
target = root / "Sources/Folmi/Resources/Fonts/fusion-pixel-12px-monospaced-zh_hans.otf"

codepoints = set(range(0x20, 0x7F)) | set(range(0xA0, 0x100))
for start, end in [(0x2000, 0x206F), (0x2190, 0x21FF), (0x2200, 0x22FF), (0x2300, 0x23FF), (0x2460, 0x24FF),
                   (0x2500, 0x25FF), (0x2600, 0x26FF), (0x2700, 0x27BF), (0x3000, 0x303F), (0xFF00, 0xFFEF)]:
    codepoints |= set(range(start, end + 1))
for high in range(0xA1, 0xF8):
    for low in range(0xA1, 0xFF):
        try: codepoints |= {ord(c) for c in bytes([high, low]).decode("gb2312")}
        except UnicodeDecodeError: pass
for path in (root / "Sources").rglob("*.swift"):
    codepoints |= {ord(c) for c in path.read_text(encoding="utf-8")}

unicodes = ",".join(f"U+{c:04X}" for c in sorted(codepoints))
target.parent.mkdir(parents=True, exist_ok=True)
subprocess.run([str(pathlib.Path(sys.executable).parent / "pyftsubset"), str(source), f"--unicodes={unicodes}",
                f"--output-file={target}", "--layout-features=*", "--name-IDs=*", "--name-languages=*", "--notdef-outline",
                "--glyph-names", "--no-hinting"], check=True)
print(f"{source.stat().st_size / 1e6:.1f} MB → {target.stat().st_size / 1e6:.1f} MB ({len(codepoints)} code points)")
