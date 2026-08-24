#!/usr/bin/env python3
"""Make Yeet app icons fill the macOS 26 squircle.

macOS Tahoe treats an icon as "legacy" and draws it inset on a gray plate
when any edge pixel has alpha < 253, or when there is no Icon Composer
fill layer. This script:

1. Composites every AppIcon / AppIcon-Dev PNG onto opaque charcoal so
   every pixel is alpha 255 (full-bleed).
2. Writes Icon Composer bundles (charcoal fill + raster mascot) that
   Tahoe uses as the native filled icon. Sequoia still reads the
   flattened .appiconset.

Usage: python3 scripts/flatten-app-icons.py
"""

from __future__ import annotations

import json
import shutil
import struct
import subprocess
import tempfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "yeet" / "Assets.xcassets"
ICONSETS = (
    ASSETS / "AppIcon.appiconset",
    ASSETS / "AppIcon-Dev.appiconset",
)

# Corner color of the Yeet mark (~#141618). Fill + flatten both use this.
CHARCOAL = (20, 22, 24)
PNG_SIG = b"\x89PNG\r\n\x1a\n"


def load_png(path: Path):
    data = Path(path).read_bytes()
    assert data[:8] == PNG_SIG, f"{path} is not a PNG"
    off, width, height, color_type, idat = 8, 0, 0, 0, bytearray()
    while off < len(data):
        (length,) = struct.unpack(">I", data[off : off + 4])
        ctype = data[off + 4 : off + 8]
        cdata = data[off + 8 : off + 8 + length]
        off += 12 + length
        if ctype == b"IHDR":
            width, height, bit_depth, color_type, _c, _f, interlace = struct.unpack(
                ">IIBBBBB", cdata
            )
            assert bit_depth == 8 and interlace == 0, f"{path}: unsupported PNG"
        elif ctype == b"IDAT":
            idat += cdata
        elif ctype == b"IEND":
            break

    if color_type not in (2, 6):
        raise ValueError(f"{path}: color_type {color_type}")
    channels = {2: 3, 6: 4}[color_type]
    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    flat = bytearray(height * stride)
    pos = 0
    for y in range(height):
        ftype = raw[pos]
        pos += 1
        line = raw[pos : pos + stride]
        pos += stride
        ro, po = y * stride, (y - 1) * stride
        for i in range(stride):
            x = line[i]
            a = flat[ro + i - channels] if i >= channels else 0
            b = flat[po + i] if y > 0 else 0
            c = flat[po + i - channels] if (y > 0 and i >= channels) else 0
            if ftype == 0:
                r = x
            elif ftype == 1:
                r = x + a
            elif ftype == 2:
                r = x + b
            elif ftype == 3:
                r = x + ((a + b) >> 1)
            elif ftype == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                r = x + (a if (pa <= pb and pa <= pc) else (b if pb <= pc else c))
            else:
                raise ValueError(f"bad filter {ftype}")
            flat[ro + i] = r & 0xFF

    if channels == 4:
        return width, height, flat
    rgba = bytearray(width * height * 4)
    for px in range(width * height):
        rgba[px * 4 : px * 4 + 3] = flat[px * 3 : px * 3 + 3]
        rgba[px * 4 + 3] = 255
    return width, height, rgba


def save_png(path: Path, width: int, height: int, rgba: bytearray) -> None:
    stride = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += rgba[y * stride : (y + 1) * stride]

    def chunk(ctype, cdata):
        return (
            struct.pack(">I", len(cdata))
            + ctype
            + cdata
            + struct.pack(">I", zlib.crc32(ctype + cdata) & 0xFFFFFFFF)
        )

    path.write_bytes(
        PNG_SIG
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def sips_png(src: Path, dst: Path, size: int | None = None) -> None:
    cmd = ["sips", "-s", "format", "png"]
    if size is not None:
        cmd += ["-z", str(size), str(size)]
    cmd += [str(src), "--out", str(dst)]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def flatten_rgba(rgba: bytearray) -> bytearray:
    cr, cg, cb = CHARCOAL
    out = bytearray(len(rgba))
    for i in range(0, len(rgba), 4):
        a = rgba[i + 3]
        if a == 255:
            out[i : i + 4] = rgba[i : i + 4]
            continue
        t = a / 255.0
        out[i] = int(rgba[i] * t + cr * (1 - t) + 0.5)
        out[i + 1] = int(rgba[i + 1] * t + cg * (1 - t) + 0.5)
        out[i + 2] = int(rgba[i + 2] * t + cb * (1 - t) + 0.5)
        out[i + 3] = 255
    return out


def flatten_iconset(iconset: Path, tmp: Path) -> Path:
    """Rewrite every PNG in *iconset* as opaque charcoal-composited RGBA.

    Returns the flattened 1024×1024 master.
    """
    contents = json.loads((iconset / "Contents.json").read_text())
    master_1024 = None
    for img in contents["images"]:
        name = img["filename"]
        src = iconset / name
        side = int(img["size"].split("x")[0]) * int(img["scale"].rstrip("x"))
        converted = tmp / f"{iconset.name}-{name}"
        sips_png(src, converted)
        w, h, rgba = load_png(converted)
        if (w, h) != (side, side):
            # Force exact catalog size after flatten.
            flat_tmp = tmp / f"flat-{name}"
            save_png(flat_tmp, w, h, flatten_rgba(rgba))
            sized = tmp / f"sized-{name}"
            sips_png(flat_tmp, sized, side)
            _, _, rgba = load_png(sized)
            rgba = flatten_rgba(rgba)
        else:
            rgba = flatten_rgba(rgba)
        save_png(src, side, side, rgba)
        print(f"  {iconset.name}/{name}  {side}x{side} opaque")
        if side == 1024:
            master_1024 = src
    if master_1024 is None:
        raise SystemExit(f"{iconset}: no 1024 master")
    return master_1024


def write_icon_bundle(name: str, master: Path) -> None:
    bundle = ROOT / f"{name}.icon"
    assets = bundle / "Assets"
    if bundle.exists():
        shutil.rmtree(bundle)
    assets.mkdir(parents=True)
    shutil.copy2(master, assets / "mascot.png")
    cr, cg, cb = CHARCOAL
    fill = f"srgb:{cr/255:.5f},{cg/255:.5f},{cb/255:.5f},1.00000"
    # Schema matches Icon Composer documents (see
    # peterpoliwoda/icon-composer-template). `shadow` must be an object;
    # a string made actool abort with a nil insertion.
    manifest = {
        "fill": {"solid": fill},
        "groups": [
            {
                "layers": [
                    {
                        "glass": False,
                        "hidden": False,
                        "image-name": "mascot.png",
                        "name": "Mascot",
                        "position": {
                            "scale": 1,
                            "translation-in-points": [0, 0],
                        },
                    }
                ],
                "shadow": {"kind": "none", "opacity": 0},
                "specular": False,
                "translucency": {"enabled": False, "value": 0.5},
            }
        ],
        "supported-platforms": {"squares": "shared"},
    }
    (bundle / "icon.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"  wrote {bundle.relative_to(ROOT)}")


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        masters = {}
        for iconset in ICONSETS:
            print(f"flatten {iconset.name}")
            masters[iconset.name] = flatten_iconset(iconset, tmp)
        write_icon_bundle("AppIcon", masters["AppIcon.appiconset"])
        write_icon_bundle("AppIcon-Dev", masters["AppIcon-Dev.appiconset"])


if __name__ == "__main__":
    main()
