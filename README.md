# VisionCull

VisionCull is a native macOS app and Swift CLI for reviewing and tagging photos locally. Apple Vision proposes motifs, a category, and a short caption assembled from its recognized labels. You can edit those suggestions and searchable topics, moods, and styles, approve a batch, and export XMP sidecars while keeping the original image files intact.

## Build and run

Requires macOS 15+ and Xcode 16+ on a Mac. GitHub Actions builds and tests both products in the [macOS workflow](.github/workflows/macos.yml). The workflow uploads the app and CLI as ZIP artifacts for Apple Silicon and Intel. Apple Silicon runs the Vision and reference-image tests. Intel checks the native build, ImageIO metadata, and the metadata-only CLI workflow. For a local development build:

```sh
swift test
Scripts/build-macos.sh
open dist/VisionCull.app
dist/visioncull --help
```

The build is ad-hoc signed for development. Distribution to other Macs may require Developer ID signing and notarization.

## Review photos

1. Choose **Open → Folder** and select a directory. VisionCull scans supported images recursively. **Find Similar Photos** is an optional scan setting that adds Vision feature prints and a similar-photo strip to the review.
2. Review the images in the sidebar. Edit motifs, category, topics, moods, styles, star rating, caption, capture date, and GPS and use **Save Edits**. Existing EXIF, IPTC, XMP, and Apple Photos metadata can populate these fields. Capture dates without a timezone remain unzoned. Missing date and GPS are left blank.
3. Mark the photos you reviewed and choose **Approve Marked**. Saving another edit clears an earlier approval.
4. Choose **Export → XMP**. Export to a separate folder to keep the source folder untouched. Subfolders are preserved. **Save Review** keeps edits and approvals in a JSON file you can reopen.

The **Aesthetics** panel shows the Apple Vision score (−1 to +1), the utility-image flag when present, and color and tone estimates from a downsized sRGB preview. It includes brightness, contrast, saturation, deep shadows, near-white highlights, and a small palette. Topics group recognized subjects and scenes. Mood suggestions are based on visual cues such as low contrast or vivid color, and can be edited like any other tag. Your star rating is a separate, manual choice.

Search the sidebar by topic, mood, style, or other photo text. Multiple words can match different fields. German and English aliases work in the search, so `ruhig` also finds `Calm`. Older review JSON files still open.

### Learn and reuse tags

VisionCull keeps a local tag vocabulary. When you approve a review, it reuses recognized spellings, aliases, and clear typos. For example, a collection that already uses `Abendlicht` will keep that spelling when you enter `Golden Hour`. Unclear matches list the existing choices before approval. A term without a match can join the vocabulary when you approve it.

A new scan uses past approvals to suggest personal tags. VisionCull needs at least two different, similar photos with consistent tags before it changes a mood or style suggestion. It can also suggest your known topics and motifs for similar photos. Source metadata takes precedence. You review each suggestion and choose your own stars. This learns from approvals made with this version, including older reviews you reopen and approve again.

The vocabulary lives under `~/Library/Application Support/VisionCull` alongside the analysis cache. If you supply `--cache DIR` for a scan, use the same option for the CLI approval. Reused analysis gets fresh tag suggestions from the current vocabulary.

Existing, different XMP files are preserved. If they already exist or two inputs share a sidecar name, resolve the conflict or choose a fresh export location. The app rejects a reviewed file that changed before export. Review JSON files contain local file paths and may contain GPS.

The analysis cache is stored under `~/Library/Application Support/VisionCull`. A second scan of the same images reuses analysis for the same file revision and model settings. Metadata and sidecars are read again, even on a cache hit.

### Apple Photos and iCloud

Use **Open → Apple Photos** to read a page of recent photos available to the app in the system photo library. PhotoKit calls the required permission “read/write.” VisionCull uses it to fetch assets and copy original still-image resources to its own cache. XMP for these photos always goes to a separate export folder.

Enable **Download iCloud-only originals** to let PhotoKit fetch originals that are stored in iCloud. This can use network data and local disk space. With downloads disabled, unavailable originals appear in scan issues. Apple Photos originals copied into the local cache remain available to saved reviews until that cache is removed. Live Photo video companions and alternate RAW resources are outside this workflow.

Use the packaged app or CLI so macOS can display the Photos permission prompt. The packaged CLI supports `photos --limit N --offset N` and the optional `--icloud` flag.

### Immich

Choose an approved photo and explicitly select **Update Existing** or **Upload New**. Enter the server URL and an API key with the permissions needed for the action. The app keeps the key in memory for the current action. The CLI gets it from `IMMICH_API_KEY`.

- **Update existing:** Supply the exact Immich asset UUID. VisionCull verifies its checksum against the local original before updating metadata. If the checksum differs, verify the original in Immich before trying again.
- **Upload new:** Supply a target album UUID. VisionCull checks for an existing checksum before sending the image. A duplicate result asks you to verify the returned asset ID and then explicitly choose Update. If an upload succeeds and a later step fails, the error includes the new asset ID so you can finish with Update and the album UUID.
- VisionCull reads the server’s tag catalog before sending tags. The API key needs permission to read tags as well as to create and attach them as needed. It reuses matching tags and their IDs, including recognized German and English names. For several uncertain matches, edit the tag in the review and approve again before retrying. VisionCull adds confirmed motifs and category as Immich tags. Topics, moods, and styles use searchable paths such as `VisionCull/Topics/Travel`, `VisionCull/Moods/Calm`, and `VisionCull/Styles/Warm tones`. The same paths are exported as XMP keywords. A confirmed star rating becomes the Immich rating and `xmp:Rating`. Existing Immich tags are preserved, and empty fields are skipped. To send an edited capture time to Immich, include an explicit timezone offset. The server URL must use HTTPS, with HTTP accepted on loopback for local testing.

### Saved searches, comparison, and content

- **Tools → Saved Searches** combines text, topics, moods, styles, and minimum stars. Apply a filter, mark its results, and use **Edit Marked Photos** to add tags or set stars for the batch. Edits go back to Pending before they can be sent.
- **Tools → Tag Synonyms** stores your preferred spelling. The duplicate check lists close pairs in the open review or the Immich tag catalog. Choose **Use as Alias**, adjust the two names if needed, and save the rule. Applying aliases at approval normalizes the review. Immich looks for an existing tag ID when syncing.
- **Compare Photos** in the inspector opens similar photos side by side. You can also pick two photos manually. Zoom and drag are linked. The detail score is an estimate from a downsized preview, so it is most useful for comparing the same scene. Choose a favorite to store it in the review. A fresh scan adds detail values to older photos.
- **Tools → Find by Content** ranks the open review by a description or a reference photo. Text searches use Vision's recognized concepts and local language embeddings when available. Reference search uses Vision feature prints. Mark interesting results to tag them together. A first reference search caches any missing feature prints locally.

### Immich batches

Mark the approved photos and choose **Tools → Preview Marked in Immich**. The preview searches by exact checksum and verifies the returned asset. For several matches, enter the verified asset UUID for that row. For a new upload, choose **Upload new** on that row and enter the album UUID. The preview lists fields and reused or new tags for each proposed action. Send only the selected, ready rows. Changed target metadata or tag mappings require a fresh preview.

Use `visioncull immich batch REVIEW.json --preset NAME --server URL` for a CLI preview. Add `--apply` to send after the checks pass. A map file supplied via `--map FILE.json` uses the exact relative path as the key and one explicit action per value:

```json
{
  "day-1/IMG_001.jpg": { "assetID": "f7d2d3d4-2832-4ad3-8606-dfb56f1518b5" },
  "day-1/IMG_002.jpg": { "uploadAlbumID": "b627b862-c762-4387-a979-9bd5baad59eb" }
}
```

### CLI example

```sh
dist/visioncull scan ~/Pictures/Test --duplicates --review review.json
dist/visioncull preview review.json
dist/visioncull edit review.json 'day-1/IMG_001.jpg' \
  --subjects 'garden,flowers' --category Nature --description 'Flowers beside a path' \
  --topics 'Flowers & gardens' --moods 'Calm' --styles 'Soft contrast' --rating 4
dist/visioncull preview review.json --search 'garden calm'
dist/visioncull search save 'Calm garden' --topics 'Flowers & gardens' --moods Calm --stars 4
dist/visioncull search run 'Calm garden' review.json
dist/visioncull find review.json --text 'ruhiger Garten'
dist/visioncull approve review.json 'day-1/IMG_001.jpg'
dist/visioncull export review.json --output ./xmp-export
```

Use `Scripts/smoke-cli.sh "$PWD/dist/visioncull"` to run a disposable local folder through scan, cache reuse, preview, approval, and XMP export. On Linux, the smoke script uses `--metadata-only`. Apple Vision, the native UI, PhotoKit, and Immich checksumming use the macOS build.

The [original Python pipeline](docs/legacy-python.md) remains available for its HTML contact sheet, palette analysis, and CLI compatibility. [Project background and original benchmark](docs/case-study.md).
