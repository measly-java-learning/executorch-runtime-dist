#!/usr/bin/env python3
"""Assert the build container is pinned in .build-image and that no workflow hardcodes an image.

Usage: check_build_image_pin.py <repo root>

Two failures this prevents:

1. An UNPINNED image. A floating tag lets the toolchain (gcc-toolset, glibc, CPython) be rebuilt
   underneath a green tree - a base rebuild broke a sibling repo on unchanged source exactly that
   way. This repo pins ExecuTorch by tag+commit and the OpenVINO wheel by SHA-256, and publishes
   consumer pins with SHA-256; building all of it in a floating container undercuts the lot.

2. A SECOND spelling of the image. The point of the file is that the digest appears once. A
   workflow that hardcodes an image silently stops tracking the pin, and two jobs on different
   images is a difference nobody would think to look for.
"""
import pathlib
import re
import sys

import yaml

PIN_FILE = ".build-image"
DIGEST_RE = re.compile(r"^\S+@sha256:[0-9a-f]{64}$")
# Any registry-looking literal in a container image field. The pin must arrive by expression.
LITERAL_IMAGE_RE = re.compile(r"^[a-z0-9.-]+\.[a-z]{2,}/")


def check_pin_file(root: pathlib.Path):
    """Returns (ok, messages). The file is one bare line - no comments, no parsing."""
    path = root / PIN_FILE
    if not path.exists():
        return False, [f"{PIN_FILE} does not exist"]

    raw = path.read_text()
    lines = raw.splitlines()
    msgs = []
    ok = True

    if len(lines) != 1:
        msgs.append(f"{PIN_FILE} must hold exactly one line, found {len(lines)}")
        ok = False
    if not raw.endswith("\n"):
        msgs.append(f"{PIN_FILE} must end with a newline")
        ok = False
    if lines and not DIGEST_RE.match(lines[0].strip()):
        msgs.append(f"{PIN_FILE} must pin a digest, not a tag: {lines[0]!r}")
        ok = False
    return ok, msgs


def container_images(path: pathlib.Path):
    doc = yaml.safe_load(open(path)) or {}
    for job_name, job in (doc.get("jobs") or {}).items():
        container = job.get("container")
        image = container if isinstance(container, str) else (container or {}).get("image")
        if image:
            yield f"{path.name}:{job_name}", str(image)


def main(root_arg: str) -> int:
    root = pathlib.Path(root_arg)
    fails = 0

    ok, msgs = check_pin_file(root)
    for m in msgs:
        print(f"FAIL: {m}", file=sys.stderr)
    if ok:
        print(f"ok: {PIN_FILE} holds one digest-pinned line")
    else:
        fails += 1

    for wf in sorted((root / ".github" / "workflows").glob("*.yml")):
        for where, image in container_images(wf):
            if LITERAL_IMAGE_RE.match(image):
                print(f"FAIL: {where} hardcodes an image; use the {PIN_FILE} output: {image}",
                      file=sys.stderr)
                fails += 1
            else:
                print(f"ok: {where} takes its image from an expression")

    return 1 if fails else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
