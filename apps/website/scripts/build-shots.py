# Build the website shots from the raw captures: crop, scale, encode as WebP, write a size manifest.
import json, os, sys, shutil
from PIL import Image
src, out, manifest = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
full = None
jobs = [
  # id, source, crop box in source pixels (None = whole), max width
  ("hero-start", "hero-start.png", None, 2400), ("hero-build", "hero-build.png", None, 2400),
  ("hero-review", "hero-review.png", None, 2400), ("hero-team", "hero-team.png", None, 2400),
  ("hero-pr", "hero-pr.png", None, 2400),
  ("agents-view", "full-agents.png", (0, 1050, 1120, 1750), 1120),
  ("new-agent", "hero-start.png", (800, 500, 2080, 1300), 1280),
  ("skills", "full-skills.png", (840, 380, 2120, 1180), 1280),
  ("queue", "full-queue-list.png", (1020, 100, 2300, 900), 1280),
  ("sessions", "full-sessions.png", (1180, 110, 2620, 1010), 1280),
  ("handoff", "full-handoff.png", (800, 190, 2080, 990), 1280),
  ("profile", "set-profile.png", None, 1280),
  ("notifications", "full-filter-unread.png", (0, 60, 1280, 860), 1280),
  ("persistence", "full-quit.png", (324, 190, 1604, 990), 1280),
  ("sidebar", "full-sidebar.png", (0, 100, 1100, 1700), 1100),
  ("layout", "full-layout.png", None, 2400),
  ("pr-popover", "hero-pr.png", (1420, 50, 2370, 644), 1280),
  ("mr-popover", "full-mr.png", (1420, 50, 2370, 644), 1280),
  ("diff", "win-diff.png", None, 2200),
  ("filter-workspace", "full-filter-workspace.png", (0, 100, 700, 700), 700),
  ("filter-remote", "full-filter-remote.png", (0, 100, 700, 700), 700),
  ("filter-pr", "full-filter-pr.png", (0, 100, 700, 700), 700),
  ("theme-mocha", "theme-mocha.png", None, 1600), ("theme-gruvbox", "theme-gruvbox.png", None, 1600),
  ("theme-tokyonight", "theme-tokyonight.png", None, 1600), ("theme-rosepine", "theme-rosepine.png", None, 1600),
  ("theme-latte", "theme-latte.png", None, 1600),
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
for v, poster in (("panes-team.mp4", "panes-team-poster.png"),):
    shutil.copy(os.path.join(src, v), os.path.join(out, v))
    im = Image.open(os.path.join(src, poster)).convert("RGB")
    im.save(os.path.join(out, "panes-team.webp"), "WEBP", quality=80, method=6)
    sizes["panes-team"] = {"width": im.width, "height": im.height, "video": True}
og = Image.open(os.path.join(src, "hero-build.png")).convert("RGB").resize((1200, 750), Image.LANCZOS)
og.save(os.path.join(out, "og.png"), optimize=True)
json.dump(sizes, open(manifest, "w"), indent=2, sort_keys=True)
print(len(sizes), "shots")
