#!/usr/bin/env python3
"""Re-apply the element-web notification fixes after a bundle restage.

The shipped element-web bundle is patched in two places so that real incoming
messages produce an OS notification on this client (see doc/DESIGN.md §7b):

1. In `bundles/*/8406.js`, `displayPopupNotification` early-returns when the
   per-device `is_silenced` account-data flag is set (`if((0,D.J7)(s))return;`),
   which element-web turns on after the first sync while notifications are off.
   This patch removes only that popup guard. The audio guard
   (`if(!s||(0,D.J7)(s))return;`) in the sound function is left untouched so
   silenced rooms still stay silent.

2. `index.html` loads `prelude.js` with a cache-busting query string
   (`prelude.js?v=N`); the version is bumped so ArkWeb (running with
   `CacheMode.None`) definitely fetches the freshly extracted prelude.

Idempotent: already-patched bundles are detected and skipped, and the cache-bust
version keeps increasing. Run it after every `cp -R` restage of the element-web
build.

Usage:
    python3 scripts/patch-notifier.py [--dry-run] [element-dir]
`element-dir` defaults to products/default/src/main/resources/rawfile/element
"""

import argparse
import os
import re
import sys
from pathlib import Path

def rel(p: Path) -> Path:
    return Path(os.path.relpath(p))

POPUP_GUARD = "if((0,D.J7)(s))return;"
AUDIO_GUARD = "if(!s||(0,D.J7)(s))return;"


def patch_8406(bundle_file: Path, dry_run: bool) -> bool:
    """Remove the is_silenced popup guard from 8406.js. Returns True if changed."""
    if not bundle_file.exists():
        print(f"ERROR: {bundle_file} not found", file=sys.stderr)
        sys.exit(1)
    text = bundle_file.read_bytes().decode("utf-8")
    count = text.count(POPUP_GUARD)
    if count == 0:
        if AUDIO_GUARD in text:
            print(f"  {rel(bundle_file)}: popup guard already removed (audio guard kept)")
        else:
            print(
                f"WARNING: {rel(bundle_file)}: neither the popup guard "
                f"nor the audio guard was found - the bundle layout may have changed; "
                f"check the pattern in this script",
                file=sys.stderr,
            )
            sys.exit(1)
        return False
    if count > 1:
        print(
            f"ERROR: {rel(bundle_file)}: popup guard matched {count} times, "
            f"expected exactly 1 - refusing to patch",
            file=sys.stderr,
        )
        sys.exit(1)
    if dry_run:
        print(f"  WOULD patch {rel(bundle_file)}: remove popup is_silenced guard")
        return True
    new = text.replace(POPUP_GUARD, "", 1)
    bundle_file.write_bytes(new.encode("utf-8"))
    print(f"  patched {rel(bundle_file)}: removed popup is_silenced guard")
    return True


def bump_prelude_buster(index_file: Path, dry_run: bool) -> bool:
    """Bump the prelude.js?v=N cache-buster in index.html. Returns True if changed."""
    if not index_file.exists():
        print(f"ERROR: {index_file} not found", file=sys.stderr)
        sys.exit(1)
    text = index_file.read_text(encoding="utf-8")
    m = re.search(r'prelude\.js\?v=(\d+)', text)
    if m is None:
        print(
            f"WARNING: {rel(index_file)}: no 'prelude.js?v=N' reference found",
            file=sys.stderr,
        )
        sys.exit(1)
    version = int(m.group(1))
    if dry_run:
        print(f"  WOULD bump {rel(index_file)}: prelude.js?v={version} -> ?v={version + 1}")
        return True
    new = text.replace(f"prelude.js?v={version}", f"prelude.js?v={version + 1}", 1)
    index_file.write_text(new, encoding="utf-8")
    print(f"  bumped {rel(index_file)}: prelude.js?v={version} -> ?v={version + 1}")
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true", help="report changes without applying them")
    parser.add_argument(
        "element_dir",
        nargs="?",
        default="products/default/src/main/resources/rawfile/element",
        help="element-web staging directory (default: the project rawfile/element)",
    )
    args = parser.parse_args()

    root = Path(args.element_dir)
    bundles = sorted(root.glob("bundles/*/8406.js"))
    if not bundles:
        print(f"ERROR: no bundles/*/8406.js under {root}", file=sys.stderr)
        sys.exit(1)
    if len(bundles) > 1:
        print(f"ERROR: multiple 8406.js bundles found: {[p.name for p in bundles]}", file=sys.stderr)
        sys.exit(1)

    banner = "DRY-RUN — changes not applied:" if args.dry_run else "Patching:"
    print(banner)
    changed = patch_8406(bundles[0], args.dry_run)
    changed = bump_prelude_buster(root / "index.html", args.dry_run) or changed

    if args.dry_run:
        sys.exit(0)
    if changed:
        print("OK - notifier patch applied. Rebuild with compile_and_run.sh to redeploy.")
    else:
        print("OK - nothing to do.")


if __name__ == "__main__":
    main()