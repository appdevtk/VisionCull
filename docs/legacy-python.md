# VisionCull

**Cull 500 photos in ~73 seconds, fully on-device on Apple Silicon.**

![Python 3.14+](https://img.shields.io/badge/Python-3.14%2B-blue)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-lightgrey)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-Neural_Engine-black)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

VisionCull is a CLI tool that batch-scores, classifies, clusters, and ranks a folder of images using Apple's Vision framework — running entirely on the Neural Engine. No cloud, no subscription, no third-party ML models. Everything stays on your machine.

---

## Why VisionCull?

Manually culling 500 photos takes 30–45 minutes of scrolling. Aftershoot and similar tools send your images to the cloud and charge a subscription. Apple's Vision framework has been doing production-quality aesthetic scoring, duplicate detection, and scene classification on every M-series Mac for years — VisionCull exposes that capability as a fast, private CLI.

- **Private** — your images never leave your machine
- **Fast** — 483 images processed in ~73 seconds on M1 Pro
- **Free** — no subscription, no API keys, no model downloads
- **Accurate** — Neural Engine aesthetic scoring + subject-aware dual-palette analysis

---

## What It Does

VisionCull runs up to four Vision framework requests per image:

| Analysis | API | Output |
|---|---|---|
| **Aesthetic scoring** | `VNCalculateImageAestheticsScoresRequest` | 0–1 score, quality flags (utility, blurry, screenshot) |
| **Scene classification** | `VNClassifyImageRequest` | Top labels with confidence (flower, indoor, person, etc.) |
| **Duplicate detection** | `VNGenerateImageFeaturePrintRequest` | Feature vectors → cosine-distance clustering |
| **Subject lifting** | `VNGenerateForegroundInstanceMaskRequest` | Foreground mask → subject color palette |

Results are written to a JSON report. Selects are copied to an output directory. An optional HTML contact sheet gives you a visual grid with scores, palettes, and labels.

---

## Requirements

- macOS 15+ (Sequoia or later)
- Apple Silicon Mac (M1 or newer) — Vision framework + Neural Engine
- Python 3.12+

> **Note:** `pyobjc-framework-Vision` requires macOS — this tool does not run on Linux or Windows.

---

## Install

```bash
git clone https://github.com/echase/VisionCull.git
cd VisionCull
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

---

## Usage

```bash
# Score and rank a folder, copy top 40 selects
python3 visioncull.py ~/Photos/shoot/ --output ~/Photos/selects/

# With duplicate clustering (removes near-identical shots)
python3 visioncull.py ~/Photos/shoot/ --output ~/selects/ --duplicates

# Filter by scene classification label
python3 visioncull.py ~/Photos/shoot/ --tags flower,indoor --selects 20

# Full pipeline: deduplicate, classify, subject analysis, ranked report
python3 visioncull.py ~/Photos/shoot/ \
  --output ~/Photos/selects/ \
  --selects 40 \
  --duplicates --threshold 0.92 \
  --subject \
  --tags flower,table,outdoor \
  --report report.json \
  --rank-prefix

# Enrich selects with Claude Vision descriptions (requires ANTHROPIC_API_KEY)
python3 visioncull.py ~/Photos/shoot/ --output ~/selects/ --enrich
```

### All flags

| Flag | Default | Description |
|---|---|---|
| `input_dir` | *(required)* | Directory of images to score |
| `--output PATH` | — | Copy selects here |
| `--selects N` | `40` | Number of selects to pick |
| `--duplicates` | off | Enable duplicate clustering |
| `--threshold FLOAT` | `0.92` | Cosine similarity threshold for duplicates |
| `--report PATH` | — | Write full JSON report to this path |
| `--rank-prefix` | off | Prefix selects with rank: `01_IMG_4521.jpg` |
| `--min-score FLOAT` | `0.0` | Reject images below this aesthetic score |
| `--subject` | off | Foreground subject lifting (dual-palette analysis) |
| `--tags LABELS` | — | Comma-separated labels to filter selects |
| `--enrich` | off | Enrich selects with Claude Vision descriptions |
| `--enrich-all` | off | Enrich all processed images |

---

## Contact Sheet

Generate an interactive HTML contact sheet from any report:

```bash
python3 contact_sheet.py --report report.json --output contact_sheet.html
```

The contact sheet renders thumbnails in ranked order with aesthetic score bars, subject/scene color palettes, classification labels, and a lightbox with full EXIF detail.

---

## Performance (M1 Pro, 16GB)

| Metric | Value |
|---|---|
| Corpus size | 483 images |
| Total wall time | ~73 seconds |
| Aesthetic score request (warm) | ~10ms/image |
| Classification request (warm) | ~10ms/image |
| Feature print request (warm) | ~10ms/image |
| Foreground mask request (warm) | ~23ms/image |
| 4-request batch (warm) | ~31ms/image steady state |
| Peak RSS | ~3 GB (plateaus and holds flat) |
| Subject detection rate | 88% (425/483 images) |

Memory is bounded via per-iteration `objc.autorelease_pool()` and periodic `gc.collect()`. The RSS plateau holds steady through large corpora.

---

## Architecture

```
Input folder
    │
    ▼
scan_images()           ← find .jpg/.jpeg/.png/.heic/.tiff
    │
    ▼
analyze_image()         ← per-image: aesthetic + classify + featureprint + optional mask
    │                      runs in objc.autorelease_pool() per iteration
    ▼
extract_dominant_colors()  ← Pillow-based dominant color extraction
    │
    ▼  (if --subject)
_extract_subject_colors()  ← masked-image → CIContext → CGImage → numpy → HSL naming
    │
    ▼  (if --duplicates)
cluster_duplicates()    ← cosine distance on feature vectors → clusters, best-per-cluster
    │
    ▼
rank_and_select()       ← sort by aesthetic score, apply filters, pick top N
    │
    ├── generate_report()   → JSON report
    ├── copy_selects()      → output directory
    └── contact_sheet.py    → HTML grid (separate command)
```

### Dual-palette output

When `--subject` is enabled, each image gets two color palettes:

- **`subject_colors`** — extracted from the foreground subject (arrangement, product, etc.) via `VNGenerateForegroundInstanceMaskRequest` → masked render → alpha-channel filtering
- **`dominant_colors`** — full-frame dominant colors via Pillow

Both palettes include HSL-derived color names and coverage percentages.

---

## Report format

```json
{
  "source": "/path/to/photos",
  "total_images": 483,
  "processed": 483,
  "processing_time_seconds": 54.6,
  "selects": ["IMG_4521.jpg", "IMG_4087.jpg"],
  "images": [
    {
      "filename": "IMG_4521.jpg",
      "aesthetic_score": 0.87,
      "classifications": [
        {"label": "flower", "confidence": 0.94},
        {"label": "indoor", "confidence": 0.89}
      ],
      "subject_lift_status": "success",
      "subject_colors": [
        {"hex": "#F5E6D3", "name": "peach", "coverage_pct": 34.1}
      ],
      "dominant_colors": [
        {"hex": "#2D4A3E", "name": "forest green", "coverage_pct": 28.7}
      ],
      "duplicate_cluster": 3,
      "cluster_rank": 1,
      "recommended": true,
      "recommendation_reason": "High aesthetic score, best in duplicate cluster"
    }
  ]
}
```

---

## pyobjc binding notes

See [`docs/pyobjc_probes.md`](pyobjc_probes.md) for documented Vision framework binding patterns, including:

- `computeDistance` returning `(True, None)` — use numpy cosine on raw vectors instead
- `generateScaledMaskForImage` extraction failures — use `generateMaskedImageOfInstances` instead
- `CVPixelBufferGetBaseAddress` returning `objc.varlist` — go CIContext → CGImage → numpy
- Autorelease pool requirement for per-iteration loops

---

## Conduit integration

VisionCull's scoring and classification functions are designed to be exposable as [Conduit](https://github.com/echase) co-yield endpoints — an agent sends a batch of image paths, the local tool returns scored results. The Vision framework calls are the exact kind of task co-yield was designed for: bounded, compute-local, latency-sensitive, privacy-preserving.

Standalone first. Conduit integration is Phase 4.

---

## Case study

See [`docs/case-study.md`](case-study.md) for a full writeup on how VisionCull was built, the hard-won pyobjc patterns, and real performance data from a production photo curation run.

---

## License

MIT — see [LICENSE](LICENSE).
