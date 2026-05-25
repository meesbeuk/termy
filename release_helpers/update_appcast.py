#!/usr/bin/env python3
"""Inject a new <item> entry into appcast.xml as the latest release.

Sparkle clients pick the first <item> they find — so prepending in front
of the existing first <item> is enough to make this the served update.

Called by release.sh as:
    python3 release_helpers/update_appcast.py VERSION BUILD LENGTH SIG

VERSION  short version string (e.g. "0.10.1")
BUILD    integer build number (e.g. "52")
LENGTH   DMG byte count from `stat -f%z`
SIG      sparkle:edSignature value parsed out of sign_update's output

Release notes are read from RELEASE_NOTES.md in the repo root if it
exists, otherwise we fall back to the README's "Project status" line for
this version. Keeps the script idempotent — running it twice will produce
duplicate <item>s, which Sparkle tolerates but isn't clean; the script
detects that and refuses to double-insert.
"""
from __future__ import annotations

import re
import sys
from datetime import datetime, timezone
from pathlib import Path

APPCAST_PATH = Path(__file__).resolve().parent.parent / "appcast.xml"
README_PATH = Path(__file__).resolve().parent.parent / "README.md"
NOTES_PATH = Path(__file__).resolve().parent.parent / "RELEASE_NOTES.md"


def load_notes(version: str) -> str:
    """Pick the best available release notes for VERSION.

    Priority:
      1. RELEASE_NOTES.md if present (HTML or markdown — passed through).
      2. The README "Project status" bullet for vVERSION, lightly
         massaged into <h2>/<ul> HTML.
      3. Generic fallback.
    """
    if NOTES_PATH.exists():
        return NOTES_PATH.read_text(encoding="utf-8").strip()
    if README_PATH.exists():
        text = README_PATH.read_text(encoding="utf-8")
        pattern = rf"\*\*v{re.escape(version)}\*\*\s*[—-]\s*(.+)"
        m = re.search(pattern, text)
        if m:
            body = m.group(1).strip()
            return f"<p>{body}</p>"
    return f"<p>Version {version} — see GitHub release notes.</p>"


def build_item(version: str, build: str, length: str, sig: str, notes_html: str) -> str:
    pub_date = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    return (
        "        <item>\n"
        f"            <title>Version {version}</title>\n"
        "            <description><![CDATA[\n"
        f"                {notes_html}\n"
        "            ]]></description>\n"
        f"            <pubDate>{pub_date}</pubDate>\n"
        f"            <sparkle:version>{build}</sparkle:version>\n"
        f"            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>\n"
        "            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>\n"
        "            <enclosure\n"
        f'                url="https://github.com/meesbeuk/termy/releases/download/v{version}/Termy.dmg"\n'
        f'                sparkle:version="{build}"\n'
        f'                sparkle:shortVersionString="{version}"\n'
        f'                length="{length}"\n'
        f'                sparkle:edSignature="{sig}"\n'
        '                type="application/octet-stream"/>\n'
        "        </item>\n"
        "\n"
    )


def main() -> int:
    if len(sys.argv) != 5:
        print("Usage: update_appcast.py VERSION BUILD LENGTH SIG", file=sys.stderr)
        return 2

    version, build, length, sig = sys.argv[1:5]
    content = APPCAST_PATH.read_text(encoding="utf-8")

    # Idempotency: if an item with this short-version already exists, skip
    # rather than duplicating. The user re-running release.sh after a
    # failed upload shouldn't pollute the feed.
    duplicate_marker = f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
    if duplicate_marker in content:
        print(f"appcast.xml already contains an entry for v{version} — skipping insert.")
        return 0

    notes_html = load_notes(version)
    new_item = build_item(version, build, length, sig, notes_html)

    # Insert before the first <item> we find — Sparkle reads top-to-bottom.
    first_item = "        <item>"
    if first_item not in content:
        print("ERROR: couldn't locate '        <item>' anchor in appcast.xml. Is the file structured as expected?", file=sys.stderr)
        return 1

    content = content.replace(first_item, new_item + first_item, 1)
    APPCAST_PATH.write_text(content, encoding="utf-8")
    print(f"appcast.xml: prepended v{version} (build {build}, {length} bytes).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
