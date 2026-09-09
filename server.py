from __future__ import annotations

import io
import os
import secrets
from pathlib import Path

from flask import Flask, redirect, render_template, request, send_file, url_for
from PIL import Image
from rembg import new_session, remove


ROOT = Path(__file__).resolve().parent
UPLOAD_DIR = ROOT / "uploads"
OUTPUT_DIR = ROOT / "outputs"
MODEL_DIR = ROOT / ".u2net"

for path in (UPLOAD_DIR, OUTPUT_DIR, MODEL_DIR):
    path.mkdir(exist_ok=True)

os.environ.setdefault("U2NET_HOME", str(MODEL_DIR))

MODEL_CHOICES = [
    ("isnet-general-use", "Recommended"),
    ("u2net", "Balanced"),
    ("u2netp", "Fast"),
    ("u2net_human_seg", "Human"),
    ("u2net_cloth_seg", "Clothes"),
]

CATEGORY_CHOICES = [
    ("tops", "Tops"),
    ("bottoms", "Bottoms"),
    ("outerwear", "Outerwear"),
    ("onepiece", "One-piece"),
    ("shoes", "Shoes"),
    ("bags", "Bags"),
    ("accessories", "Accessories"),
    ("other", "Other"),
]

_session_cache: dict[str, object] = {}


def get_session(model_name: str):
    if model_name not in _session_cache:
        _session_cache[model_name] = new_session(model_name)
    return _session_cache[model_name]


def sanitize_name(filename: str) -> str:
    stem = Path(filename).stem or "image"
    return "".join(ch for ch in stem if ch.isalnum() or ch in ("-", "_"))[:60] or "image"


def ensure_category_dir(category: str) -> Path:
    path = OUTPUT_DIR / category
    path.mkdir(exist_ok=True)
    return path


def collect_gallery():
    groups = []
    for slug, label in CATEGORY_CHOICES:
        category_dir = ensure_category_dir(slug)
        items = sorted(category_dir.glob("*.png"), key=lambda p: p.stat().st_mtime, reverse=True)
        groups.append(
            {
                "slug": slug,
                "label": label,
                "items": [
                    {
                        "name": item.name,
                        "url_name": f"{slug}/{item.name}",
                        "updated_at": item.stat().st_mtime,
                    }
                    for item in items
                ],
            }
        )
    return groups


def latest_output_name(groups) -> str | None:
    latest_item = None
    for group in groups:
        for item in group["items"]:
            if latest_item is None or item["updated_at"] > latest_item["updated_at"]:
                latest_item = item
    return latest_item["url_name"] if latest_item else None


app = Flask(__name__)


@app.get("/")
def index():
    groups = collect_gallery()
    return render_template(
        "index.html",
        model_choices=MODEL_CHOICES,
        category_choices=CATEGORY_CHOICES,
        gallery_groups=groups,
        latest_name=latest_output_name(groups),
        message=request.args.get("message", ""),
        error=request.args.get("error", ""),
    )


@app.get("/manual")
def manual():
    return render_template("manual.html")


@app.post("/cutout")
def cutout():
    upload = request.files.get("image")
    if not upload or not upload.filename:
        return redirect(url_for("index", error="Please choose an image file."))

    model_name = request.form.get("model", "isnet-general-use")
    if model_name not in {value for value, _ in MODEL_CHOICES}:
        model_name = "isnet-general-use"

    category = request.form.get("category", "other")
    if category not in {value for value, _ in CATEGORY_CHOICES}:
        category = "other"

    alpha_matting = request.form.get("alpha_matting") == "on"
    try:
        alpha_foreground = int(request.form.get("alpha_foreground", "240"))
        alpha_background = int(request.form.get("alpha_background", "10"))
        alpha_erode = int(request.form.get("alpha_erode", "10"))
    except ValueError:
        alpha_foreground, alpha_background, alpha_erode = 240, 10, 10

    token = secrets.token_hex(6)
    base_name = sanitize_name(upload.filename)
    input_path = UPLOAD_DIR / f"{base_name}_{token}{Path(upload.filename).suffix or '.png'}"
    output_dir = ensure_category_dir(category)
    output_path = output_dir / f"{base_name}_{token}.png"

    upload.save(input_path)

    session = get_session(model_name)
    input_bytes = input_path.read_bytes()
    result_bytes = remove(
        input_bytes,
        session=session,
        alpha_matting=alpha_matting,
        alpha_matting_foreground_threshold=alpha_foreground,
        alpha_matting_background_threshold=alpha_background,
        alpha_matting_erode_size=alpha_erode,
    )

    image = Image.open(io.BytesIO(result_bytes)).convert("RGBA")
    bbox = image.getbbox()
    if bbox:
        image = image.crop(bbox)
    image.save(output_path)

    return redirect(url_for("index", message=f"Saved to {category}/{output_path.name}"))


@app.post("/manual-save")
def manual_save():
    upload = request.files.get("image")
    if not upload or not upload.filename:
        return {"ok": False, "error": "Image was not provided."}, 400

    category = request.form.get("category", "other")
    if category not in {value for value, _ in CATEGORY_CHOICES}:
        category = "other"

    token = secrets.token_hex(6)
    base_name = sanitize_name(upload.filename)
    output_dir = ensure_category_dir(category)
    output_path = output_dir / f"{base_name}_{token}.png"

    image = Image.open(upload.stream).convert("RGBA")
    bbox = image.getbbox()
    if bbox:
        image = image.crop(bbox)
    image.save(output_path)

    return {"ok": True, "category": category, "name": output_path.name, "url": url_for("output_file", name=f"{category}/{output_path.name}")}


@app.get("/outputs/<path:name>")
def output_file(name: str):
    path = OUTPUT_DIR / name
    if not path.exists():
        return redirect(url_for("index", error="Output file was not found."))
    return send_file(path)


@app.post("/delete")
def delete_output():
    name = request.form.get("name", "")
    if not name:
        return redirect(url_for("index", error="Delete target was not specified."))

    path = (OUTPUT_DIR / name).resolve()
    outputs_root = OUTPUT_DIR.resolve()

    try:
        path.relative_to(outputs_root)
    except ValueError:
        return redirect(url_for("index", error="Invalid delete target."))

    if not path.exists() or not path.is_file():
        return redirect(url_for("index", error="File was not found."))

    path.unlink()
    return redirect(url_for("index", message=f"Deleted {name}"))


if __name__ == "__main__":
    host = os.environ.get("CUTOUT_HOST", "127.0.0.1")
    port = int(os.environ.get("CUTOUT_PORT", "5042"))
    app.run(host=host, port=port, debug=False)
