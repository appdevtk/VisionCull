# VisionCull

VisionCull is a native macOS app and Swift CLI for reviewing and tagging photos locally. Apple Vision proposes motifs, a category, and a short caption assembled from its recognized labels. You can edit those suggestions, approve a batch, and export XMP sidecars while keeping the original image files intact.

## Build and run

Requires macOS 15+ and Xcode 16+ on a Mac. GitHub Actions builds and tests both products in the [macOS workflow](.github/workflows/macos.yml). The workflow uploads the app and CLI as ZIP artifacts. For a local development build:

```sh
swift test
Scripts/build-macos.sh
open dist/VisionCull.app
dist/visioncull --help
```

The build is ad-hoc signed for development. Distribution to other Macs may require Developer ID signing and notarization.

## Review photos

1. Choose **Open → Folder** and select a directory. VisionCull scans supported images recursively. **Find Similar Photos** is an optional scan setting that adds Vision feature prints and a similar-photo strip to the review.
2. Review the images in the sidebar. Edit motifs, category, caption, capture date, and GPS and use **Save Edits**. Existing EXIF, IPTC, XMP, and Apple Photos metadata can populate these fields. Capture dates without a timezone remain unzoned. Missing date and GPS are left blank.
3. Mark the photos you reviewed and choose **Approve Marked**. Saving another edit clears an earlier approval.
4. Choose **Export → XMP**. Export to a separate folder to keep the source folder untouched. Subfolders are preserved. **Save Review** keeps edits and approvals in a JSON file you can reopen.

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
- VisionCull adds confirmed motifs and category as Immich tags and leaves other tags intact. It omits blank metadata. To send an edited capture time to Immich, include an explicit timezone offset. The server URL must use HTTPS, with HTTP accepted on loopback for local testing.

### CLI example

```sh
dist/visioncull scan ~/Pictures/Test --duplicates --review review.json
dist/visioncull preview review.json
dist/visioncull edit review.json 'day-1/IMG_001.jpg' \
  --subjects 'garden,flowers' --category Nature --description 'Flowers beside a path'
dist/visioncull approve review.json 'day-1/IMG_001.jpg'
dist/visioncull export review.json --output ./xmp-export
```

Use `Scripts/smoke-cli.sh "$PWD/dist/visioncull"` to run a disposable local folder through scan, cache reuse, preview, approval, and XMP export. On Linux, the smoke script uses `--metadata-only`. Apple Vision, the native UI, PhotoKit, and Immich checksumming use the macOS build.

The [original Python pipeline](docs/legacy-python.md) remains available for its HTML contact sheet, palette analysis, and CLI compatibility. [Project background and original benchmark](docs/case-study.md).
