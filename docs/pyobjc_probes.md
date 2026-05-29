# pyobjc + Apple Vision Framework — Binding Gotchas

Pattern reference for VisionCull development. Each entry documents a pyobjc binding issue encountered during Phase A development (macOS 26.4.1, pyobjc-framework-Vision 12.1, M1 Pro).

---

## 1. `computeDistance` returns `(True, None)`

**API:** `VNFeaturePrintObservation.computeDistance_toFeaturePrintObservation_error_`

**Expected:** Returns the cosine distance as a float via the out-parameter.

**Actual:** pyobjc binding returns `(True, None)` — the success bool works but the distance value is lost in the objc-to-Python bridge.

**Workaround:** Extract raw feature vectors and compute similarity in numpy:

```python
fp = featureprint_req.results()[0]
raw = bytes(fp.data())
vec = np.frombuffer(raw, dtype=np.float32).copy()
# 768-dim unit-normalized float32 vectors
# Cosine similarity: mat_normalized @ mat_normalized.T
```

---

## 2. `generateScaledMaskForImage` pixel extraction fails

**API:** `VNInstanceMaskObservation.generateScaledMaskForImageForInstances_fromRequestHandler_error_`

**Expected:** Returns a CVPixelBuffer of the scaled mask whose pixels can be read.

**Actual:** Method executes and returns a CVPixelBuffer with correct dimensions, but extracting pixel data via `CVPixelBufferGetBaseAddress` raises `TypeError: integer expected`.

**Workaround:** Use `generateMaskedImageOfInstances_fromRequestHandler_croppedToInstancesExtent_error_` instead. This returns a full-resolution BGRA CVPixelBuffer with the foreground composited on a transparent/black background. Convert through CIContext for reliable pixel access (see entry 3).

```python
instances = mask_obs.allInstances()
masked_buf, err = mask_obs.generateMaskedImageOfInstances_fromRequestHandler_croppedToInstancesExtent_error_(
    instances, handler, False, None  # False = full frame, not cropped
)
```

---

## 3. `CVPixelBufferGetBaseAddress` returns `objc.varlist`

**API:** `Quartz.CVPixelBufferGetBaseAddress(pixel_buffer)`

**Expected:** Returns a raw void pointer suitable for `ctypes.string_at()`.

**Actual:** Returns an `objc.varlist` object that cannot be interpreted as `ctypes.c_void_p`.

**Workaround:** Never extract bytes directly from CVPixelBuffer. Instead, convert through CIContext to CGImage, then render into a CGBitmapContext whose `GetData()` returns a usable buffer:

```python
ci_image = Quartz.CIImage.imageWithCVPixelBuffer_(pixel_buffer)
ctx = Quartz.CIContext.contextWithOptions_(None)
extent = ci_image.extent()
cg_image = ctx.createCGImage_fromRect_(ci_image, extent)

w = Quartz.CGImageGetWidth(cg_image)
h = Quartz.CGImageGetHeight(cg_image)
bitmap_ctx = Quartz.CGBitmapContextCreate(
    None, w, h, 8, w * 4,
    Quartz.CGColorSpaceCreateDeviceRGB(),
    Quartz.kCGImageAlphaPremultipliedLast,  # RGBA
)
Quartz.CGContextDrawImage(bitmap_ctx, ((0, 0), (w, h)), cg_image)
data_ptr = Quartz.CGBitmapContextGetData(bitmap_ctx)
raw_bytes = data_ptr.as_buffer(w * h * 4)
arr = np.frombuffer(raw_bytes, dtype=np.uint8).reshape(h, w, 4)
```

---

## 4. Autorelease pool required for per-image loops

**Symptom:** Processing 483 images with foreground mask extraction causes RSS to grow unboundedly (17GB+), freezing the Mac.

**Cause:** Each iteration creates large transient objc objects (CVPixelBuffer ~12.5MB, CIImage, CGImage, CGBitmapContext) that accumulate in the implicit autorelease pool until the script exits. Phase 1 (aesthetic + classify + featureprint only) didn't trigger this because those observations are small objects.

**Fix:** Wrap each iteration in `objc.autorelease_pool()` and call `gc.collect()` periodically:

```python
import objc, gc

for idx, path in enumerate(image_paths):
    with objc.autorelease_pool():
        result = analyze_image(path, subject_aware=True)
        results.append(result)
    if (idx + 1) % 5 == 0:
        gc.collect()
```

**Critical:** The result dict must contain only Python-native types (str, float, int, list, dict). If any objc-backed object (CVPixelBuffer, CIImage, numpy array referencing objc memory) leaks into the result, the pool cannot reclaim it.

**Measured impact:** Without pool: 17GB+ OOM crash. With pool: 3.0GB peak RSS for 483 images, plateauing at image ~345.

---

## General Notes

- **CoreImage access:** `import Quartz`, not `import CoreImage`. There is no standalone CoreImage module in pyobjc.
- **CIKMeans `inputExtent`:** Defaults to `[0 0 0 0]` which produces `None` output. Must set via `CIVector.vectorWithX_Y_W_H_()` with the actual image extent.
- **Method name underscores:** pyobjc method names don't always follow the obvious Objective-C selector translation. Use `dir(obj)` or `type(obj).instanceMethodSignatureForSelector_()` to introspect.
- **`ru_maxrss` on macOS:** Reports bytes (not KB). Represents peak RSS (monotonically increasing watermark), not current RSS.
