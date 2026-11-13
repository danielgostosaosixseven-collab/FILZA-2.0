#!/usr/bin/env python3
"""Validate critical resources and pixel identity of Filza PNG assets in an unsigned IPA."""
from __future__ import annotations

import argparse
import hashlib
import re
import struct
import sys
import zipfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ANTICRACK = ROOT / "ThreeOneOSFive/helpers/AntiCrack.swift"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
APPROVED_TUTORIAL_SHA256 = {
    "Tutorials/tutorial_error_others.mov": "d040ecca2f28bc5ab0557b5cf0431df71e77588cc251410ef84df3140259dc6a",
    "Tutorials/tutorial_ffth_ffmax.mov": "5d575f121beb72dd5c02fa7714e551219d7884827a9e6b3611e316f6977f24b3",
    "Tutorials/tutorial_ap.mov": "c9bbac6eac8410723e7dca84d6eba7e887cbe1dc3e2c31bcc19c91f9724b7441",
    "Tutorials/tutorial_error_banner.jpg": "66acbea6c9a19551b0e19ca4f5e02b8c6e769a29240601b1312d44be2f9711fd",
    "Tutorials/tutorial_ffth_banner.jpg": "2b702af53bcf03d29e46fcee4fbea43283802ec27bdbf64767138bb2ce30693f",
    "Tutorials/tutorial_ap_banner.jpg": "c444140ce5def6629db293bcf724ffdeaa7b0a5a78b33b0b3d728c9c0d479f1a",
}


def critical_specs() -> list[tuple[str, str, int, int, bytes]]:
    source = ANTICRACK.read_text(encoding="utf-8")
    match = re.search(r"static let criticalFiles: \[String\]\s*=\s*\[(.*?)\]", source, re.S)
    if not match:
        raise ValueError("criticalFiles manifest not found in AntiCrack.swift")
    values = re.findall(r'"([^"\n]+)"', match.group(1))
    specs = []
    for value in values:
        parts = value.split("|")
        if len(parts) < 5:
            raise ValueError("malformed criticalFiles entry: " + value)
        relative_path, extension, min_size, max_size, signature_hex = parts[:5]
        specs.append((relative_path, extension.lower(), int(min_size), int(max_size), bytes.fromhex(signature_hex)))
    if not specs:
        raise ValueError("criticalFiles manifest is empty")
    return specs


def signature_matches(data: bytes, extension: str, signature: bytes) -> bool:
    # ISO-BMFF MOV/MP4/M4V files put `ftyp` after a four-byte box length.
    offset = 4 if extension.lower() in {"mov", "mp4", "m4v"} else 0
    return bool(signature) and data[offset : offset + len(signature)] == signature


def paeth(a: int, b: int, c: int) -> int:
    estimate = a + b - c
    da, db, dc = abs(estimate - a), abs(estimate - b), abs(estimate - c)
    return a if da <= db and da <= dc else b if db <= dc else c


def decode_png(data: bytes, label: str) -> tuple[int, int, bytes]:
    """Decode standard PNG or Apple's CgBI PNG into canonical RGBA pixels."""
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("PNG signature missing: " + label)
    pos = len(PNG_SIGNATURE)
    header = None
    palette = b""
    transparency = b""
    compressed = bytearray()
    saw_cgbi = False
    saw_end = False
    try:
        while pos + 12 <= len(data):
            length = struct.unpack(">I", data[pos : pos + 4])[0]
            kind = data[pos + 4 : pos + 8]
            end = pos + length + 12
            if end > len(data):
                raise ValueError("truncated PNG chunk: " + label)
            payload = data[pos + 8 : pos + 8 + length]
            crc = struct.unpack(">I", data[pos + 8 + length : end])[0]
            if (zlib.crc32(kind + payload) & 0xFFFFFFFF) != crc:
                raise ValueError("PNG chunk CRC mismatch: " + label)
            if kind == b"CgBI":
                saw_cgbi = True
            elif kind == b"IHDR":
                header = struct.unpack(">IIBBBBB", payload)
            elif kind == b"PLTE":
                palette = payload
            elif kind == b"tRNS":
                transparency = payload
            elif kind == b"IDAT":
                compressed.extend(payload)
            elif kind == b"IEND":
                saw_end = True
                pos = end
                break
            pos = end
        if header is None or not saw_end or pos != len(data):
            raise ValueError("incomplete or trailing PNG data: " + label)
        width, height, depth, color_type, compression, filtering, interlace = header
        if depth != 8 or compression != 0 or filtering != 0 or interlace != 0:
            raise ValueError("unsupported PNG encoding: " + label)
        if saw_cgbi and color_type != 6:
            raise ValueError("unsupported Apple CgBI color type: " + label)
        channels_by_type = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
        channels = channels_by_type.get(color_type)
        if channels is None:
            raise ValueError("unsupported PNG color type: " + label)
        raw = zlib.decompress(bytes(compressed), -15 if saw_cgbi else zlib.MAX_WBITS)
        stride = width * channels
        if len(raw) != height * (stride + 1):
            raise ValueError("PNG pixel data length mismatch: " + label)
        unfiltered = bytearray(height * stride)
        previous = bytearray(stride)
        offset = 0
        for y in range(height):
            filter_type = raw[offset]
            offset += 1
            row = bytearray(raw[offset : offset + stride])
            offset += stride
            for x in range(stride):
                left = row[x - channels] if x >= channels else 0
                above = previous[x]
                upper_left = previous[x - channels] if x >= channels else 0
                if filter_type == 1:
                    row[x] = (row[x] + left) & 255
                elif filter_type == 2:
                    row[x] = (row[x] + above) & 255
                elif filter_type == 3:
                    row[x] = (row[x] + (left + above) // 2) & 255
                elif filter_type == 4:
                    row[x] = (row[x] + paeth(left, above, upper_left)) & 255
                elif filter_type != 0:
                    raise ValueError("unknown PNG filter in " + label)
            unfiltered[y * stride : (y + 1) * stride] = row
            previous = row

        rgba = bytearray(width * height * 4)
        for index in range(width * height):
            base = index * channels
            if color_type == 0:
                gray = unfiltered[base]
                red = green = blue = gray
                alpha = 255
            elif color_type == 2:
                red, green, blue = unfiltered[base : base + 3]
                alpha = 255
            elif color_type == 3:
                palette_index = unfiltered[base]
                p = palette_index * 3
                if p + 3 > len(palette):
                    raise ValueError("PNG palette index out of bounds: " + label)
                red, green, blue = palette[p : p + 3]
                alpha = transparency[palette_index] if palette_index < len(transparency) else 255
            elif color_type == 4:
                gray, alpha = unfiltered[base : base + 2]
                red = green = blue = gray
            elif color_type == 6:
                if saw_cgbi:
                    blue, green, red, alpha = unfiltered[base : base + 4]
                    if alpha not in (0, 255):
                        red = min(255, (red * 255 + alpha // 2) // alpha)
                        green = min(255, (green * 255 + alpha // 2) // alpha)
                        blue = min(255, (blue * 255 + alpha // 2) // alpha)
                else:
                    red, green, blue, alpha = unfiltered[base : base + 4]
            rgba[index * 4 : index * 4 + 4] = bytes((red, green, blue, alpha))
        return width, height, bytes(rgba)
    except (struct.error, zlib.error) as exc:
        raise ValueError("PNG compressed data is invalid: " + label) from exc


def validate_signature_cases() -> None:
    cases = (
        (b"\x00\x00\x00\x14ftypisom", "mov", b"ftyp", True),
        (b"\x00\x00\x00\x14ftypisom", "mp4", b"ftyp", True),
        (b"\x00\x00\x00\x14ftypisom", "m4v", b"ftyp", True),
        (b"\x00\x00\x00\x14nopeisom", "mov", b"ftyp", False),
        (b"\x00\x00\x00\x14nopeisom", "mp4", b"ftyp", False),
        (b"\x00\x00\x00\x14nopeisom", "m4v", b"ftyp", False),
        (b"\xff\xd8\xff\xe0jpeg", "jpg", b"\xff\xd8\xff", True),
        (b"\xff\xd9\xff\xe0jpeg", "jpg", b"\xff\xd8\xff", False),
        (PNG_SIGNATURE + b"rest", "png", PNG_SIGNATURE, True),
    )
    for data, extension, signature, expected in cases:
        if signature_matches(data, extension, signature) is not expected:
            raise ValueError("resource signature self-test failed for " + extension)


def validate_source() -> None:
    for relative_path, extension, min_size, max_size, signature in critical_specs():
        path = ROOT / "ThreeOneOSFive" / relative_path
        if not path.is_file():
            raise ValueError("critical resource missing from source: " + relative_path)
        data = path.read_bytes()
        if not signature_matches(data, extension, signature):
            raise ValueError("critical resource signature mismatch in source: " + relative_path)
        approved_hash = APPROVED_TUTORIAL_SHA256.get(relative_path)
        if approved_hash and hashlib.sha256(data).hexdigest() != approved_hash:
            raise ValueError("tutorial resource differs from the approved original: " + relative_path)
        if extension == "png":
            decode_png(data, "source/" + relative_path)
        if not min_size <= len(data) <= max_size:
            print(f"WARN size outside reference range (runtime logs only): {relative_path} ({len(data)} bytes)")
        print(f"OK source: {relative_path} ({len(data)} bytes)")


def validate_ipa(ipa_path: Path) -> None:
    with zipfile.ZipFile(ipa_path) as archive:
        names = archive.namelist()
        info_plists = [name for name in names if name.startswith("Payload/") and name.endswith(".app/Info.plist")]
        if len(info_plists) != 1:
            raise ValueError(f"expected one app Info.plist inside Payload; found {len(info_plists)}")
        app_prefix = info_plists[0][: -len("Info.plist")]
        for relative_path, extension, min_size, max_size, signature in critical_specs():
            try:
                data = archive.read(app_prefix + relative_path)
            except KeyError as exc:
                raise ValueError("critical resource missing from IPA: " + relative_path) from exc
            if not signature_matches(data, extension, signature):
                raise ValueError("critical resource signature mismatch in IPA: " + relative_path)
            approved_hash = APPROVED_TUTORIAL_SHA256.get(relative_path)
            if approved_hash and hashlib.sha256(data).hexdigest() != approved_hash:
                raise ValueError("tutorial resource differs from the approved original in IPA: " + relative_path)
            if extension == "png":
                actual = decode_png(data, "IPA/" + relative_path)
                expected = decode_png((ROOT / "ThreeOneOSFive" / relative_path).read_bytes(), "source/" + relative_path)
                if actual != expected:
                    raise ValueError("PNG pixels differ from approved Filza source: " + relative_path)
            if not min_size <= len(data) <= max_size:
                print(f"WARN size outside reference range (runtime logs only): {relative_path} ({len(data)} bytes)")
            print(f"OK IPA: {relative_path} ({len(data)} bytes)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", nargs="?", type=Path, help="unsigned IPA to inspect")
    parser.add_argument("--source-only", action="store_true", help="validate resources in the checked-out source tree")
    args = parser.parse_args()
    try:
        validate_signature_cases()
        if args.source_only:
            validate_source()
        elif args.ipa:
            validate_ipa(args.ipa)
        else:
            parser.error("provide an IPA path or --source-only")
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        print("ERROR:", exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
