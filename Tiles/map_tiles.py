#!/usr/bin/env python3
"""
stm32_tiles.py - pack 256x256 XYZ map tiles into one file per zoom level
for the STM32F746G-DISCO moving map (480x272 LCD, bare-metal Ada).

Output (copy to the root of the microSD card):
    Z08.BIN .. Z12.BIN   one file per zoom, 8.3 names (no long-file-name support needed)
    MAPINFO.TXT          human-readable summary
    preview_zNN.png      (with --preview) mosaics decoded back from the .BIN files

File layout (all little-endian):
    bytes 0..2047        header (4 SD sectors), see map_tiles.ads
    bytes 2048..         fixed-size tile records, row-major over the tile grid:
                         offset = 2048 + ((y - y_min) * width + (x - x_min)) * record_size
                         RGB565: 131072 bytes/tile, L8: 65536 bytes/tile
                         Missing tiles are all zeros (black).

Tile sources (pick one with --source):
    a directory of {z}/{x}/{y}.png|.jpg|.webp   (e.g. gdal2tiles.py --xyz output)
    an .mbtiles file with raster tiles          (e.g. chartmaker output)
    a URL template on THIS computer, such as http://localhost:8080/styles/dark/{z}/{x}/{y}.png
    (only localhost is accepted: public OSM tile servers forbid bulk/offline downloading)

Examples:
    python3 stm32_tiles.py --source tiles_faa/ --out sdcard/ --preview
    python3 stm32_tiles.py --source nyc_dark.mbtiles --format l8 --out sdcard/
    python3 stm32_tiles.py --source "http://localhost:8080/styles/dark/{z}/{x}/{y}.png" --out sdcard/
"""

import argparse
import io
import math
import os
import sqlite3
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request

import numpy as np
from PIL import Image

TILE = 256
HEADER_SIZE = 2048            # 4 x 512-byte sectors, keeps every tile sector-aligned
MAGIC = b"ADSBMAP1"
VERSION = 1
FMT_RGB565, FMT_L8 = 0, 1
RECORD_SIZE = {FMT_RGB565: TILE * TILE * 2, FMT_L8: TILE * TILE}
PALETTE_OFFSET = 64
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1"}

NYC = (40.7128, -74.0060)


# --------------------------------------------------------------------------- geometry

def lonlat_to_tile(lon, lat, z):
    """Web Mercator (XYZ, y grows southward) tile containing lon/lat."""
    n = 1 << z
    lat = max(min(lat, 85.05112878), -85.05112878)
    x = int((lon + 180.0) / 360.0 * n)
    y = int((1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n)
    return min(max(x, 0), n - 1), min(max(y, 0), n - 1)


def tile_grid(bbox, z):
    """(x_min, y_min, width, height) of the tiles covering bbox = (west, south, east, north)."""
    west, south, east, north = bbox
    x0, y0 = lonlat_to_tile(west, north, z)
    x1, y1 = lonlat_to_tile(east, south, z)
    return x0, y0, x1 - x0 + 1, y1 - y0 + 1


def bbox_from_center(lat, lon, radius_mi):
    km = radius_mi * 1.609344
    dlat = km / 111.32
    dlon = km / (111.32 * math.cos(math.radians(lat)))
    return (lon - dlon, lat - dlat, lon + dlon, lat + dlat)


# --------------------------------------------------------------------------- sources

class DirSource:
    EXTS = (".png", ".jpg", ".jpeg", ".webp")

    def __init__(self, root, tms):
        self.root, self.tms = root, tms

    def get(self, z, x, y):
        yy = (1 << z) - 1 - y if self.tms else y
        for ext in self.EXTS:
            path = os.path.join(self.root, str(z), str(x), f"{yy}{ext}")
            if os.path.isfile(path):
                return Image.open(path)
        return None


class MBTilesSource:
    """MBTiles always stores rows in TMS order (y grows northward)."""

    def __init__(self, path):
        self.db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        row = self.db.execute("SELECT value FROM metadata WHERE name='format'").fetchone()
        if row and row[0].lower() in ("pbf", "mvt"):
            sys.exit(f"{path} holds vector tiles. Render them to PNG first "
                     "(e.g. with TileServer GL), then point --source at the rendered tiles.")

    def get(self, z, x, y):
        row = self.db.execute(
            "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?",
            (z, x, (1 << z) - 1 - y)).fetchone()
        return Image.open(io.BytesIO(row[0])) if row else None


class LocalUrlSource:
    def __init__(self, template):
        host = urllib.parse.urlsplit(
            template.replace("{z}", "0").replace("{x}", "0").replace("{y}", "0")).hostname
        if host not in LOCAL_HOSTS:
            sys.exit(f"Refusing to download from {host}: only a tile server running on this "
                     "computer is allowed. Public OpenStreetMap tile servers prohibit bulk/offline "
                     "downloading and block clients that do it. Render tiles locally instead "
                     "(see README).")
        self.template = template

    def get(self, z, x, y):
        url = self.template.format(z=z, x=x, y=y)
        try:
            with urllib.request.urlopen(url, timeout=60) as resp:
                return Image.open(io.BytesIO(resp.read()))
        except urllib.error.HTTPError as err:
            if err.code in (204, 404):
                return None
            raise


def open_source(spec, tms):
    if spec.startswith(("http://", "https://")):
        return LocalUrlSource(spec)
    if spec.lower().endswith(".mbtiles"):
        return MBTilesSource(spec)
    if os.path.isdir(spec):
        return DirSource(spec, tms)
    sys.exit(f"--source {spec!r} is not a directory, .mbtiles file or local URL template")


# --------------------------------------------------------------------------- pixel work

def prepare(img, dim):
    """RGB, 256x256, optionally darkened. Returns an HxWx3 uint8 array."""
    img = img.convert("RGB")
    if img.size != (TILE, TILE):
        img = img.resize((TILE, TILE), Image.Resampling.LANCZOS)
    arr = np.asarray(img, dtype=np.uint8)
    if dim < 1.0:
        arr = (arr.astype(np.float32) * dim + 0.5).astype(np.uint8)
    return arr


def to_rgb565(arr):
    a = arr.astype(np.uint16)
    v = ((a[..., 0] >> 3) << 11) | ((a[..., 1] >> 2) << 5) | (a[..., 2] >> 3)
    return v.astype("<u2").tobytes()


def from_rgb565(buf):
    v = np.frombuffer(buf, dtype="<u2").reshape(TILE, TILE).astype(np.uint32)
    r, g, b = (v >> 11) & 0x1F, (v >> 5) & 0x3F, v & 0x1F
    rgb = np.stack([(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)], axis=-1)
    return rgb.astype(np.uint8)


def build_palette(source, grids, dim, max_samples=400):
    """One shared 255-colour palette for every zoom, so a single CLUT serves all files.
    Index 0 is reserved for black (missing tiles); real colours use 1..255."""
    coords = [(z, x0 + i % w, y0 + i // w)
              for z, (x0, y0, w, h) in grids.items() for i in range(w * h)]
    step = max(1, len(coords) // max_samples)
    samples = []
    for z, x, y in coords[::step]:
        img = source.get(z, x, y)
        if img is not None:
            samples.append(prepare(img, dim)[::2, ::2])     # every other pixel keeps exact colours
    if not samples:
        sys.exit("No tiles found in the source for this area and these zooms.")
    mosaic = Image.fromarray(np.concatenate(samples, axis=0))
    q = mosaic.quantize(colors=255, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    pal = q.getpalette()[: 255 * 3]
    pal += pal[-3:] * ((255 * 3 - len(pal)) // 3)           # pad if the source has few colours
    pal_img = Image.new("P", (1, 1))
    pal_img.putpalette(pal + pal[-3:])                        # entry 255 duplicates entry 254
    colours = [tuple(pal[i:i + 3]) for i in range(0, 255 * 3, 3)]
    return pal_img, colours


def to_l8(arr, pal_img):
    idx = np.asarray(Image.fromarray(arr).quantize(palette=pal_img, dither=Image.Dither.NONE),
                     dtype=np.uint8).copy()
    idx[idx == 255] = 254                                     # duplicate entry -> its twin
    return (idx + 1).tobytes()                                # shift past reserved black


# --------------------------------------------------------------------------- files

def header_bytes(z, fmt, grid, present, colours):
    x0, y0, w, h = grid
    hdr = bytearray(HEADER_SIZE)
    struct.pack_into("<8sHBBHH7I", hdr, 0, MAGIC, VERSION, z, fmt, TILE, 0,
                     x0, y0, w, h, RECORD_SIZE[fmt], HEADER_SIZE, present)
    if fmt == FMT_L8:
        entries = [0xFF000000] + [0xFF000000 | r << 16 | g << 8 | b for r, g, b in colours]
        struct.pack_into("<256I", hdr, PALETTE_OFFSET, *entries)
    return hdr


def write_zoom(path, source, z, grid, fmt, dim, pal_img, colours):
    x0, y0, w, h = grid
    blank = bytes(RECORD_SIZE[fmt])
    present = 0
    with open(path, "wb") as f:
        f.write(bytes(HEADER_SIZE))                           # placeholder until count is known
        for ty in range(h):
            for tx in range(w):
                img = source.get(z, x0 + tx, y0 + ty)
                if img is None:
                    f.write(blank)
                    continue
                arr = prepare(img, dim)
                f.write(to_rgb565(arr) if fmt == FMT_RGB565 else to_l8(arr, pal_img))
                present += 1
        f.seek(0)
        f.write(header_bytes(z, fmt, grid, present, colours))
    return present


def read_back_preview(path, png_path, max_px=2048):
    """Decode the .BIN exactly as the board would and save a mosaic PNG."""
    with open(path, "rb") as f:
        hdr = f.read(HEADER_SIZE)
        magic, ver, z, fmt, tile, _, x0, y0, w, h, rec, data_off, present = \
            struct.unpack_from("<8sHBBHH7I", hdr, 0)
        assert magic == MAGIC and data_off == HEADER_SIZE and rec == RECORD_SIZE[fmt]
        lut = None
        if fmt == FMT_L8:
            entries = struct.unpack_from("<256I", hdr, PALETTE_OFFSET)
            lut = np.array([[(e >> 16) & 255, (e >> 8) & 255, e & 255] for e in entries], np.uint8)
        cell = max(16, min(TILE, max_px // max(w, h)))
        mosaic = Image.new("RGB", (w * cell, h * cell))
        for i in range(w * h):
            buf = f.read(rec)
            if fmt == FMT_RGB565:
                rgb = from_rgb565(buf)
            else:
                rgb = lut[np.frombuffer(buf, np.uint8).reshape(TILE, TILE)]
            tile_img = Image.fromarray(rgb)
            if cell != TILE:
                tile_img = tile_img.resize((cell, cell), Image.Resampling.BILINEAR)
            mosaic.paste(tile_img, ((i % w) * cell, (i // w) * cell))
    mosaic.save(png_path)


# --------------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", required=True, help="tile directory, .mbtiles file, or localhost URL template")
    ap.add_argument("--out", default="sdcard", help="output folder (default: sdcard)")
    ap.add_argument("--zooms", default="8-12", help="zoom range, e.g. 8-12 (default) or 9-11")
    ap.add_argument("--center", default=f"{NYC[0]},{NYC[1]}", help="lat,lon of map centre (default: NYC)")
    ap.add_argument("--radius-mi", type=float, default=100.0, help="radius in statute miles (default: 100)")
    ap.add_argument("--bbox", help="west,south,east,north instead of --center/--radius-mi")
    ap.add_argument("--format", choices=["rgb565", "l8"], default="rgb565",
                    help="rgb565: 128 KB/tile, direct copy to frame buffer; "
                         "l8: 64 KB/tile + shared CLUT, cheap day/night by rewriting the CLUT")
    ap.add_argument("--dim", type=float, default=1.0,
                    help="bake in darkening, 0..1 (default 1 = none; prefer LTDC layer alpha on the board)")
    ap.add_argument("--tms", action="store_true", help="tile directory uses TMS rows (gdal2tiles without --xyz)")
    ap.add_argument("--preview", action="store_true", help="also write preview_zNN.png decoded from the .BIN files")
    args = ap.parse_args()

    z_lo, _, z_hi = args.zooms.partition("-")
    zooms = range(int(z_lo), int(z_hi or z_lo) + 1)
    if args.bbox:
        bbox = tuple(float(v) for v in args.bbox.split(","))
    else:
        lat, lon = (float(v) for v in args.center.split(","))
        bbox = bbox_from_center(lat, lon, args.radius_mi)
    if not 0.0 < args.dim <= 1.0:
        sys.exit("--dim must be between 0 and 1")

    fmt = FMT_RGB565 if args.format == "rgb565" else FMT_L8
    source = open_source(args.source, args.tms)
    grids = {z: tile_grid(bbox, z) for z in zooms}
    os.makedirs(args.out, exist_ok=True)

    pal_img, colours = (None, None)
    if fmt == FMT_L8:
        print("Building shared 256-colour palette ...")
        pal_img, colours = build_palette(source, grids, args.dim)

    lines = [f"bbox west,south,east,north = {', '.join(f'{v:.4f}' for v in bbox)}",
             f"format = {args.format}, record = {RECORD_SIZE[fmt]} bytes, header = {HEADER_SIZE} bytes",
             ""]
    total = 0
    for z, grid in grids.items():
        name = f"Z{z:02d}.BIN"
        path = os.path.join(args.out, name)
        x0, y0, w, h = grid
        print(f"{name}: x {x0}..{x0 + w - 1}, y {y0}..{y0 + h - 1} ({w}x{h} = {w * h} tiles) ...", flush=True)
        present = write_zoom(path, source, z, grid, fmt, args.dim, pal_img, colours)
        size = os.path.getsize(path)
        total += size
        line = (f"{name}  zoom {z:2d}  x_min {x0}  y_min {y0}  grid {w}x{h}  "
                f"tiles {present}/{w * h} present  {size / 2**20:.1f} MiB")
        print("   " + line)
        lines.append(line)
        if args.preview:
            read_back_preview(path, os.path.join(args.out, f"preview_z{z:02d}.png"))
    lines += ["", f"total {total / 2**20:.1f} MiB"]
    with open(os.path.join(args.out, "MAPINFO.TXT"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"Done: {total / 2**20:.1f} MiB in {args.out}/")


if __name__ == "__main__":
    main()