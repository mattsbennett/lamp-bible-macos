#!/usr/bin/env python3
"""Generate Resources/Third Party Licenses for the Mac app.

The folder is bundled into Lamp Bible.app and opened from Help → Third-Party Notices. It holds
one file per third-party component with that component's complete licence text, and a README
that lists each component with its exact version.

Sources, all checked rather than assumed:

- Swift packages: versions from the Xcode project's Package.resolved, licence texts from the
  matching SwiftPM checkouts in .build/checkouts (run `swift package resolve` first). Every
  resolved package must be listed in PACKAGES or EXCLUDED, so a new dependency can't ship
  without a notice.
- Editor bundle: the TipTap editor is byte-identical to the iOS app's, so its JavaScript
  notices are copied from the iOS repo. If the bundles ever differ, generation stops.
- Bundled content: the CrossWire KJV notice is included only when the bundled module database
  actually contains the KJVs translation.

Usage:
    swift package resolve
    python3 scripts/generate_third_party_notices.py            # fail on any unaccepted licence gap
    python3 scripts/generate_third_party_notices.py --allow-gaps  # development builds only
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sqlite3
import sys
import tempfile
import zlib
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPOS = ROOT.parent
OUTPUT = ROOT / "Resources" / "Third Party Licenses"
XCODE_RESOLVED = ROOT / "Lamp Bible.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
SPM_RESOLVED = ROOT / "Package.resolved"
CHECKOUTS = ROOT / ".build" / "checkouts"

IOS_NOTICES = REPOS / "lamp-bible-ios" / "Resource Files" / "Third Party Licenses"
IOS_EDITOR = REPOS / "lamp-bible-ios" / "Lamp Bible" / "Resources" / "TipTapEditor" / "index.html"
MAC_EDITOR = ROOT / "Sources" / "LampBibleMac" / "Resources" / "TipTapEditor" / "index.html"
BUNDLED_DB = REPOS / "lamp-bible-modules" / "modules_db" / "bundled_modules.db.zlib"


@dataclass(frozen=True)
class Package:
    name: str
    spdx: str
    #: Why it ships: which binary links it.
    shipped_in: str


# Keyed by Package.resolved identity. Verified against the Debug build's compiled modules.
PACKAGES: dict[str, Package] = {
    "eventsource": Package("EventSource", "MIT", "lamp-mcp helper, via MCP Swift SDK"),
    "grdb.swift": Package("GRDB.swift", "MIT", "app and lamp-mcp helper, via LampCore"),
    "kingfisher": Package("Kingfisher", "MIT", "app, via SwiftyChat"),
    "sparkle": Package("Sparkle", "MIT", "app (software updates)"),
    "swift-atomics": Package("Swift Atomics", "Apache-2.0", "lamp-mcp helper, via SwiftNIO"),
    "swift-collections": Package("Swift Collections", "Apache-2.0", "lamp-mcp helper, via SwiftNIO"),
    "swift-log": Package("SwiftLog", "Apache-2.0", "lamp-mcp helper, via MCP Swift SDK"),
    "swift-nio": Package("SwiftNIO", "Apache-2.0", "lamp-mcp helper, via MCP Swift SDK"),
    "swift-sdk": Package("MCP Swift SDK", "Apache-2.0 AND MIT", "lamp-mcp helper"),
    "swift-system": Package("Swift System", "Apache-2.0", "lamp-mcp helper, via MCP Swift SDK"),
    "swiftterm": Package("SwiftTerm", "MIT", "app (agent terminal)"),
    "swiftuiektensions": Package("SwiftUIEKtensions", "NOASSERTION", "app, via SwiftyChat"),
    "swiftychat": Package("SwiftyChat", "Apache-2.0", "app (agent chat)"),
}

# Shipped packages with a known licence gap that the project owner has decided to accept.
# Each entry is a dated, deliberate decision; any gap not listed here still fails the release.
# The reasoning stays here in the repository — the bundled notice only credits the author.
ACCEPTED_GAPS: dict[str, str] = {
    "swiftuiektensions": (
        "2026-09-22: shipped without a published licence by project-owner decision. It is a "
        "dependency of SwiftyChat (Apache-2.0) by the same author, who distributes it through "
        "Swift Package Manager for that purpose. If the author objects or publishes restrictive "
        "terms, fork SwiftyChat and replace the few helpers it uses."
    ),
}

# Resolved but not linked into anything that ships.
EXCLUDED: dict[str, str] = {
    "swift-argument-parser": "build-time only; no shipped target links it",
}

# iOS notice files that describe the TipTap editor bundle's JavaScript dependencies.
EDITOR_NOTICE_FILES = [
    "Tiptap-MIT.txt",
    "ProseMirror-MIT.txt",
    "prosemirror-changeset-MIT.txt",
    "prosemirror-tables-MIT.txt",
    "tiptap-markdown-MIT.txt",
    "Remirror-MIT.txt",
    "TypeScript-Definitions-MIT.txt",
    "markdown-it-MIT.txt",
    "markdown-it-task-lists-ISC.txt",
    "linkify-it-MIT.txt",
    "linkifyjs-MIT.txt",
    "mdurl-MIT.txt",
    "punycode-uc.micro-MIT.txt",
    "entities-BSD-2-Clause.txt",
    "argparse-Python.txt",
    "escape-string-regexp-MIT.txt",
    "crelt-MIT.txt",
    "orderedmap-MIT.txt",
    "rope-sequence-MIT.txt",
]

CROSSWIRE_NOTICE = "CrossWire-KJV-v3.1-NOTICE.txt"

LICENCE_NAMES = ("LICENSE", "LICENSE.txt", "LICENSE.md", "LICENCE", "COPYING")
NOTICE_NAMES = ("NOTICE", "NOTICE.txt", "NOTICE.md")


class NoticeError(RuntimeError):
    pass


def resolved_pins(path: Path) -> dict[str, dict]:
    data = json.loads(path.read_text())
    return {pin["identity"]: pin for pin in data["pins"]}


def checkout_dir(pin: dict) -> Path:
    name = pin["location"].rstrip("/").split("/")[-1].removesuffix(".git")
    return CHECKOUTS / name


def first_existing(directory: Path, names: tuple[str, ...]) -> Path | None:
    for name in names:
        candidate = directory / name
        if candidate.is_file():
            return candidate
    return None


def package_notice(identity: str, pin: dict, gaps: list[str]) -> tuple[str, str, str] | None:
    """Returns (file name, version, spdx) after writing the package's notice file, or None for
    an unaccepted licence gap."""
    package = PACKAGES[identity]
    version = pin["state"].get("version") or pin["state"]["revision"][:12]
    directory = checkout_dir(pin)
    if not directory.is_dir():
        raise NoticeError(f"{identity}: no checkout at {directory}. Run `swift package resolve`.")

    licence = first_existing(directory, LICENCE_NAMES)
    if licence is None:
        if identity not in ACCEPTED_GAPS:
            gaps.append(f"{package.name} {version} publishes no licence, so redistribution isn't permitted")
            return None
        # Still credit the author and state plainly that no licence terms exist.
        author = pin["location"].rstrip("/").split("/")[-2]
        file_name = f"{package.name}-no-licence.txt"
        (OUTPUT / file_name).write_text(
            f"{package.name} {version}\n{pin['location']}\nAuthor: {author}\n\n"
            "No licence has been published for this component.\n",
            encoding="utf-8",
        )
        return file_name, version, "No licence published"

    if identity in ACCEPTED_GAPS:
        print(f"note: {package.name} now publishes {licence.name}; remove it from ACCEPTED_GAPS.")

    parts = [licence.read_text(encoding="utf-8").strip()]
    notice = first_existing(directory, NOTICE_NAMES)
    if notice is not None:
        # Apache-2.0 §4(d) requires a NOTICE file's attribution to travel with the work.
        parts.append(f"----- {notice.name} -----\n\n{notice.read_text(encoding='utf-8').strip()}")

    file_name = f"{package.name.replace(' ', '-')}-{package.spdx.replace(' AND ', '+')}.txt"
    header = f"{package.name} {version}\n{pin['location']}\nLicence: {package.spdx}\n\n"
    (OUTPUT / file_name).write_text(header + "\n\n".join(parts) + "\n", encoding="utf-8")
    return file_name, version, package.spdx


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bundled_translation_ids() -> set[str]:
    raw = BUNDLED_DB.read_bytes()
    data = zlib.decompressobj(wbits=-15).decompress(raw)
    with tempfile.NamedTemporaryFile(suffix=".db") as handle:
        handle.write(data)
        handle.flush()
        connection = sqlite3.connect(handle.name)
        try:
            return {row[0] for row in connection.execute("SELECT id FROM translations")}
        finally:
            connection.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--allow-gaps",
        action="store_true",
        help="write notices even when a shipped component has no licence (never for a release)",
    )
    args = parser.parse_args()

    xcode_pins = resolved_pins(XCODE_RESOLVED)
    if {k: v["state"] for k, v in xcode_pins.items()} != {
        k: v["state"] for k, v in resolved_pins(SPM_RESOLVED).items()
    }:
        raise NoticeError("Package.resolved and the Xcode project's Package.resolved disagree; resolve both.")

    stale = set(ACCEPTED_GAPS) - set(PACKAGES)
    if stale:
        raise NoticeError("ACCEPTED_GAPS lists packages that no longer ship: " + ", ".join(sorted(stale)))

    unknown = set(xcode_pins) - set(PACKAGES) - set(EXCLUDED)
    if unknown:
        raise NoticeError(
            "New dependencies need a PACKAGES or EXCLUDED entry before they can ship: "
            + ", ".join(sorted(unknown))
        )

    if sha256(IOS_EDITOR) != sha256(MAC_EDITOR):
        raise NoticeError(
            "The Mac TipTap editor bundle differs from the iOS one, so the iOS editor notices may "
            "not describe it. Review its dependencies and update EDITOR_NOTICE_FILES."
        )

    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    OUTPUT.mkdir(parents=True)

    gaps: list[str] = []
    swift_rows = []
    for identity in sorted(PACKAGES, key=lambda key: PACKAGES[key].name.lower()):
        if identity not in xcode_pins:
            raise NoticeError(f"{identity} is listed in PACKAGES but no longer resolved; remove it.")
        result = package_notice(identity, xcode_pins[identity], gaps)
        version = xcode_pins[identity]["state"].get("version", "")
        if result is None:
            swift_rows.append(f"- {PACKAGES[identity].name} {version} — NO LICENCE PUBLISHED")
        else:
            swift_rows.append(f"- {PACKAGES[identity].name} {version} — {result[2]} — {result[0]}")

    for name in EDITOR_NOTICE_FILES:
        shutil.copy2(IOS_NOTICES / name, OUTPUT / name)

    content_lines = []
    if "KJVs" in bundled_translation_ids():
        shutil.copy2(IOS_NOTICES / CROSSWIRE_NOTICE, OUTPUT / CROSSWIRE_NOTICE)
        content_lines.append(
            "The bundled library includes the CrossWire KJV v3.1 module, so its source, contributor\n"
            f"credits, licence statements and Lamp Bible conversion record are in {CROSSWIRE_NOTICE}.\n"
        )

    readme = f"""THIRD-PARTY SOFTWARE NOTICES — LAMP BIBLE FOR MAC

Lamp Bible for Mac includes the following third-party software. The complete licence text for
each component, and any NOTICE file it publishes, is in this folder.

Swift packages (in the app and its lamp-mcp helper):
{chr(10).join(swift_rows)}

Writing editor (identical to the iPhone and iPad app's):
- Tiptap 3.18.0 packages — MIT — Copyright (c) 2025, Tiptap GmbH
- ProseMirror and related packages — principally MIT; exact package notices are included here
- tiptap-markdown 0.9.0 — MIT — Copyright (c) 2021, Antoine Guingand
- markdown-it and related runtime packages — permissive licences; exact notices are included here

These notices apply to the third-party components only. They do not change the licence of Lamp
Bible itself or the rights in bundled Bible content. Bundled-content notices are published at
https://lampbible.com/content-licences.
{("" if not content_lines else chr(10) + "".join(content_lines))}"""
    (OUTPUT / "README.txt").write_text(readme, encoding="utf-8")

    print(f"Wrote {len(list(OUTPUT.iterdir()))} files to {OUTPUT.relative_to(ROOT)}")
    for identity, reason in EXCLUDED.items():
        print(f"  excluded {identity}: {reason}")
    if gaps:
        print("\nLicence gaps:", file=sys.stderr)
        for gap in gaps:
            print(f"  ✗ {gap}", file=sys.stderr)
        if not args.allow_gaps:
            print("\nNot releasable. Resolve the gaps above; --allow-gaps is for development only.", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except NoticeError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
