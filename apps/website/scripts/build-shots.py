# Build the website shots from the raw captures: crop, scale, encode as WebP, write a size manifest.
import json, os, sys
from PIL import Image
src, out, manifest = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
full = None
SCENE = (256, 4, 3584, 2092)
jobs = [
  # id, source, crop box in source pixels (None = whole), max width
  # A tour scene is 1664 x 1044 points around the 1440 x 900 window; global.css uses this size.
  # The tour scenes: the window with its shadow in front of a backdrop, captured as a screen region.
  ("hero-palette", "stage-palette.png", SCENE, 3200), ("hero-start", "stage-start.png", SCENE, 3200),
  ("hero-build", "stage-build.png", SCENE, 3200), ("hero-review", "stage-review.png", SCENE, 3200),
  ("hero-team", "stage-team.png", SCENE, 3200), ("hero-pr", "stage-pr.png", SCENE, 3200),
  ("agents-view-1", "agents-view-1.png", None, 740), ("agents-view-2", "agents-view-2.png", None, 740),
  ("agents-view-3", "agents-view-3.png", None, 740),
  ("new-agent", "hero-start.png", (800, 500, 2080, 1300), 1280),
  # Card frames are crops of region captures (2 px for each point; the window starts at 480, 148).
  ("queue-1", "card-q1b.png", (1224, 768, 2744, 1718), 1280), ("queue-2", "card-q3.png", (1600, 224, 2720, 924), 1120),
  ("sessions-1", "card-s1.png", (1520, 208, 3120, 1208), 1280), ("sessions-2", "card-s2.png", (1520, 208, 3120, 1208), 1280),
  ("sessions-3", "card-s3.png", (1520, 208, 3120, 1208), 1280),
  ("cli-1", "card-c1.png", (1124, 332, 2164, 982), 1040), ("cli-2", "card-c2.png", (1872, 600, 2604, 1058), 732),
  ("handoff", "full-handoff.png", (800, 190, 2080, 990), 1280),
  ("profile", "set-profile.png", None, 1280),
  ("notifications-1", "card-notification-center.png", (0, 30, 738, 491), 738),
  ("notifications-2", "full-filter-unread.png", (0, 60, 1280, 860), 1280),
  ("persistence", "full-quit.png", (324, 190, 1604, 990), 1280),
  ("sidebar", "full-sidebar.png", (0, 100, 1100, 1700), 1100),
  ("filter-workspace", "full-filter-workspace.png", (0, 100, 700, 700), 700),
  ("filter-remote", "full-filter-remote.png", (0, 100, 700, 700), 700),
  ("filter-pr", "full-filter-pr.png", (0, 100, 700, 700), 700),
  # The theme wall: the whole window in each theme, as a small tile.
] + [("theme-" + n, "theme-" + n + ".png", None, 640) for n in (
  "dracula latte tokyonight gruvbox nord rosepine-dawn github-dark monokai github-light kanagawa one-dark "
  "everforest mocha gruvbox-light night-owl solarized rosepine ayu").split()] + [
  ("palette", "full-palette.png", (660, 180, 1940, 980), 1280),
  ("run-menu", "full-run.png", (1248, 40, 2880, 1060), 1280),
  ("shortcuts", "set-shortcuts.png", None, 1280),
  ("open-in", "full-open.png", (1400, 60, 2880, 985), 1280),
]
sizes = {}
for sid, name, box, maxw in jobs:
    im = Image.open(os.path.join(src, name)).convert("RGBA")
    if box: im = im.crop(box)
    if im.width > maxw: im = im.resize((maxw, round(im.height * maxw / im.width)), Image.LANCZOS)
    im.save(os.path.join(out, sid + ".webp"), "WEBP", quality=84, method=6)
    sizes[sid] = {"width": im.width, "height": im.height}
og = Image.open(os.path.join(src, "stage-palette.png")).convert("RGB")
og = og.resize((1200, round(og.height * 1200 / og.width)), Image.LANCZOS).crop((0, 12, 1200, 642))
og.save(os.path.join(out, "og.png"), optimize=True)
json.dump(sizes, open(manifest, "w"), indent=2, sort_keys=True)
print(len(sizes), "shots")
