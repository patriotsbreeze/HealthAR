#!/usr/bin/env python3
"""Draws the app icon: the medical alert mark (red core, white plus, split ring).

Writes three 1024 px PNGs into App/Assets.xcassets/AppIcon.appiconset: light (default), dark and
tinted. iOS requires opaque icons, so each one has a solid background. Renders with headless
Google Chrome, which macOS dev machines here already have.
"""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT_DIR = ROOT / "App" / "Assets.xcassets" / "AppIcon.appiconset"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SIZE = 1024
MARK = 700  # same mark-to-tile ratio as the design sheet (130 of 190)

RED = "#E5483A"
WHITE = "#ffffff"

# name: (background, ring and core, plus)
VARIANTS = {
    "icon-1024.png": ("#f4f3ef", RED, WHITE),
    "icon-1024-dark.png": ("#1f2026", RED, WHITE),
    "icon-1024-tinted.png": ("#000000", WHITE, "#000000"),
}


def svg(background, mark, plus):
    offset = (SIZE - MARK) // 2
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">
  <rect width="{SIZE}" height="{SIZE}" fill="{background}"/>
  <svg x="{offset}" y="{offset}" width="{MARK}" height="{MARK}" viewBox="0 0 128 128">
    <circle cx="64" cy="64" r="58" fill="none" stroke="{mark}" stroke-width="6" stroke-linecap="round"
            stroke-dasharray="160 22.4 160 22.4" transform="rotate(-100 64 64)"/>
    <circle cx="64" cy="64" r="44" fill="{mark}"/>
    <path d="M64 40v48M40 64h48" stroke="{plus}" stroke-width="16" stroke-linecap="round"/>
  </svg>
</svg>"""


def render(name, background, mark, plus, workdir):
    page = workdir / f"{name}.html"
    page.write_text(
        "<!doctype html><html><head><style>"
        f"html,body{{margin:0;padding:0;background:{background}}}svg{{display:block}}"
        f"</style></head><body>{svg(background, mark, plus)}</body></html>"
    )
    out = OUTPUT_DIR / name
    subprocess.run(
        [
            CHROME,
            "--headless=new",
            "--disable-gpu",
            "--hide-scrollbars",
            "--force-device-scale-factor=1",
            f"--window-size={SIZE},{SIZE}",
            f"--screenshot={out}",
            page.as_uri(),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    print(f"wrote {out.relative_to(ROOT)}")


def main():
    with tempfile.TemporaryDirectory() as tmp:
        for name, colors in VARIANTS.items():
            render(name, *colors, pathlib.Path(tmp))


if __name__ == "__main__":
    main()
