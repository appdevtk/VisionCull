# VisionCull: Culling 500 Photos in 73 Seconds with Apple's Vision Framework

*How I built a privacy-first, on-device image curation CLI using pyobjc and Apple Silicon's Neural Engine — and what I learned about binding patterns, memory management, and the real performance ceiling.*

---

## The problem

A client arrived with 500 photos from a recent event. Some iPhone, some DSLR. Mix of beautiful arrangements, unlit corners of a catering hall, someone's elbow, and 60 near-identical shots of the same centerpiece from 60 angles.

The ask: cull to 30–40 selects, organized by shoot category, ready for web. The manual process — import to Lightroom, scroll, flag, compare — runs 30–45 minutes minimum, and that's with a trained eye and a fast machine.

I'd been aware that Apple's Vision framework has been doing production-quality aesthetic scoring and scene classification for years. Every M-series Mac has a Neural Engine sitting idle. So I decided to find out whether I could route the entire culling pipeline through it.

---

## Why not a SaaS tool?

Aftershoot is the obvious comparison. It's good. But:

- **Cost** — subscription or per-image pricing adds up across multiple client engagements
- **Privacy** — client photos leave your machine. For some clients that's a non-starter.
- **Speed** — round-trip to cloud + back isn't dramatically faster than local when the local hardware is this capable
- **Lock-in** — you're dependent on their API staying up and their model not changing underneath you

Apple's Vision framework is free, on-device, and has been running in production across millions of Macs since macOS 12. The performance story turns out to be significantly better than I expected.

---

## The Vision framework surface area

Everything I needed was already in the OS. Four Vision requests power the whole pipeline:

**`VNCalculateImageAestheticsScoresRequest`** — The star. Returns an `overallScore` (0–1) representing composition, lighting, and visual appeal. Also surfaces quality flags: `isUtility` (screenshot, document), `failureScore`, `poorQualityScore`, `screenShotScore`. This single request does most of the culling work.

**`VNGenerateImageFeaturePrintRequest`** — Produces a feature embedding per image. Cosine distance between embeddings identifies near-duplicate shots. Critical for event photography where clients take 15 versions of the same arrangement.

**`VNClassifyImageRequest`** — Scene and object classification against 1000+ labels. Returns confidence-ranked labels like `flower`, `indoor`, `table`, `person`. Lets you filter selects by subject without manually reviewing every image.

**`VNGenerateForegroundInstanceMaskRequest`** — The most technically interesting one. Generates a per-pixel mask of the foreground subject. I use it to extract a "subject palette" that isolates the arrangement colors from the venue background — relevant for any project where subject color matters independently of the scene.

All four run via `pyobjc-framework-Vision` in Python, dispatched to the Neural Engine on M1.

---

## The 140-second lesson

The first working pipeline took 140 seconds for 50 images. That's 2.8 seconds per image — completely unacceptable.

The cause was embarrassingly simple: I was re-warming the Vision models on every image. The first request to the Neural Engine carries a cold-start cost (~2 seconds for framework init + model load). Subsequent requests on a warm model run in 10–23ms. My loop was somehow invalidating the warm state.

The fix: probe first, pipeline second. Run each Vision request in isolation against a single image, time it warm, then build the loop knowing exactly what the steady-state latency should be. This discipline — timing individual API calls before timing pipelines — is now my default methodology for any local ML work.

After the fix:
- Aesthetic score request (warm): ~10ms/image
- Classification request (warm): ~10ms/image
- Feature print request (warm): ~10ms/image
- Foreground mask request (warm): ~23ms/image

Total 4-request batch (warm): ~31ms/image steady state.

---

## Memory: the real ceiling

With the performance problem solved, the next issue was memory. Processing 483 images with four Vision requests each, including `CIImage` and `CVPixelBuffer` intermediates for the mask extraction, piled up. RSS climbed past 2GB, then 2.5GB, still climbing.

macOS releases this memory — eventually — but under GCD the cleanup is asynchronous. In a tight Python loop, "eventually" means "never before your process gets killed."

Three interventions, applied in order of impact:

**`objc.autorelease_pool()`** around every image iteration. This is the mandatory pattern for any pyobjc loop that creates ObjC objects. Without it, autoreleased objects accumulate until the loop finishes. With it, they're drained after each image.

**`gc.collect()` every 5 images.** Python's cyclic garbage collector doesn't know about ObjC reference counts. Calling it periodically handles any Python-side cycles that would otherwise defer cleanup.

**Deferred resolution downscaling.** Full-resolution inputs to the Neural Engine cost proportionally more memory than the scoring accuracy gains. Downscaling to 2048px before analysis would cut peak RSS substantially. I documented this for Phase A.5 but didn't implement it yet — the autorelease pool alone brought the pipeline to a stable plateau.

The result: peak RSS of ~3GB, plateauing at image 345 and holding flat for the remaining 138 images. In a 483-image corpus, stability matters more than the peak number.

---

## Subject lifting: the hard part

`VNGenerateForegroundInstanceMaskRequest` sounds straightforward. It was not.

pyobjc's bindings for the mask extraction methods are incomplete or undocumented in several places. Lessons learned the hard way:

**`computeDistance_toFeaturePrint_error_` returns `(True, None)`.** The result is in the first return value, not the error slot. The binding wraps the out-parameter differently than you'd expect from the Swift docs. Use numpy cosine distance on the raw vectors instead.

**`generateScaledMaskForImage_forInstances_error_` silently fails.** Use `generateMaskedImageOfInstances_fromRequestHandler_error_` instead. The scaled variant is unreliable through pyobjc; the instances variant works consistently.

**`CVPixelBufferGetBaseAddress` returns `objc.varlist`, not bytes.** You can't pass it directly to numpy. The path that works: `CIContext` → render to `CGImage` → export as JPEG/PNG bytes → numpy array → alpha channel filter. One extra render step, but reliable.

All four patterns are documented in [`docs/pyobjc_probes.md`](pyobjc_probes.md) for reference.

The subject lifting pipeline, once working, produces meaningful results. From a corpus of 483 floristry images, 88% (425/483) produced detectable foreground subjects. The 12% failure cases cluster predictably: full-frame table shots where the "foreground" is ambiguous, outdoor installations where sky and subject blend, and a handful of edge cases where the arrangement is entirely white against a white background (the Vision segmenter correctly identifies no salient foreground).

---

## Real numbers

Running the full 4-request pipeline on 483 floristry images on M1 Pro, 16GB:

| Metric | Value |
|---|---|
| Aesthetic scoring (483 images) | 54.6s |
| Dominant color extraction | 17.8s |
| Total wall time | ~73s |
| Peak RSS | ~3,027 MB |
| RSS plateau at image | 345 |
| Subject detection rate | 88% (425/483) |
| Duplicate clusters detected | 47 clusters, 189 images |

For context: Aftershoot's reported processing time for a similar corpus on M1 hardware is 90–120 seconds, with cloud round-trips adding variable latency. VisionCull runs in 73 seconds, entirely local, with zero data egress.

---

## What the output looks like

The JSON report structures each image with its full analysis:

```json
{
  "filename": "IMG_4521.jpg",
  "aesthetic_score": 0.87,
  "classifications": [
    {"label": "flower", "confidence": 0.94},
    {"label": "indoor", "confidence": 0.89},
    {"label": "table", "confidence": 0.71}
  ],
  "subject_lift_status": "success",
  "subject_colors": [
    {"hex": "#F5E6D3", "name": "peach", "coverage_pct": 34.1},
    {"hex": "#FFFFFF", "name": "white", "coverage_pct": 28.3}
  ],
  "dominant_colors": [
    {"hex": "#2D4A3E", "name": "forest green", "coverage_pct": 28.7},
    {"hex": "#C4A882", "name": "tan", "coverage_pct": 22.1}
  ],
  "duplicate_cluster": 3,
  "cluster_rank": 1,
  "recommended": true,
  "recommendation_reason": "High aesthetic score, best in duplicate cluster"
}
```

The contact sheet generator (`contact_sheet.py`) turns this report into an interactive HTML grid — ranked thumbnails with score bars, hover-revealed palettes and labels, and a lightbox with full EXIF detail. The entire thing is a self-contained HTML file with inline CSS and JS.

---

## The Conduit thesis

VisionCull is also a proof-of-concept for a broader architecture I'm building called Conduit — a local agent routing layer that treats Apple Silicon ML frameworks as the default fast path for compute-local tasks.

The idea: when an agent needs to analyze images, score aesthetics, detect objects, transcribe audio, or perform other bounded ML tasks, it shouldn't be reflexively routing to a cloud API. The hardware in the room is already capable. The economics, latency, and privacy characteristics are all better on-device.

VisionCull demonstrates this concretely:
- **Cost**: $0 vs. ~$0.01–0.03/image via cloud vision APIs
- **Latency**: ~31ms/image local vs. ~800ms/image cloud round-trip
- **Privacy**: zero data egress
- **Reliability**: zero external dependency

A Conduit Phase 3 will expose the VisionCull scoring functions as co-yield endpoints — an agent sends a batch of image paths, the local tool returns scored results, the agent acts on them. The Vision framework calls are exactly the kind of task co-yield was designed for: bounded, compute-local, latency-sensitive, privacy-preserving.

---

## The tool

VisionCull is open-source, MIT licensed, and available at [github.com/echase/VisionCull](https://github.com/echase/VisionCull).

Requirements: macOS 15+, Apple Silicon, Python 3.12+. Install is `pip install -r requirements.txt` (three dependencies: `pyobjc-framework-Vision`, `numpy`, `Pillow`).

The pyobjc binding gotchas are documented in [`docs/pyobjc_probes.md`](pyobjc_probes.md). If you're integrating Vision framework into Python for any use case beyond image culling, that file will save you several hours.
