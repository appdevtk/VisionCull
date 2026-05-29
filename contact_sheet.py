#!/usr/bin/env python3
"""VisionCull Contact Sheet — HTML contact sheet generator with dual-palette rendering."""

import argparse
import html
import json
import os
import sys
from pathlib import Path

from PIL import Image

THUMB_WIDTH = 480
THUMB_QUALITY = 82

# Color name → CSS hex for palette dots
COLOR_MAP = {
    "red": "#C0392B", "orange": "#E67E22", "yellow": "#F1C40F",
    "green": "#27AE60", "teal": "#16A085", "blue": "#2980B9",
    "purple": "#8E44AD", "pink": "#E91E8C", "brown": "#8B5A2B",
    "black": "#2C2C2C", "white": "#F8F8F8", "gray": "#95A5A6",
}


def generate_thumbnails(images, images_base, output_dir):
    """Generate cached thumbnails. Returns map of filename → thumb relative path."""
    thumbs_dir = Path(output_dir) / "thumbs"
    thumbs_dir.mkdir(parents=True, exist_ok=True)
    thumb_map = {}

    for img_data in images:
        fname = img_data["filename"]
        src = Path(img_data.get("path", ""))
        if not src.is_file() and images_base:
            src = Path(images_base) / fname
        if not src.is_file():
            continue

        thumb_path = thumbs_dir / f"thumb_{fname}"
        # Use .jpg extension for all thumbnails
        if thumb_path.suffix.lower() not in (".jpg", ".jpeg"):
            thumb_path = thumb_path.with_suffix(".jpg")

        # Cache by mtime
        if thumb_path.exists() and thumb_path.stat().st_mtime >= src.stat().st_mtime:
            thumb_map[fname] = f"thumbs/{thumb_path.name}"
            continue

        try:
            with Image.open(src) as pil_img:
                pil_img = pil_img.convert("RGB")
                ratio = THUMB_WIDTH / pil_img.width
                new_h = int(pil_img.height * ratio)
                pil_img = pil_img.resize((THUMB_WIDTH, new_h), Image.LANCZOS)
                pil_img.save(thumb_path, "JPEG", quality=THUMB_QUALITY)
            thumb_map[fname] = f"thumbs/{thumb_path.name}"
        except Exception as e:
            print(f"  Warning: thumbnail failed for {fname}: {e}", file=sys.stderr)

    return thumb_map


def _palette_dots_html(colors, label, dot_size=14):
    """Render a row of color dots with label."""
    if not colors:
        return ""
    dots = []
    for c in colors[:5]:
        color_name = c.get("color", "gray")
        css_color = COLOR_MAP.get(color_name, "#95A5A6")
        pct = c.get("percentage", 0)
        border = "1px solid rgba(0,0,0,0.15)" if color_name == "white" else "none"
        dots.append(
            f'<span class="dot" style="width:{dot_size}px;height:{dot_size}px;'
            f'background:{css_color};border:{border}" '
            f'title="{color_name} {pct}%"></span>'
        )
    return f'<div class="palette-row"><span class="palette-label">{label}</span>{"".join(dots)}</div>'


def _subject_status(img):
    """Determine subject lift status."""
    sc = img.get("subject_colors", [])
    cov = img.get("subject_coverage", 0)
    if sc and cov > 0:
        return "success"
    if cov == 0 and not sc:
        return "no_instances"
    return "error"


def _card_html(img, rank, thumb_path, idx):
    """Render one image card."""
    fname = html.escape(img["filename"])
    score = img.get("aesthetic_score", 0)
    score_pct = max(0, min(100, score * 100))
    labels = img.get("labels", [])[:3]
    dc = img.get("dominant_colors", [])
    sc = img.get("subject_colors", [])
    status = _subject_status(img)
    cluster = img.get("duplicate_cluster")
    cov = img.get("subject_coverage", 0)
    full_path = html.escape(img.get("path", ""))

    # Label chips
    label_chips = "".join(
        f'<span class="label-chip">{html.escape(l["name"])} '
        f'<small>{l["confidence"]:.0%}</small></span>'
        for l in labels
    )

    # Palette rows
    if status == "success":
        palette_html = (
            _palette_dots_html(sc, "Arrangement", 14)
            + _palette_dots_html(dc, "Scene", 10)
        )
    else:
        palette_html = _palette_dots_html(dc, "Scene", 12)

    # Status indicator for failures
    status_icon = ""
    if status != "success":
        reason = "No subject detected" if status == "no_instances" else "Extraction error"
        status_icon = f'<span class="status-icon" title="{reason}">◌</span>'

    # Cluster badge
    cluster_badge = ""
    if cluster:
        c_rank = img.get("cluster_rank", 0)
        badge_class = "cluster-best" if c_rank == 1 else "cluster-dup"
        cluster_badge = f'<span class="cluster-badge {badge_class}">C{cluster}</span>'

    rank_badge = f'<span class="rank-badge">#{rank}</span>' if rank else ""

    return f'''<div class="card" data-idx="{idx}" onclick="openLightbox({idx})">
  <div class="card-img-wrap">
    <img src="{html.escape(thumb_path)}" alt="{fname}" loading="lazy">
    {rank_badge}
    {status_icon}
    {cluster_badge}
    <div class="score-bar"><div class="score-fill" style="width:{score_pct}%"></div></div>
    <div class="hover-overlay">
      <div class="hover-labels">{label_chips}</div>
      <div class="hover-palettes">{palette_html}</div>
    </div>
  </div>
  <div class="card-footer">
    <span class="card-name">{fname}</span>
    <span class="card-score">{score:.3f}</span>
  </div>
</div>'''


def _lightbox_data_js(images):
    """Generate JS data array for lightbox."""
    entries = []
    for img in images:
        labels_json = json.dumps(img.get("labels", []))
        dc_json = json.dumps(img.get("dominant_colors", []))
        sc_json = json.dumps(img.get("subject_colors", []))
        qf = img.get("quality_flags", {})
        entries.append(
            f'{{"filename":{json.dumps(img["filename"])},'
            f'"path":{json.dumps(img.get("_thumb_path") or img.get("path",""))},'
            f'"score":{img.get("aesthetic_score",0)},'
            f'"is_utility":{json.dumps(img.get("is_utility",False))},'
            f'"quality_flags":{json.dumps(qf)},'
            f'"labels":{labels_json},'
            f'"dominant_colors":{dc_json},'
            f'"subject_colors":{sc_json},'
            f'"subject_coverage":{img.get("subject_coverage",0)},'
            f'"cluster":{json.dumps(img.get("duplicate_cluster"))},'
            f'"cluster_rank":{json.dumps(img.get("cluster_rank"))}}}'
        )
    return "[\n" + ",\n".join(entries) + "\n]"


def generate_html(report, thumb_map, ordered_images):
    """Generate the full HTML contact sheet."""
    total = report["total_images"]
    n_selects = len(report.get("selects", []))
    proc_time = report.get("processing_time_seconds", 0)
    selects_set = set(report.get("selects", []))

    # Build cards
    select_cards = []
    rest_cards = []
    all_ordered = []

    for img in ordered_images:
        fname = img["filename"]
        tp = thumb_map.get(fname)
        if not tp:
            continue
        img["_thumb_path"] = tp  # relative path for HTML
        is_select = fname in selects_set
        idx = len(all_ordered)
        all_ordered.append(img)
        if is_select:
            rank = report["selects"].index(fname) + 1
            select_cards.append(_card_html(img, rank, tp, idx))
        else:
            rest_cards.append(_card_html(img, None, tp, idx))

    lightbox_data = _lightbox_data_js(all_ordered)
    color_map_js = json.dumps(COLOR_MAP)

    return f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>VisionCull Contact Sheet — {total} images</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Playfair+Display:ital,wght@0,500;1,500&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet">
<style>
*, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}
body {{
  background: #F5F1E8;
  font-family: 'DM Sans', system-ui, sans-serif;
  color: #2D4A3E;
  padding: 2rem;
}}
h1 {{
  font-family: 'Playfair Display', Georgia, serif;
  font-weight: 500;
  font-size: 1.8rem;
  color: #2D4A3E;
  margin-bottom: 0.25rem;
}}
.subtitle {{
  color: #6B8F7A;
  font-size: 0.85rem;
  margin-bottom: 1.5rem;
}}
.divider {{
  border: none;
  border-top: 1px solid #B8956A;
  margin: 2rem 0 1.5rem;
}}
.section-label {{
  font-family: 'Playfair Display', Georgia, serif;
  font-weight: 500;
  font-size: 1.1rem;
  color: #2D4A3E;
  margin-bottom: 1rem;
}}
.grid {{
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
  gap: 1rem;
}}
.card {{
  background: #fff;
  border-radius: 4px;
  box-shadow: 0 2px 12px rgba(17,40,25,0.08);
  border: 1px solid #EDE9DF;
  overflow: hidden;
  cursor: pointer;
  transition: box-shadow 0.3s ease;
}}
.card:hover {{
  box-shadow: 0 4px 20px rgba(17,40,25,0.14);
}}
.card-img-wrap {{
  position: relative;
  overflow: hidden;
}}
.card-img-wrap img {{
  display: block;
  width: 100%;
  height: auto;
  transition: brightness 0.3s ease;
}}
.card:hover .card-img-wrap img {{
  brightness: 0.7;
}}
.rank-badge {{
  position: absolute;
  top: 8px;
  left: 8px;
  background: #2D4A3E;
  color: #F5F1E8;
  font-size: 0.7rem;
  font-weight: 600;
  padding: 2px 7px;
  border-radius: 12px;
  z-index: 2;
}}
.status-icon {{
  position: absolute;
  top: 8px;
  right: 8px;
  color: #B8956A;
  font-size: 0.9rem;
  opacity: 0.7;
  z-index: 2;
}}
.cluster-badge {{
  position: absolute;
  top: 8px;
  right: 8px;
  font-size: 0.6rem;
  font-weight: 600;
  padding: 2px 6px;
  border-radius: 8px;
  z-index: 2;
}}
.cluster-best {{ background: #27AE60; color: #fff; }}
.cluster-dup {{ background: #E67E22; color: #fff; }}
.status-icon + .cluster-badge {{ top: 28px; }}
.score-bar {{
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  height: 3px;
  background: rgba(0,0,0,0.1);
}}
.score-fill {{
  height: 100%;
  background: #B8956A;
  transition: width 0.3s ease;
}}
.hover-overlay {{
  position: absolute;
  inset: 0;
  background: rgba(45,74,62,0.88);
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
  padding: 12px;
  opacity: 0;
  transition: opacity 0.3s ease;
}}
.card:hover .hover-overlay {{ opacity: 1; }}
.hover-labels {{
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
  margin-bottom: 8px;
}}
.label-chip {{
  background: rgba(255,255,255,0.15);
  color: #F5F1E8;
  font-size: 0.65rem;
  padding: 2px 6px;
  border-radius: 10px;
}}
.label-chip small {{ opacity: 0.7; }}
.palette-row {{
  display: flex;
  align-items: center;
  gap: 4px;
  margin-top: 4px;
}}
.palette-label {{
  color: #B8956A;
  font-size: 0.6rem;
  font-weight: 600;
  min-width: 72px;
  text-transform: uppercase;
  letter-spacing: 0.5px;
}}
.dot {{
  display: inline-block;
  border-radius: 50%;
  flex-shrink: 0;
}}
.card-footer {{
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 6px 10px;
  font-size: 0.72rem;
}}
.card-name {{
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  max-width: 70%;
  color: #6B8F7A;
}}
.card-score {{
  font-weight: 600;
  color: #2D4A3E;
}}

/* Lightbox */
.lightbox {{
  display: none;
  position: fixed;
  inset: 0;
  z-index: 1000;
  background: rgba(17,40,25,0.92);
}}
.lightbox.active {{ display: flex; }}
.lb-main {{
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 2rem;
  min-width: 0;
}}
.lb-main img {{
  max-width: 100%;
  max-height: 90vh;
  object-fit: contain;
  border-radius: 2px;
}}
.lb-sidebar {{
  width: 320px;
  background: #F5F1E8;
  overflow-y: auto;
  padding: 1.5rem;
  flex-shrink: 0;
}}
.lb-close {{
  position: absolute;
  top: 1rem;
  left: 1rem;
  background: none;
  border: none;
  color: #F5F1E8;
  font-size: 1.5rem;
  cursor: pointer;
  opacity: 0.7;
  z-index: 1001;
}}
.lb-close:hover {{ opacity: 1; }}
.lb-counter {{
  position: absolute;
  top: 1rem;
  left: 50%;
  transform: translateX(-50%);
  color: #F5F1E8;
  font-family: 'DM Sans', sans-serif;
  font-size: 1.1rem;
  font-weight: 600;
  letter-spacing: 0.05em;
  background: rgba(17,40,25,0.65);
  padding: 0.3rem 1rem;
  border-radius: 24px;
  z-index: 1001;
  pointer-events: none;
}}
.lb-nav {{
  position: absolute;
  top: 50%;
  transform: translateY(-50%);
  background: rgba(45,74,62,0.6);
  border: none;
  color: #F5F1E8;
  font-size: 2rem;
  padding: 0.5rem 1rem;
  cursor: pointer;
  border-radius: 4px;
  z-index: 1001;
}}
.lb-nav:hover {{ background: rgba(45,74,62,0.85); }}
.lb-prev {{ left: 1rem; }}
.lb-next {{ right: 340px; }}
.lb-sidebar h3 {{
  font-family: 'Playfair Display', Georgia, serif;
  font-size: 1rem;
  font-weight: 500;
  margin-bottom: 0.5rem;
  color: #2D4A3E;
}}
.lb-sidebar .lb-filename {{
  font-size: 0.8rem;
  color: #6B8F7A;
  word-break: break-all;
  margin-bottom: 1rem;
}}
.lb-section {{
  margin-bottom: 1.2rem;
}}
.lb-section-title {{
  font-size: 0.7rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  color: #B8956A;
  margin-bottom: 0.4rem;
}}
.lb-score-big {{
  font-size: 2rem;
  font-weight: 600;
  color: #2D4A3E;
}}
.lb-label-list {{
  list-style: none;
  padding: 0;
}}
.lb-label-list li {{
  display: flex;
  justify-content: space-between;
  font-size: 0.75rem;
  padding: 2px 0;
  border-bottom: 1px solid #EDE9DF;
}}
.lb-label-list li span:last-child {{
  color: #6B8F7A;
}}
.lb-color-row {{
  display: flex;
  align-items: center;
  gap: 6px;
  margin: 4px 0;
  font-size: 0.72rem;
}}
.lb-color-dot {{
  width: 16px;
  height: 16px;
  border-radius: 50%;
  flex-shrink: 0;
}}
.lb-flags {{
  font-size: 0.7rem;
  color: #6B8F7A;
}}
.lb-flags span {{
  display: inline-block;
  margin-right: 8px;
}}
</style>
</head>
<body>

<h1>VisionCull Contact Sheet</h1>
<p class="subtitle">{total} images &middot; {n_selects} selects &middot; {proc_time:.1f}s processing</p>

<p class="section-label">Selects ({n_selects})</p>
<div class="grid">
{"".join(select_cards)}
</div>

<hr class="divider">

<p class="section-label">Remaining ({len(rest_cards)})</p>
<div class="grid">
{"".join(rest_cards)}
</div>

<div class="lightbox" id="lightbox">
  <button class="lb-close" onclick="closeLightbox()">&times;</button>
  <div class="lb-counter" id="lb-counter"></div>
  <button class="lb-nav lb-prev" onclick="navLightbox(-1)">&#8249;</button>
  <button class="lb-nav lb-next" onclick="navLightbox(1)">&#8250;</button>
  <div class="lb-main">
    <img id="lb-img" src="" alt="">
  </div>
  <div class="lb-sidebar" id="lb-sidebar"></div>
</div>

<script>
const DATA = {lightbox_data};
const COLOR_MAP = {color_map_js};
let currentIdx = -1;

function openLightbox(idx) {{
  currentIdx = idx;
  renderLightbox();
  document.getElementById('lightbox').classList.add('active');
  document.body.style.overflow = 'hidden';
}}

function closeLightbox() {{
  document.getElementById('lightbox').classList.remove('active');
  document.body.style.overflow = '';
  currentIdx = -1;
}}

function navLightbox(dir) {{
  currentIdx = (currentIdx + dir + DATA.length) % DATA.length;
  renderLightbox();
}}

function renderLightbox() {{
  const d = DATA[currentIdx];
  document.getElementById('lb-img').src = d.path;
  document.getElementById('lb-counter').textContent = `${{currentIdx + 1}} / ${{DATA.length}}`;

  // Labels
  const labelsHtml = d.labels.map(l =>
    `<li><span>${{l.name}}</span><span>${{(l.confidence*100).toFixed(1)}}%</span></li>`
  ).join('');

  // Color rows helper
  function colorRows(colors, label) {{
    if (!colors || !colors.length) return '';
    const rows = colors.map(c => {{
      const hex = COLOR_MAP[c.color] || '#95A5A6';
      const border = c.color === 'white' ? '1px solid rgba(0,0,0,0.15)' : 'none';
      return `<div class="lb-color-row">
        <span class="lb-color-dot" style="background:${{hex}};border:${{border}}"></span>
        <span>${{c.color}}</span>
        <span style="color:#6B8F7A;margin-left:auto">${{c.percentage}}%</span>
      </div>`;
    }}).join('');
    return `<div class="lb-section">
      <div class="lb-section-title">${{label}}</div>${{rows}}</div>`;
  }}

  // Subject status
  const hasSubject = d.subject_colors && d.subject_colors.length > 0 && d.subject_coverage > 0;
  let palettesHtml = '';
  if (hasSubject) {{
    palettesHtml = colorRows(d.subject_colors, `Arrangement (${{d.subject_coverage}}% coverage)`)
                 + colorRows(d.dominant_colors, 'Scene (full frame)');
  }} else {{
    palettesHtml = colorRows(d.dominant_colors, 'Scene (full frame)');
  }}

  // Quality flags
  const qf = d.quality_flags || {{}};
  const flagsHtml = Object.entries(qf).map(([k,v]) =>
    `<span>${{k.replace('_',' ')}}: ${{(v*100).toFixed(2)}}%</span>`
  ).join('');

  // Cluster info
  let clusterHtml = '';
  if (d.cluster) {{
    const cLabel = d.cluster_rank === 1 ? 'Best in cluster' : 'Duplicate';
    clusterHtml = `<div class="lb-section">
      <div class="lb-section-title">Cluster</div>
      <span style="font-size:0.8rem">Cluster ${{d.cluster}} &middot; ${{cLabel}}</span>
    </div>`;
  }}

  document.getElementById('lb-sidebar').innerHTML = `
    <h3>Image Details</h3>
    <div class="lb-filename">${{d.filename}}</div>

    <div class="lb-section">
      <div class="lb-section-title">Aesthetic Score</div>
      <div class="lb-score-big">${{d.score.toFixed(3)}}</div>
      ${{d.is_utility ? '<span style="font-size:0.7rem;color:#B8956A">Utility image</span>' : ''}}
    </div>

    <div class="lb-section">
      <div class="lb-section-title">Classification</div>
      <ul class="lb-label-list">${{labelsHtml}}</ul>
    </div>

    ${{palettesHtml}}
    ${{clusterHtml}}

    <div class="lb-section">
      <div class="lb-section-title">Quality Flags</div>
      <div class="lb-flags">${{flagsHtml}}</div>
    </div>
  `;
}}

document.addEventListener('keydown', e => {{
  if (currentIdx < 0) return;
  if (e.key === 'Escape') closeLightbox();
  if (e.key === 'ArrowRight') navLightbox(1);
  if (e.key === 'ArrowLeft') navLightbox(-1);
}});
</script>
</body>
</html>'''


def main():
    parser = argparse.ArgumentParser(description="Generate HTML contact sheet from VisionCull report")
    parser.add_argument("--report", required=True, help="Path to VisionCull JSON report")
    parser.add_argument("--output", help="Output HTML path (default: alongside report)")
    parser.add_argument("--images-base", help="Base directory for image paths")
    args = parser.parse_args()

    report_path = Path(args.report).expanduser().resolve()
    if not report_path.exists():
        print(f"Error: report not found: {report_path}", file=sys.stderr)
        sys.exit(1)

    with open(report_path) as f:
        report = json.load(f)

    output_path = args.output or str(report_path.parent / "contact_sheet.html")
    output_dir = Path(output_path).parent
    images_base = args.images_base or report.get("source", "")

    # Build ordered image list: selects first (in rank order), then rest by score
    selects_list = report.get("selects", [])
    selects_set = set(selects_list)
    images_by_name = {img["filename"]: img for img in report["images"]}

    ordered = []
    for fname in selects_list:
        if fname in images_by_name:
            ordered.append(images_by_name[fname])
    rest = sorted(
        [img for img in report["images"] if img["filename"] not in selects_set],
        key=lambda x: x.get("aesthetic_score", 0),
        reverse=True,
    )
    ordered.extend(rest)

    # Generate thumbnails
    print(f"Generating thumbnails for {len(ordered)} images...")
    thumb_map = generate_thumbnails(ordered, images_base, output_dir)
    print(f"  {len(thumb_map)} thumbnails ready")

    # Generate HTML
    html_content = generate_html(report, thumb_map, ordered)
    with open(output_path, "w") as f:
        f.write(html_content)

    print(f"Contact sheet: {output_path}")


if __name__ == "__main__":
    main()
