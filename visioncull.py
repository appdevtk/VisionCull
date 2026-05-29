#!/usr/bin/env python3
"""VisionCull — batch image scoring, classification, and curation using Apple Vision framework."""

import argparse
import ctypes
import gc
import json
import os
import resource
import shutil
import sys
import time
from collections import Counter
from pathlib import Path

import numpy as np
from PIL import Image

import objc

import Cocoa
import Quartz
import Vision


def _get_rss_mb():
    """Return current RSS in MB (macOS reports ru_maxrss in bytes)."""
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024)

IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".heic", ".tiff", ".tif"}
LABEL_CONFIDENCE_THRESHOLD = 0.05


def scan_images(input_dir):
    path = Path(input_dir).expanduser().resolve()
    if not path.is_dir():
        print(f"Error: {input_dir} is not a directory", file=sys.stderr)
        sys.exit(1)
    images = sorted(
        p for p in path.iterdir()
        if p.is_file() and p.suffix.lower() in IMAGE_EXTENSIONS
    )
    return images


def analyze_image(image_path, subject_aware=False):
    """Run aesthetic scoring, classification, feature extraction, and optional foreground mask."""
    url = Cocoa.NSURL.fileURLWithPath_(str(image_path))
    handler = Vision.VNImageRequestHandler.alloc().initWithURL_options_(url, None)

    aesthetic_req = Vision.VNCalculateImageAestheticsScoresRequest.alloc().init()
    classify_req = Vision.VNClassifyImageRequest.alloc().init()
    featureprint_req = Vision.VNGenerateImageFeaturePrintRequest.alloc().init()

    requests = [aesthetic_req, classify_req, featureprint_req]

    mask_req = None
    if subject_aware:
        mask_req = Vision.VNGenerateForegroundInstanceMaskRequest.alloc().init()
        requests.append(mask_req)

    success, error = handler.performRequests_error_(requests, None)

    if not success:
        return None

    result = {}

    # Aesthetic scores
    if aesthetic_req.results():
        obs = aesthetic_req.results()[0]
        result["aesthetic_score"] = obs.overallScore()
        result["is_utility"] = bool(obs.isUtility())
        result["quality_flags"] = {
            "failure": obs.failureScore(),
            "poor_quality": obs.poorQualityScore(),
            "screenshot": obs.screenShotScore(),
            "text_document": obs.textDocumentScore(),
        }

    # Classification labels
    if classify_req.results():
        labels = []
        for r in classify_req.results():
            if r.confidence() >= LABEL_CONFIDENCE_THRESHOLD:
                labels.append({"name": r.identifier(), "confidence": round(r.confidence(), 4)})
        labels.sort(key=lambda x: -x["confidence"])
        result["labels"] = labels

    # Feature vector
    if featureprint_req.results():
        fp = featureprint_req.results()[0]
        raw = bytes(fp.data())
        result["feature_vector"] = np.frombuffer(raw, dtype=np.float32).copy()

    # Foreground mask → subject colors
    if mask_req and mask_req.results():
        mask_obs = mask_req.results()[0]
        try:
            colors, coverage = _extract_subject_colors(mask_obs, handler)
            result["subject_colors"] = colors
            result["subject_coverage"] = coverage
        except Exception:
            result["subject_colors"] = []
            result["subject_coverage"] = 0

    return result


def _extract_subject_colors(mask_obs, handler, n=5):
    """Extract named colors from foreground-only pixels of a masked image."""
    instances = mask_obs.allInstances()
    masked_buf, err = mask_obs.generateMaskedImageOfInstances_fromRequestHandler_croppedToInstancesExtent_error_(
        instances, handler, False, None
    )
    if masked_buf is None:
        return []

    # CVPixelBuffer → CIImage → CGImage → numpy RGBA
    ci_masked = Quartz.CIImage.imageWithCVPixelBuffer_(masked_buf)
    ctx = Quartz.CIContext.contextWithOptions_(None)
    extent = ci_masked.extent()
    cg_masked = ctx.createCGImage_fromRect_(ci_masked, extent)

    cg_w = Quartz.CGImageGetWidth(cg_masked)
    cg_h = Quartz.CGImageGetHeight(cg_masked)
    color_space = Quartz.CGColorSpaceCreateDeviceRGB()

    bitmap_ctx = Quartz.CGBitmapContextCreate(
        None, cg_w, cg_h, 8, cg_w * 4,
        color_space,
        Quartz.kCGImageAlphaPremultipliedLast,  # RGBA
    )
    Quartz.CGContextDrawImage(bitmap_ctx, ((0, 0), (cg_w, cg_h)), cg_masked)
    data_ptr = Quartz.CGBitmapContextGetData(bitmap_ctx)

    buf_len = cg_w * cg_h * 4
    raw_bytes = data_ptr.as_buffer(buf_len)
    arr = np.frombuffer(raw_bytes, dtype=np.uint8).reshape(cg_h, cg_w, 4)

    r, g, b, a = arr[:, :, 0], arr[:, :, 1], arr[:, :, 2], arr[:, :, 3]

    # Filter to foreground pixels (alpha > 128)
    fg_mask = a > 128
    fg_count = int(fg_mask.sum())
    total = cg_w * cg_h
    coverage = round(fg_count / total * 100, 1) if total > 0 else 0

    if fg_count == 0:
        return [], 0

    fg_r, fg_g, fg_b = r[fg_mask], g[fg_mask], b[fg_mask]

    # Downsample for speed — 10k pixels is plenty for color distribution
    step = max(1, fg_count // 10000)
    counts = Counter()
    for ri, gi, bi in zip(fg_r[::step], fg_g[::step], fg_b[::step]):
        counts[_rgb_to_color_name(int(ri), int(gi), int(bi))] += 1

    total_sampled = sum(counts.values())
    colors = [
        {"color": color, "percentage": round(count / total_sampled * 100, 1)}
        for color, count in counts.most_common(n)
    ]
    return colors, coverage


def extract_dominant_colors(image_path, n=5):
    """Extract dominant named colors from an image via pixel sampling."""
    img = Image.open(image_path).convert("RGB")
    img_small = img.resize((80, 80), Image.LANCZOS)
    pixels = list(img_small.get_flattened_data())

    counts = Counter()
    for r, g, b in pixels:
        counts[_rgb_to_color_name(r, g, b)] += 1

    total = len(pixels)
    return [
        {"color": color, "percentage": round(count / total * 100, 1)}
        for color, count in counts.most_common(n)
    ]


def _rgb_to_color_name(r, g, b):
    brightness = (r + g + b) / 3
    saturation = max(r, g, b) - min(r, g, b)

    if brightness < 35:
        return "black"
    if brightness > 220 and saturation < 30:
        return "white"
    if saturation < 20:
        return "gray"

    # Use hue-based classification for saturated colors
    if max(r, g, b) == 0:
        return "black"

    # Convert to HSL-ish hue
    cmax = max(r, g, b)
    cmin = min(r, g, b)
    delta = cmax - cmin
    if delta == 0:
        return "gray"

    if cmax == r:
        hue = 60 * (((g - b) / delta) % 6)
    elif cmax == g:
        hue = 60 * (((b - r) / delta) + 2)
    else:
        hue = 60 * (((r - g) / delta) + 4)

    if hue < 0:
        hue += 360

    lightness = (cmax + cmin) / 2

    if lightness < 40:
        if 15 < hue < 45:
            return "brown"
        return "black"

    if hue < 15 or hue >= 345:
        return "pink" if lightness > 170 else "red"
    if hue < 45:
        return "orange" if saturation > 80 else "brown"
    if hue < 70:
        return "yellow"
    if hue < 165:
        return "green"
    if hue < 195:
        return "teal"
    if hue < 260:
        return "blue"
    if hue < 290:
        return "purple"
    return "pink"


class UnionFind:
    def __init__(self, n):
        self.parent = list(range(n))
        self.rank = [0] * n

    def find(self, x):
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def union(self, x, y):
        rx, ry = self.find(x), self.find(y)
        if rx == ry:
            return
        if self.rank[rx] < self.rank[ry]:
            rx, ry = ry, rx
        self.parent[ry] = rx
        if self.rank[rx] == self.rank[ry]:
            self.rank[rx] += 1


def cluster_duplicates(image_data, threshold):
    """Cluster images by feature vector cosine similarity."""
    vectors = []
    indices = []
    for i, img in enumerate(image_data):
        if "feature_vector" in img:
            vectors.append(img["feature_vector"])
            indices.append(i)

    if len(vectors) < 2:
        return []

    mat = np.stack(vectors)
    norms = np.linalg.norm(mat, axis=1, keepdims=True)
    norms = np.where(norms == 0, 1, norms)
    mat_normalized = mat / norms
    similarity = mat_normalized @ mat_normalized.T

    uf = UnionFind(len(vectors))
    for i in range(len(vectors)):
        for j in range(i + 1, len(vectors)):
            if similarity[i, j] >= threshold:
                uf.union(i, j)

    clusters_map = {}
    for i in range(len(vectors)):
        root = uf.find(i)
        if root not in clusters_map:
            clusters_map[root] = []
        clusters_map[root].append(indices[i])

    # Only keep clusters with >1 member
    clusters = []
    cluster_id = 1
    for members in clusters_map.values():
        if len(members) > 1:
            best_idx = max(members, key=lambda i: image_data[i].get("aesthetic_score", 0))
            clusters.append({
                "cluster_id": cluster_id,
                "count": len(members),
                "best_index": best_idx,
                "member_indices": sorted(members),
            })
            for idx in members:
                image_data[idx]["duplicate_cluster"] = cluster_id
                image_data[idx]["cluster_rank"] = 1 if idx == best_idx else 0
            cluster_id += 1

    return clusters


def rank_and_select(image_data, n_selects, tags_filter=None):
    """Rank images and pick top N selects."""
    candidates = []
    for i, img in enumerate(image_data):
        # Skip non-best duplicates
        if img.get("cluster_rank") == 0:
            continue

        # Apply tag filter
        if tags_filter:
            img_labels = {l["name"] for l in img.get("labels", [])}
            if not img_labels & tags_filter:
                continue

        candidates.append(i)

    candidates.sort(key=lambda i: image_data[i].get("aesthetic_score", 0), reverse=True)
    return candidates[:n_selects]


def enrich_descriptions(image_data, select_indices, enrich_all=False):
    """Add natural language descriptions via Claude Vision API."""
    try:
        import anthropic
    except ImportError:
        print("Warning: anthropic package not installed. Skipping enrichment.", file=sys.stderr)
        print("  Install with: pip install anthropic", file=sys.stderr)
        return

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        key_file = Path.home() / ".anthropic" / "api_key"
        if key_file.exists():
            api_key = key_file.read_text().strip()
    if not api_key:
        print("Warning: No ANTHROPIC_API_KEY found. Skipping enrichment.", file=sys.stderr)
        return

    client = anthropic.Anthropic(api_key=api_key)
    indices = list(range(len(image_data))) if enrich_all else select_indices

    print(f"  Enriching:  {len(indices)} images via Claude Vision API...")
    for count, idx in enumerate(indices, 1):
        img = image_data[idx]
        img_path = img["path"]

        try:
            with Image.open(img_path) as pil_img:
                pil_img = pil_img.convert("RGB")
                max_dim = 1024
                if max(pil_img.size) > max_dim:
                    ratio = max_dim / max(pil_img.size)
                    new_size = (int(pil_img.size[0] * ratio), int(pil_img.size[1] * ratio))
                    pil_img = pil_img.resize(new_size, Image.LANCZOS)

                import base64
                import io
                buf = io.BytesIO()
                pil_img.save(buf, format="JPEG", quality=85)
                b64_data = base64.b64encode(buf.getvalue()).decode()

            response = client.messages.create(
                model="claude-sonnet-4-20250514",
                max_tokens=200,
                messages=[{
                    "role": "user",
                    "content": [
                        {
                            "type": "image",
                            "source": {"type": "base64", "media_type": "image/jpeg", "data": b64_data},
                        },
                        {
                            "type": "text",
                            "text": "Describe this image in 1-2 sentences. Note the type of floral arrangement if present, flowers visible, colors, setting, and any notable details.",
                        },
                    ],
                }],
            )
            img["description"] = response.content[0].text
            sys.stdout.write(f"\r  Enriching:  {count}/{len(indices)}")
            sys.stdout.flush()

        except Exception as e:
            img["description"] = f"[enrichment failed: {e}]"

    print()


def generate_report(image_data, clusters, select_indices, source_dir, processing_time, output_path):
    """Write JSON report."""
    images_out = []
    select_set = set(select_indices)

    for img in image_data:
        entry = {
            "filename": img["filename"],
            "path": img["path"],
            "aesthetic_score": round(img.get("aesthetic_score", 0), 4),
            "is_utility": img.get("is_utility", False),
            "quality_flags": {
                k: round(v, 6) for k, v in img.get("quality_flags", {}).items()
            },
            "labels": img.get("labels", []),
            "dominant_colors": img.get("dominant_colors", []),
            "subject_colors": img.get("subject_colors", []),
            "subject_coverage": img.get("subject_coverage", 0),
        }
        if "duplicate_cluster" in img:
            entry["duplicate_cluster"] = img["duplicate_cluster"]
            entry["cluster_rank"] = img["cluster_rank"]
        entry["recommended"] = img.get("_index") in select_set
        if "description" in img:
            entry["description"] = img["description"]
        images_out.append(entry)

    clusters_out = []
    for c in clusters:
        clusters_out.append({
            "cluster_id": c["cluster_id"],
            "count": c["count"],
            "best": image_data[c["best_index"]]["filename"],
            "members": [image_data[i]["filename"] for i in c["member_indices"]],
        })

    report = {
        "source": str(source_dir),
        "total_images": len(image_data),
        "processed": len(image_data),
        "processing_time_seconds": round(processing_time, 1),
        "images": images_out,
        "duplicate_clusters": clusters_out,
        "selects": [image_data[i]["filename"] for i in select_indices],
    }

    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(report, f, indent=2)


def copy_selects(image_data, select_indices, output_dir, rank_prefix=False):
    """Copy selected images to output directory."""
    output = Path(output_dir).expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)

    for rank, idx in enumerate(select_indices, 1):
        src = Path(image_data[idx]["path"])
        if rank_prefix:
            dest = output / f"{rank:02d}_{src.name}"
        else:
            dest = output / src.name
        shutil.copy2(src, dest)


def main():
    parser = argparse.ArgumentParser(
        description="Batch image scoring and curation using Apple Vision framework"
    )
    parser.add_argument("input_dir", help="Directory of images to process")
    parser.add_argument("--output", help="Directory to copy selects to")
    parser.add_argument("--selects", type=int, default=40, help="Number of selects (default: 40)")
    parser.add_argument("--duplicates", action="store_true", help="Enable duplicate clustering")
    parser.add_argument("--threshold", type=float, default=0.92, help="Duplicate similarity threshold (default: 0.92)")
    parser.add_argument("--report", help="JSON report output path")
    parser.add_argument("--rank-prefix", action="store_true", help="Prefix selects with rank number")
    parser.add_argument("--min-score", type=float, default=0.0, help="Minimum aesthetic score")
    parser.add_argument("--enrich", action="store_true", help="Enrich selects with Claude Vision descriptions")
    parser.add_argument("--enrich-all", action="store_true", help="Enrich ALL images with Claude Vision descriptions")
    parser.add_argument("--subject", action="store_true", help="Enable subject-aware foreground analysis (adds subject_colors, subject_coverage)")
    parser.add_argument("--tags", help="Comma-separated labels to filter selects (e.g., flower,rose)")
    args = parser.parse_args()

    # Scan
    images = scan_images(args.input_dir)
    if not images:
        print("No images found.", file=sys.stderr)
        sys.exit(1)

    print(f"Scanning {len(images)} images...")
    start_time = time.time()

    # Analyze (aesthetic + classification + feature vectors + optional subject mask)
    image_data = []
    t0 = time.time()
    print(f"[mem] baseline: {_get_rss_mb():.0f} MB RSS", file=sys.stderr)
    for i, img_path in enumerate(images):
        sys.stdout.write(f"\r  Analyzing:  {i + 1}/{len(images)}")
        sys.stdout.flush()
        with objc.autorelease_pool():
            result = analyze_image(img_path, subject_aware=args.subject)
            if result is None:
                result = {}
            result["filename"] = img_path.name
            result["path"] = str(img_path)
            result["_index"] = i
            image_data.append(result)
        if (i + 1) % 5 == 0 or i == len(images) - 1:
            gc.collect()
            print(f"[mem] image {i + 1}/{len(images)}: {_get_rss_mb():.0f} MB RSS", file=sys.stderr)
    t_analyze = time.time() - t0
    print(f"  ({t_analyze:.1f}s)")
    print(f"[mem] post-analyze: {_get_rss_mb():.0f} MB RSS", file=sys.stderr)

    # Dominant colors
    t0 = time.time()
    for i, img in enumerate(image_data):
        sys.stdout.write(f"\r  Colors:     {i + 1}/{len(image_data)}")
        sys.stdout.flush()
        with objc.autorelease_pool():
            try:
                img["dominant_colors"] = extract_dominant_colors(img["path"])
            except Exception:
                img["dominant_colors"] = []
    t_colors = time.time() - t0
    print(f"  ({t_colors:.1f}s)")
    print(f"[mem] post-colors: {_get_rss_mb():.0f} MB RSS", file=sys.stderr)

    # Filter by min score
    if args.min_score > 0:
        for img in image_data:
            if img.get("aesthetic_score", 0) < args.min_score:
                img["_below_min"] = True

    # Duplicate clustering
    clusters = []
    if args.duplicates:
        t0 = time.time()
        clusters = cluster_duplicates(image_data, args.threshold)
        t_cluster = time.time() - t0
        dup_count = sum(c["count"] for c in clusters)
        print(f"  Clustering: done     ({t_cluster:.1f}s)")
    else:
        print("  Clustering: skipped")

    processing_time = time.time() - start_time

    # Select
    tags_filter = set(args.tags.split(",")) if args.tags else None
    select_indices = rank_and_select(image_data, args.selects, tags_filter)

    # Enrich
    if args.enrich or args.enrich_all:
        enrich_descriptions(image_data, select_indices, enrich_all=args.enrich_all)

    # Summary
    print()
    print("Results:")
    if clusters:
        dup_images = sum(c["count"] for c in clusters)
        print(f"  Duplicate clusters: {len(clusters)} ({dup_images} images)")

    # Top labels across all images
    label_counts = Counter()
    for img in image_data:
        for l in img.get("labels", []):
            label_counts[l["name"]] += 1
    if label_counts:
        top = ", ".join(f"{name}({count})" for name, count in label_counts.most_common(5))
        print(f"  Top labels: {top}")

    print(f"  Selects: {len(select_indices)}")

    if args.subject:
        coverages = [img.get("subject_coverage", 0) for img in image_data if img.get("subject_coverage", 0) > 0]
        if coverages:
            avg_cov = sum(coverages) / len(coverages)
            print(f"  Subject coverage: {avg_cov:.1f}% avg ({len(coverages)}/{len(image_data)} with foreground)")
        # Top subject colors across selects
        subj_color_counts = Counter()
        for idx in select_indices:
            for c in image_data[idx].get("subject_colors", []):
                subj_color_counts[c["color"]] += 1
        if subj_color_counts:
            top_sc = ", ".join(f"{name}({count})" for name, count in subj_color_counts.most_common(5))
            print(f"  Top subject colors (selects): {top_sc}")

    # Report
    if args.output:
        report_path = args.report or str(Path(args.output).expanduser().resolve() / "report.json")
    else:
        report_path = args.report or "report.json"

    generate_report(image_data, clusters, select_indices, args.input_dir, processing_time, report_path)
    print(f"\n  Report: {report_path}")

    # Copy selects
    if args.output:
        copy_selects(image_data, select_indices, args.output, args.rank_prefix)
        print(f"  Selects copied to: {Path(args.output).expanduser().resolve()}")

    # Score range summary
    scores = [img.get("aesthetic_score", 0) for img in image_data]
    if scores:
        print(f"\n  Score range: {min(scores):.3f} - {max(scores):.3f} (median: {sorted(scores)[len(scores)//2]:.3f})")


if __name__ == "__main__":
    main()
