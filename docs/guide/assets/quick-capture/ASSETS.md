# Quick Capture guide assets (GUIDE-CAPTURE-PLACEMENT-R1)

Illustrate the lower-right Quick Capture control (a blue round button with a white
plus, Simple Machines family design) and the compact status accessory, as shipped
in CAPTURE-PLACEMENT-R1 (code tip `bdaa7b0bc`).

## Placed
| Asset | Shows |
|---|---|
| `quick-capture-iphone-visible.png` | iPhone (compact): four Everyday tabs, the attachment-status pill above the tab bar, and the **blue plus Quick Capture button in the lower-right** — clearing the tab bar and the status pill. |
| `quick-capture-iphone-hidden.png` | iPhone (compact): Quick Capture turned off in Settings — the button is **gone**, while the tabs, status pill, and all navigation remain. |

## Outstanding
- **Regular shell (iPad full-width / Mac), Quick Capture visible** — the blue plus
  button in the lower-right of the detail pane, sidebar navigation, status band at
  the bottom. NOT yet placed as a guide-quality asset because:
  - the iPad simulator fires a pre-existing "Open in Fulcrum?" system dialog over
    the center on launch (unrelated to this feature — the mission forbids reusing
    that evidence shot, `cap-04`, as-is); and
  - macOS `screencapture` is unavailable in the headless build session
    ("could not create image from display").
  A clean regular-shell asset should be captured on a Mac/iPad with a display, or
  after the deep-link launch dialog is suppressed. The regular shell is the same
  `hSizeClass == .regular` code path (macOS compile-verified).

## Source evidence
The full CAPTURE-PLACEMENT-R1 verification set (including the AX5 shot and the
iPad regular shot with its system dialog) is held with the engineering records
rather than in this repository's published tree. Those are evidence captures,
not polished guide assets — do not publish them as-is.
