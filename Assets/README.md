# Float Tasks logo

`FloatTasks.png` is the original generated logo: a jade rounded tile, two vertical frosted task cards, and a white checkmark. It has a transparent background and is independent of Google's branding.

The image was generated with OpenAI's built-in `image_gen` tool, with `transparent_background: true`. The tool returned a **1254 × 1254 RGBA PNG** from the 1024 × 1024 request below. The original PNG and alpha channel are preserved in this directory.

During packaging, `build.sh` uses Apple's `sips` to derive the standard 16, 32, 128, 256, and 512-point icon sizes at 1× and 2×, then `iconutil` to create the app's `FloatTasks.icns`. The generated iconset and ICNS are build artifacts; they are not checked in. Packaging uses no image service or third-party image library.

## Generation prompt

```text
Use case: logo-brand
Asset type: one macOS app icon/logo for Float Tasks, square 1024 × 1024 PNG with genuine transparent background.
Primary request: A centered rounded-square soft emerald/jade tile containing a simple white checkmark on a narrow frosted vertical task-card shape, with one subtly offset card behind it suggesting floating stacked lists.
Style/medium: Minimal polished macOS app icon, crisp vector-friendly silhouette, restrained depth and a soft highlight, subtle frosted-glass cards. Clean readable forms at small icon sizes.
Composition/framing: One icon only, centered, generous transparent outer margin on all four sides, front-facing with slight depth. Keep the stacked card symbol narrow and vertical within the tile.
Color palette: Soft emerald and jade tile, pale frosted card surfaces, a clear white checkmark with enough contrast to remain readable.
Constraints: Actual alpha transparency outside the tile; preserve clean antialiased edges. No text, letters, numerals, Google G, Google brand marks, other branding, watermark, device, screen mockup, surrounding UI, grid, decorative objects, or duplicate icon variants.
```
