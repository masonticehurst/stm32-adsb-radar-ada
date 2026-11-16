#!/usr/bin/env python3
"""
render_pmtiles.py - render a Protomaps .pmtiles extract into 256x256 PNG map tiles
({z}/{x}/{y}.png, XYZ scheme) ready for stm32_tiles.py.

It runs MapLibre GL in a headless Chromium (via Playwright) with an official Protomaps
style flavour, so the tiles look like the Protomaps basemap: light, dark, white,
grayscale or black.

One-time setup on your PC:
    pip install playwright pillow numpy
    python3 -m playwright install chromium

Typical run (NYC extract made with `pmtiles extract`):
    python3 render_pmtiles.py --pmtiles nyc.pmtiles --flavor dark --out tiles_osm
    python3 stm32_tiles.py --source tiles_osm --out sdcard --preview

Notes:
  * The first run downloads three pinned JavaScript libraries from the npm registry
    (MapLibre GL 5.24.1, pmtiles 4.5.0, @protomaps/basemaps 5.7.2), checks their SHA-512
    hashes, and caches them next to this script in .render_cache/.
  * Labels are tuned for the 4.3-inch 480x272 screen by default: only city/town and
    state names, only places with at least --min-city-pop people, at fixed pixel sizes
    (--city-size, --state-size), brightened on the dark and black flavours. Use
    --labels all for the full Protomaps labelling, or --labels none for no text.
  * Labels need fonts and icons. By default the browser loads them from Protomaps'
    asset site; use --assets with a local clone of github.com/protomaps/basemaps-assets
    to work offline. --labels none needs no fonts at all.
  * --airspace draws FAA airspace outlines (Class B by default) into the tiles from the
    NASR "Class B,C,D,E Airspace Shape Files" zip (pip install pyshp) or a GeoJSON file.
  * --airports highlights and labels airports (rings, runways, identifiers; blue towered,
    magenta non-towered) from the NASR "Airports and Other Landing Facilities (APT)" CSV zip.
  * Already-rendered tiles are skipped, so an interrupted run can simply be restarted.
  * Map data (c) OpenStreetMap contributors, ODbL: show this attribution on the display.
"""

import argparse
import base64
import csv
import hashlib
import http.server
import io
import json
import os
import socketserver
import sys
import tarfile
import threading
import math
import re
import time
import urllib.parse
import urllib.request
import zipfile

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stm32_tiles import NYC, bbox_from_center, tile_grid  # noqa: E402  (same folder)

TILE = 256
FLAVORS = ("light", "dark", "white", "grayscale", "black")
HOSTED_ASSETS = "https://protomaps.github.io/basemaps-assets"
CACHE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".render_cache")

# Protomaps' population_rank: one more than the index of the highest break the
# population reaches (Places.java in github.com/protomaps/basemaps).
POP_BREAKS = (0, 200, 1_000, 2_000, 5_000, 10_000, 20_000, 50_000, 100_000, 200_000, 500_000,
              1_000_000, 5_000_000, 10_000_000, 20_000_000, 50_000_000, 100_000_000, 1_000_000_000)

# --label-color auto: (city colour, state colour). The dark styles draw labels in greys
# that almost disappear on a small LCD; the light styles are left as designed.
AUTO_LABEL_COLORS = {"dark": ("#c4c4c4", "#9a9a9a"), "black": ("#c4c4c4", "#9a9a9a")}


def population_rank(population):
    return sum(1 for b in POP_BREAKS if population >= b)

# package, tarball, sha512 integrity, {file inside tarball: cached name}
LIBRARIES = [
    ("maplibre-gl@5.24.1",
     "https://registry.npmjs.org/maplibre-gl/-/maplibre-gl-5.24.1.tgz",
     "HyiYBwtsbk3L1n1EPLJHWqdoyMiF80n7tEYXFZyu2m1TjvaNx6KMLiFeDdmszt1/mq2zvsR1TJuX/NMu5BonXQ==",
     {"package/dist/maplibre-gl.js": "maplibre-gl.js",
      "package/dist/maplibre-gl.css": "maplibre-gl.css"}),
    ("pmtiles@4.5.0",
     "https://registry.npmjs.org/pmtiles/-/pmtiles-4.5.0.tgz",
     "CBeD4SoUluFziGdy/8k7FOjQxQy486n+929W/tWophauvMICpkZ26vGBWhDt/6b1FZQWNaf4jFdT/5+q0Wii5w==",
     {"package/dist/pmtiles.js": "pmtiles.js"}),
    ("@protomaps/basemaps@5.7.2",
     "https://registry.npmjs.org/@protomaps/basemaps/-/basemaps-5.7.2.tgz",
     "K1Yk6bWdULulYg+R2QRVXx4NzJZan5YQhpejEG0c1/sXruJrfPIPZuakpf3jwAgVmjIRVQwAv+yRafDeN0aaUQ==",
     {"package/dist/basemaps.js": "basemaps.js"}),
]


# --------------------------------------------------------------------------- libraries

def ensure_libraries():
    os.makedirs(CACHE_DIR, exist_ok=True)
    for name, url, integrity, wanted in LIBRARIES:
        if all(os.path.isfile(os.path.join(CACHE_DIR, out)) for out in wanted.values()):
            continue
        print(f"Downloading {name} ...", flush=True)
        with urllib.request.urlopen(url, timeout=120) as resp:
            data = resp.read()
        if base64.b64encode(hashlib.sha512(data).digest()).decode() != integrity:
            sys.exit(f"{name}: download does not match its pinned SHA-512 hash; not using it.")
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
            for member, out in wanted.items():
                with tar.extractfile(member) as src, open(os.path.join(CACHE_DIR, out), "wb") as dst:
                    dst.write(src.read())


# --------------------------------------------------------------------------- local web server

PAGE = """<!doctype html>
<html><head><meta charset="utf-8">
<link rel="stylesheet" href="/lib/maplibre-gl.css">
<style>html,body{margin:0;padding:0;overflow:hidden;background:#000}
#map{position:absolute;left:0;top:0;width:%(size)dpx;height:%(size)dpx}</style>
<script src="/lib/maplibre-gl.js"></script>
<script src="/lib/pmtiles.js"></script>
<script src="/lib/basemaps.js"></script>
</head><body><div id="map"></div>
<script>
const cfg = %(cfg)s;
window.mapErrors = [];
const protocol = new pmtiles.Protocol();
maplibregl.addProtocol("pmtiles", protocol.tile);
let lyr = basemaps.layers("protomaps", basemaps.namedFlavor(cfg.flavor), {lang: cfg.lang});
if (cfg.labels === "none") {
  lyr = lyr.filter(l => l.type !== "symbol");
} else if (cfg.labels === "places") {
  const keep = new Set(["places_locality", "places_region", "places_country"]);
  lyr = lyr.filter(l => l.type !== "symbol" || keep.has(l.id));
  for (const l of lyr) {
    l.layout = l.layout || {};
    l.paint = l.paint || {};
    if (l.id === "places_locality") {
      l.filter = ["all", ["==", ["get", "kind"], "locality"],
                  [">=", ["coalesce", ["get", "population_rank"], 0], cfg.minRank]];
      l.layout["text-size"] = ["case", [">=", ["coalesce", ["get", "population_rank"], 0], cfg.bigRank],
                               cfg.bigCitySize, cfg.citySize];
      if (cfg.cityColor) l.paint["text-color"] = cfg.cityColor;
    } else if (l.id === "places_region" || l.id === "places_country") {
      l.layout["text-size"] = cfg.stateSize;
      if (cfg.stateColor) l.paint["text-color"] = cfg.stateColor;
    }
  }
}
const style = {
  version: 8,
  sources: {protomaps: {type: "vector", url: "pmtiles://" + location.origin + "/data/map.pmtiles"}},
  layers: lyr
};
if (cfg.labels !== "none" || cfg.airports) {
  const assets = cfg.assets.startsWith("/") ? location.origin + cfg.assets : cfg.assets;  // must be absolute
  style.glyphs = assets + "/fonts/{fontstack}/{range}.pbf";
  style.sprite = assets + "/sprites/v4/" + cfg.flavor;
}
if (cfg.airspace) {
  // Airspace outlines go above roads and water but below every label.
  style.sources.airspace = {type: "geojson", data: location.origin + "/data/airspace.geojson"};
  const firstLabel = style.layers.findIndex(l => l.type === "symbol");
  const asLayers = cfg.airspace.map(a => ({
    id: "airspace_" + a.cls, type: "line", source: "airspace",
    filter: ["==", ["get", "class"], a.cls],
    layout: {"line-join": "round", "line-cap": "round"},
    paint: Object.assign({"line-color": a.color, "line-width": a.width, "line-opacity": 0.9},
                         a.dash ? {"line-dasharray": a.dash} : {})
  }));
  style.layers.splice(firstLabel < 0 ? style.layers.length : firstLabel, 0, ...asLayers);
}
if (cfg.airports) {
  // Runways go with the airspace (under all labels); rings and identifiers go on top of
  // everything so airports win label collisions. Towered airports are listed last so
  // they are placed before non-towered ones.
  const A = cfg.airports;
  style.sources.airports = {type: "geojson", data: location.origin + "/data/airports.geojson"};
  const color = ["match", ["get", "cat"], "other", A.magenta, A.blue];
  const groups = [{id: "small", cats: ["other"], minzoom: A.smallZoom - 1},
                  {id: "big", cats: ["major", "towered"], minzoom: 0}];
  const runways = [], marks = [];
  for (const g of groups) {
    const inGroup = kind => ["all", ["==", ["get", "kind"], kind], ["in", ["get", "cat"], ["literal", g.cats]]];
    if (A.runways) runways.push({
      id: "airport_runways_" + g.id, type: "line", source: "airports", minzoom: g.minzoom,
      filter: inGroup("runway"), layout: {"line-cap": "round"},
      paint: {"line-color": color, "line-width": ["interpolate", ["linear"], ["zoom"], 7, 1.5, 11, 3.5]}});
    marks.push({
      id: "airport_rings_" + g.id, type: "circle", source: "airports", minzoom: g.minzoom,
      filter: inGroup("airport"),
      paint: {"circle-radius": ["match", ["get", "cat"], "major", 6, "towered", 4.5, 3.5],
              "circle-opacity": 0, "circle-stroke-width": 1.6, "circle-stroke-color": color}});
    marks.push({
      id: "airport_labels_" + g.id, type: "symbol", source: "airports", minzoom: g.minzoom,
      filter: inGroup("airport"),
      layout: {"text-field": ["get", "label"], "text-font": ["Noto Sans Medium"],
               "text-size": ["match", ["get", "cat"], "major", A.majorSize, A.size],
               "text-variable-anchor": ["left", "right", "top", "bottom"], "text-radial-offset": 0.8,
               "text-justify": "auto", "symbol-sort-key": ["get", "rank"], "text-padding": 2},
      paint: {"text-color": color, "text-halo-color": A.halo, "text-halo-width": 1.5}});
  }
  const firstLabel = style.layers.findIndex(l => l.type === "symbol");
  style.layers.splice(firstLabel < 0 ? style.layers.length : firstLabel, 0, ...runways);
  style.layers.push(...marks);
}
const map = new maplibregl.Map({
  container: "map", style: style, pixelRatio: 1, fadeDuration: 0,
  interactive: false, attributionControl: false, center: [cfg.lon, cfg.lat], zoom: cfg.zoom
});
map.on("error", e => window.mapErrors.push(String((e.error && e.error.message) || e)));
window.mapReady = new Promise(res => map.once("idle", () => res(true)));
window.renderAt = (lon, lat, zoom) => new Promise(res => {
  map.jumpTo({center: [lon, lat], zoom: zoom});
  map.once("idle", () => res(true));
  map.triggerRepaint();
});
</script></body></html>
"""


# --------------------------------------------------------------------------- airspace

# Drawn in this order, so B ends up on top. Colours follow chart convention
# (B and D blue, C magenta, D dashed), brightened to show on a dark map.
AIRSPACE_STYLE = {
    "E": {"color": "#b05cc0", "width": 1.0, "dash": [2, 3]},
    "D": {"color": "#5b9cf0", "width": 1.2, "dash": [3, 2]},
    "C": {"color": "#d470e0", "width": 1.6, "dash": None},
    "B": {"color": "#5b9cf0", "width": 2.0, "dash": None},
}


def _class_of(record):
    """Airspace class letter from an FAA Class Airspace record, or None."""
    value = str(record.get("CLASS", "") or "").strip().upper()
    if value in AIRSPACE_STYLE:
        return value
    for key in ("LOCAL_TYPE", "TYPE_CODE", "NAME"):
        m = re.search(r"CLASS[ _]?([BCDE])\b", str(record.get(key, "") or "").upper())
        if m:
            return m.group(1)
    return None


def _shapes_from_zip(path):
    """Yield (record dict, GeoJSON geometry) from every shapefile in a zip."""
    try:
        import shapefile                                     # pyshp
    except ImportError:
        sys.exit("Reading the FAA shapefile needs pyshp: pip install pyshp")
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        shps = [n for n in names if n.lower().endswith(".shp")]
        if not shps:
            sys.exit(f"{path} contains no .shp file")
        for shp in shps:
            stem = shp[:-4]
            member = {ext: next((n for n in names if n.lower() == (stem + ext).lower()), None)
                      for ext in (".shx", ".dbf", ".prj")}
            if not member[".dbf"]:
                continue
            if member[".prj"]:
                prj = z.read(member[".prj"]).decode("latin-1")
                if prj.lstrip().upper().startswith("PROJCS"):
                    sys.exit(f"{shp} uses projected coordinates; expected longitude/latitude.")
            reader = shapefile.Reader(shp=io.BytesIO(z.read(shp)),
                                      shx=io.BytesIO(z.read(member[".shx"])) if member[".shx"] else None,
                                      dbf=io.BytesIO(z.read(member[".dbf"])))
            for sr in reader.iterShapeRecords():
                if sr.shape.shapeType == shapefile.NULL or not sr.shape.points:
                    continue
                yield sr.record.as_dict(), sr.shape.__geo_interface__, sr.shape.bbox


def _features_from_geojson(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    for feat in data.get("features", []):
        geom = feat.get("geometry")
        if not geom:
            continue
        coords = []
        stack = [geom.get("coordinates", [])]
        while stack:                                          # flatten any nesting depth
            item = stack.pop()
            if item and isinstance(item[0], (int, float)):
                coords.append(item)
            else:
                stack.extend(item)
        if not coords:
            continue
        xs, ys = [c[0] for c in coords], [c[1] for c in coords]
        yield feat.get("properties") or {}, geom, (min(xs), min(ys), max(xs), max(ys))


def load_airspace(path, classes, bbox):
    """GeoJSON FeatureCollection of the wanted classes that touch bbox, plus counts."""
    source = _features_from_geojson(path) if path.lower().endswith((".geojson", ".json")) \
        else _shapes_from_zip(path)
    west, south, east, north = bbox
    features, counts, unknown, sample = [], {}, 0, None
    for record, geom, (x0, y0, x1, y1) in source:
        cls = _class_of(record)
        if cls is None:
            unknown += 1
            sample = sample or record
            continue
        if cls not in classes or x1 < west or x0 > east or y1 < south or y0 > north:
            continue
        features.append({"type": "Feature", "geometry": geom,
                         "properties": {"class": cls, "name": str(record.get("NAME", "") or "")}})
        counts[cls] = counts.get(cls, 0) + 1
    if not features and unknown:
        sys.exit("Could not find the airspace class in this file. Fields of the first record:\n  "
                 + "\n  ".join(f"{k} = {v!r}" for k, v in list(sample.items())[:25]))
    return {"type": "FeatureCollection", "features": features}, counts


# --------------------------------------------------------------------------- airports

# Sectional-chart convention: towered airports blue, non-towered magenta.
AIRPORT_COLORS = {
    "dark":  {"blue": "#6aa8ff", "magenta": "#e07ae8", "halo": "#111111"},
    "black": {"blue": "#6aa8ff", "magenta": "#e07ae8", "halo": "#000000"},
}
AIRPORT_COLORS_LIGHT = {"blue": "#1d5bbf", "magenta": "#a3268f", "halo": "#ffffff"}
AIRPORT_RANK = {"major": 0, "towered": 1, "other": 2}
APT_TABLES = ("APT_BASE.CSV", "APT_RWY_END.CSV")


def _find_apt_tables(path):
    """{'APT_BASE.CSV': bytes, 'APT_RWY_END.CSV': bytes} from the FAA NASR APT CSV zip,
    the full NASR CSV zip (also when it holds per-group zips), a folder, or APT_BASE.csv."""
    found = {}

    def from_zip(zf, depth=0):
        names = zf.namelist()
        for n in names:
            base = os.path.basename(n).upper()
            if base in APT_TABLES and base not in found:
                found[base] = zf.read(n)
        if "APT_BASE.CSV" not in found and depth == 0:
            inner = sorted((n for n in names if n.lower().endswith(".zip")),
                           key=lambda n: "APT" not in os.path.basename(n).upper())
            for n in inner:
                with zipfile.ZipFile(io.BytesIO(zf.read(n))) as z2:
                    from_zip(z2, depth + 1)
                if "APT_BASE.CSV" in found:
                    break

    if os.path.isdir(path):
        for root, _, files in os.walk(path):
            for name in files:
                if name.upper() in APT_TABLES and name.upper() not in found:
                    with open(os.path.join(root, name), "rb") as f:
                        found[name.upper()] = f.read()
    elif path.lower().endswith(".zip"):
        with zipfile.ZipFile(path) as zf:
            from_zip(zf)
    elif path.lower().endswith(".csv"):
        with open(path, "rb") as f:
            found["APT_BASE.CSV"] = f.read()
        sibling = os.path.join(os.path.dirname(path), "APT_RWY_END.csv")
        if os.path.isfile(sibling):
            with open(sibling, "rb") as f:
                found["APT_RWY_END.CSV"] = f.read()
    if "APT_BASE.CSV" not in found:
        sys.exit(f"No APT_BASE.csv found in {path}. Use the FAA NASR 'Airports and Other Landing "
                 "Facilities (APT)' CSV zip, or the 'Data in CSV format' zip.")
    return found


def _csv_rows(data):
    reader = csv.DictReader(io.StringIO(data.decode("utf-8-sig", errors="replace")))
    for row in reader:
        yield {(k or "").strip().upper(): (v or "").strip() for k, v in row.items()}


def load_airports(path, bbox, use="public", label="id", runways=True):
    """GeoJSON of airports (points) and runways (lines) inside bbox, plus counts."""
    tables = _find_apt_tables(path)
    west, south, east, north = bbox
    needed = {"ARPT_ID", "LAT_DECIMAL", "LONG_DECIMAL"}
    features, kept, counts = [], {}, {"major": 0, "towered": 0, "other": 0}
    columns = None
    for row in _csv_rows(tables["APT_BASE.CSV"]):
        if columns is None:
            columns = set(row)
            if not needed <= columns:
                sys.exit("APT_BASE.csv is missing expected columns " + ", ".join(sorted(needed - columns))
                         + ".\nColumns found: " + ", ".join(sorted(columns)))
        if row.get("SITE_TYPE_CODE", "A") != "A":              # skip heliports, seaplane bases, ...
            continue
        if use == "public" and row.get("FACILITY_USE_CODE", "PU") != "PU":
            continue
        if row.get("ARPT_STATUS", "O") not in ("O", ""):         # skip closed airports
            continue
        try:
            lat, lon = float(row["LAT_DECIMAL"]), float(row["LONG_DECIMAL"])
        except ValueError:
            continue
        if not (west <= lon <= east and south <= lat <= north):
            continue
        if row.get("FAR_139_CARRIER_SER_CODE", "") == "S":
            cat = "major"                                       # scheduled airline service
        elif row.get("TWR_TYPE_CODE", "").upper().startswith("ATCT"):
            cat = "towered"
        else:
            cat = "other"
        ident = row["ARPT_ID"]
        text = {"id": ident,
                "icao": row.get("ICAO_ID") or ident,
                "name": row.get("ARPT_NAME", ident).title()}[label]
        features.append({"type": "Feature", "geometry": {"type": "Point", "coordinates": [lon, lat]},
                         "properties": {"kind": "airport", "cat": cat, "rank": AIRPORT_RANK[cat],
                                        "label": text, "id": ident}})
        kept[row.get("SITE_NO") or ident] = cat
        kept.setdefault(ident, cat)
        counts[cat] += 1

    n_runways = 0
    if runways and "APT_RWY_END.CSV" in tables:
        ends = {}
        for row in _csv_rows(tables["APT_RWY_END.CSV"]):
            key = row.get("SITE_NO") or row.get("ARPT_ID", "")
            cat = kept.get(key) or kept.get(row.get("ARPT_ID", ""))
            rwy = row.get("RWY_ID", "")
            if cat is None or not rwy or rwy.upper().startswith("H"):      # skip helipads
                continue
            try:
                pt = [float(row["LONG_DECIMAL"]), float(row["LAT_DECIMAL"])]
            except (KeyError, ValueError):
                continue
            ends.setdefault((key, rwy), (cat, []))[1].append(pt)
        for (_, rwy), (cat, pts) in ends.items():
            if len(pts) >= 2:
                features.append({"type": "Feature", "geometry": {"type": "LineString", "coordinates": pts[:2]},
                                 "properties": {"kind": "runway", "cat": cat, "rwy": rwy}})
                n_runways += 1
    return {"type": "FeatureCollection", "features": features}, counts, n_runways


# --------------------------------------------------------------------------- local web server (handler)

def make_handler(page_html, pmtiles_path, assets_dir, data_files=None):
    data_files = data_files or {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _send(self, code, body, ctype, extra=None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = urllib.parse.unquote(self.path.split("?", 1)[0])
            if path in ("/", "/index.html"):
                return self._send(200, page_html.encode(), "text/html; charset=utf-8")
            if path.startswith("/lib/"):
                name = os.path.basename(path)
                full = os.path.join(CACHE_DIR, name)
                if os.path.isfile(full):
                    ctype = "text/css" if name.endswith(".css") else "application/javascript"
                    with open(full, "rb") as f:
                        return self._send(200, f.read(), ctype)
            if path in data_files:
                return self._send(200, data_files[path], "application/geo+json")
            if path == "/data/map.pmtiles":
                return self._serve_range(pmtiles_path)
            if assets_dir and path.startswith("/assets/"):
                full = os.path.realpath(os.path.join(assets_dir, path[len("/assets/"):]))
                if full.startswith(os.path.realpath(assets_dir) + os.sep) and os.path.isfile(full):
                    ctype = {".json": "application/json", ".png": "image/png",
                             ".pbf": "application/x-protobuf"}.get(os.path.splitext(full)[1],
                                                                  "application/octet-stream")
                    with open(full, "rb") as f:
                        return self._send(200, f.read(), ctype)
            self._send(404, b"not found", "text/plain")

        def _serve_range(self, file_path):
            size = os.path.getsize(file_path)
            rng = self.headers.get("Range")
            start, end = 0, size - 1
            if rng and rng.startswith("bytes="):
                a, _, b = rng[6:].split(",")[0].partition("-")
                if a:
                    start, end = int(a), (int(b) if b else size - 1)
                else:
                    start = max(0, size - int(b))
                end = min(end, size - 1)
                if start > end:
                    return self._send(416, b"", "application/octet-stream",
                                      {"Content-Range": f"bytes */{size}"})
            with open(file_path, "rb") as f:
                f.seek(start)
                body = f.read(end - start + 1)
            extra = {"Accept-Ranges": "bytes"}
            if rng:
                extra["Content-Range"] = f"bytes {start}-{end}/{size}"
            self._send(206 if rng else 200, body, "application/octet-stream", extra)

    return Handler


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


# --------------------------------------------------------------------------- tile maths

def tile_center_lonlat(x, y, z):
    """lon/lat of the (fractional) tile coordinate x, y at zoom z."""
    n = 2.0 ** z
    lon = x / n * 360.0 - 180.0
    lat = math.degrees(math.atan(math.sinh(math.pi * (1.0 - 2.0 * y / n))))
    return lon, lat


def tile_path(out, z, x, y):
    return os.path.join(out, str(z), str(x), f"{y}.png")


# --------------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pmtiles", required=True, help="Protomaps extract, e.g. nyc.pmtiles")
    ap.add_argument("--out", default="tiles_osm", help="output folder for {z}/{x}/{y}.png (default: tiles_osm)")
    ap.add_argument("--flavor", choices=FLAVORS, default="dark", help="Protomaps style flavour (default: dark)")
    ap.add_argument("--zooms", default="8-12", help="zoom range of 256 px tiles (default: 8-12)")
    ap.add_argument("--center", default=f"{NYC[0]},{NYC[1]}", help="lat,lon of map centre (default: NYC)")
    ap.add_argument("--radius-mi", type=float, default=100.0, help="radius in statute miles (default: 100)")
    ap.add_argument("--bbox", help="west,south,east,north instead of --center/--radius-mi")
    ap.add_argument("--labels", choices=("places", "all", "none"), default="places",
                    help="places: city/town and state names only (default); all: full Protomaps "
                         "labelling; none: no text or icons")
    ap.add_argument("--no-labels", action="store_true", help="same as --labels none")
    ap.add_argument("--min-city-pop", type=int, default=10_000,
                    help="hide cities and towns smaller than this (default 10000; --labels places)")
    ap.add_argument("--city-size", type=float, default=13,
                    help="city/town label height in screen pixels (default 13; --labels places)")
    ap.add_argument("--big-city-size", type=float, default=17,
                    help="label height for cities of --big-city-pop or more (default 17; --labels places)")
    ap.add_argument("--big-city-pop", type=int, default=500_000,
                    help="population at which a city counts as big (default 500000)")
    ap.add_argument("--state-size", type=float, default=14,
                    help="state/country label height in screen pixels (default 14; --labels places)")
    ap.add_argument("--label-color", default="auto",
                    help="auto (brighter labels on dark/black, default), style (keep the style's colours), "
                         "or a colour such as '#d0d0d0' for all labels")
    ap.add_argument("--lang", default="en", help="label language (default: en)")
    ap.add_argument("--assets", help="local clone of github.com/protomaps/basemaps-assets (offline labels)")
    ap.add_argument("--airspace",
                    help="draw airspace outlines from the FAA NASR 'Class Airspace Shape Files' zip "
                         "(class_airspace_shape_files.zip) or a GeoJSON file")
    ap.add_argument("--airspace-classes", default="B",
                    help="which classes to draw, e.g. B (default), B,C or B,C,D")
    ap.add_argument("--airports",
                    help="draw and label airports from the FAA NASR 'Airports and Other Landing "
                         "Facilities (APT)' CSV zip, the 'Data in CSV format' zip, or APT_BASE.csv")
    ap.add_argument("--airport-label", choices=("id", "icao", "name"), default="id",
                    help="label text: FAA id like JFK or TEB (default), ICAO id like KJFK, or full name")
    ap.add_argument("--airport-use", choices=("public", "all"), default="public",
                    help="public-use airports only (default), or include private airfields")
    ap.add_argument("--small-airport-zoom", type=int, default=10,
                    help="non-towered airports appear from this zoom (default 10); towered ones at all zooms")
    ap.add_argument("--airport-size", type=float, default=12,
                    help="airport label height in pixels (default 12; airline airports +2)")
    ap.add_argument("--no-runways", action="store_true", help="airport rings and labels only, no runway lines")
    ap.add_argument("--block", type=int, default=4,
                    help="tiles per side rendered in one pass (default 4; lower it if the browser runs out of memory)")
    ap.add_argument("--force", action="store_true", help="re-render tiles that already exist")
    args = ap.parse_args()

    if not os.path.isfile(args.pmtiles):
        sys.exit(f"{args.pmtiles} not found")
    if args.assets and not os.path.isdir(os.path.join(args.assets, "sprites", "v4")):
        sys.exit(f"--assets {args.assets} does not look like a basemaps-assets clone (no sprites/v4)")
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        sys.exit("Playwright is missing: pip install playwright && python3 -m playwright install chromium")

    z_lo, _, z_hi = args.zooms.partition("-")
    zooms = range(int(z_lo), int(z_hi or z_lo) + 1)
    if args.bbox:
        bbox = tuple(float(v) for v in args.bbox.split(","))
    else:
        lat, lon = (float(v) for v in args.center.split(","))
        bbox = bbox_from_center(lat, lon, args.radius_mi)

    data_files, airspace_cfg, airports_cfg = {}, None, None
    if args.airspace:
        if not os.path.isfile(args.airspace):
            sys.exit(f"{args.airspace} not found")
        classes = [c.strip().upper() for c in args.airspace_classes.split(",") if c.strip()]
        bad = [c for c in classes if c not in AIRSPACE_STYLE]
        if bad:
            sys.exit(f"--airspace-classes: unknown class {', '.join(bad)} (use B, C, D or E)")
        collection, counts = load_airspace(args.airspace, set(classes), bbox)
        data_files["/data/airspace.geojson"] = json.dumps(collection).encode()
        airspace_cfg = [dict(cls=c, **AIRSPACE_STYLE[c]) for c in AIRSPACE_STYLE if c in classes]
        found = ", ".join(f"class {c}: {counts.get(c, 0)}" for c in classes)
        print(f"Airspace shapes in the map area: {found}")

    if args.airports:
        if not os.path.exists(args.airports):
            sys.exit(f"{args.airports} not found")
        collection, counts, n_rwy = load_airports(args.airports, bbox, args.airport_use,
                                                  args.airport_label, not args.no_runways)
        data_files["/data/airports.geojson"] = json.dumps(collection).encode()
        airports_cfg = dict(AIRPORT_COLORS.get(args.flavor, AIRPORT_COLORS_LIGHT),
                            smallZoom=args.small_airport_zoom, size=args.airport_size,
                            majorSize=args.airport_size + 2, runways=not args.no_runways)
        print(f"Airports in the map area: {counts['major']} with airline service, "
              f"{counts['towered']} other towered, {counts['other']} non-towered; {n_rwy} runways")

    ensure_libraries()

    block, pad = max(1, args.block), 1          # one tile of padding keeps labels at block edges whole
    span = block + 2 * pad
    size = span * TILE
    labels = "none" if args.no_labels else args.labels
    if args.label_color == "auto":
        city_color, state_color = AUTO_LABEL_COLORS.get(args.flavor, (None, None))
    elif args.label_color == "style":
        city_color = state_color = None
    else:
        city_color = state_color = args.label_color
    cfg = {"flavor": args.flavor, "lang": args.lang, "labels": labels,
           "minRank": population_rank(args.min_city_pop),
           "citySize": args.city_size, "stateSize": args.state_size,
           "bigRank": population_rank(args.big_city_pop), "bigCitySize": args.big_city_size,
           "cityColor": city_color, "stateColor": state_color,
           "assets": "/assets" if args.assets else HOSTED_ASSETS,
           "airspace": airspace_cfg, "airports": airports_cfg,
           "lon": (bbox[0] + bbox[2]) / 2, "lat": (bbox[1] + bbox[3]) / 2, "zoom": zooms[0] - 1}
    page_html = PAGE % {"size": size, "cfg": json.dumps(cfg)}

    server = Server(("127.0.0.1", 0), make_handler(page_html, args.pmtiles, args.assets, data_files))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_address[1]}/"

    total = sum(w * h for _, _, w, h in (tile_grid(bbox, z) for z in zooms))
    done = skipped = 0
    started = time.time()
    with sync_playwright() as p:
        browser = p.chromium.launch(args=["--use-angle=swiftshader", "--enable-unsafe-swiftshader",
                                          "--ignore-gpu-blocklist"])
        page = browser.new_page(viewport={"width": size, "height": size}, device_scale_factor=1)
        page.goto(url)
        page.wait_for_function("window.mapReady !== undefined", timeout=60_000)
        page.evaluate("window.mapReady")
        reported = 0

        for z in zooms:
            x0, y0, w, h = tile_grid(bbox, z)
            print(f"zoom {z}: {w}x{h} tiles", flush=True)
            for by in range(y0, y0 + h, block):
                for bx in range(x0, x0 + w, block):
                    wanted = [(x, y) for y in range(by, min(by + block, y0 + h))
                              for x in range(bx, min(bx + block, x0 + w))]
                    if not args.force and all(os.path.isfile(tile_path(args.out, z, x, y)) for x, y in wanted):
                        skipped += len(wanted)
                        continue
                    lon, lat = tile_center_lonlat(bx + block / 2, by + block / 2, z)
                    # MapLibre uses 512 px tiles, so 256 px tile zoom z is MapLibre zoom z - 1.
                    page.evaluate("([lon, lat, zm]) => window.renderAt(lon, lat, zm)", [lon, lat, z - 1])
                    shot = Image.open(io.BytesIO(page.screenshot(
                        clip={"x": 0, "y": 0, "width": size, "height": size}))).convert("RGB")
                    for x, y in wanted:
                        left, top = (x - bx + pad) * TILE, (y - by + pad) * TILE
                        path = tile_path(args.out, z, x, y)
                        os.makedirs(os.path.dirname(path), exist_ok=True)
                        shot.crop((left, top, left + TILE, top + TILE)).save(path, optimize=True)
                    done += len(wanted)
                    errors = page.evaluate("window.mapErrors")
                    for err in errors[reported:]:
                        print(f"  map warning: {err}", flush=True)
                    reported = len(errors)
                    elapsed = time.time() - started
                    print(f"  {done + skipped}/{total} tiles  ({elapsed:.0f} s)", flush=True)
        browser.close()
    server.shutdown()
    print(f"Done: {done} rendered, {skipped} already present, in {args.out}/")
    print("Map data (c) OpenStreetMap contributors - show this attribution on the display.")


if __name__ == "__main__":
    main()