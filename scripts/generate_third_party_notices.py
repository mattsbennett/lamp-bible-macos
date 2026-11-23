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
- Editor bundle: the Mac's TipTap editor is a copy of the iOS app's, so its JavaScript notices
  are copied from the iOS repo. The two files are deliberately no longer byte-identical, so what
  is checked is the packages rather than the bytes: the Mac's copy must still be the one
  MAC_EDITOR_SHA256 records, and the editor project's lockfile in the iOS repo must list the same
  packages now as at MAC_EDITOR_FROM, the build that copy came from.
- Bundled content: the CrossWire KJV notice is included only when the bundled module database
  actually contains the CrossWire KJV translation, under either spelling of its id.

Usage:
    swift package resolve
    python3 scripts/generate_third_party_notices.py            # fail on any unaccepted licence gap
    python3 scripts/generate_third_party_notices.py --allow-gaps  # development builds only
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sqlite3
import subprocess
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

IOS_REPO = REPOS / "lamp-bible-ios"
IOS_NOTICES = IOS_REPO / "Resource Files" / "Third Party Licenses"
IOS_EDITOR = IOS_REPO / "Lamp Bible" / "Resources" / "TipTapEditor" / "index.html"
IOS_EDITOR_LOCKFILE = "tiptap-editor/package-lock.json"
MAC_EDITOR = ROOT / "Sources" / "LampBibleMac" / "Resources" / "TipTapEditor" / "index.html"
BUNDLED_DB = REPOS / "lamp-bible-modules" / "modules_db" / "bundled_modules.db.zlib"
VERSIFICATION_DATA = (
    REPOS / "lamp-bible-core" / "Sources" / "LampModuleKit" / "LampVersificationData.swift"
)
# Written by core's Scripts/build-map-data.py beside the places it describes.
MAP_NOTICE_SOURCE = REPOS / "lamp-bible-core" / "Sources" / "LampCore" / "Resources" / "Maps" / "NOTICE.txt"


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
    "swift-cmark": Package("swift-cmark", "BSD-2-Clause AND MIT", "app and lamp-mcp helper, via swift-markdown"),
    "swift-log": Package("SwiftLog", "Apache-2.0", "lamp-mcp helper, via MCP Swift SDK"),
    "swift-markdown": Package("swift-markdown", "Apache-2.0", "app and lamp-mcp helper, via LampCore"),
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

# The Mac's editor bundle is a copy of the iPhone's, built from the editor project in the iOS
# repository and patched by hand since. The two files are not byte-identical and will not become
# so: the Mac does not take the phone's editor redesign (owner decision, 2026-11-17), and its own
# injected stylesheet carries that intent tuned for a window instead.
#
# So what is checked is the packages, not the bytes. The notices in EDITOR_NOTICE_FILES have to
# cover every JavaScript package in the Mac's copy, and that is read from the editor project's
# lockfile — a manifest — rather than guessed from minified output. Two things are pinned:
#
#   MAC_EDITOR_SHA256  the copy this record describes, so an edit to the Mac's own bundle is
#                      reviewed rather than inherited;
#   MAC_EDITOR_FROM    the iOS commit it was built at, whose lockfile is the package set the
#                      iOS notices were checked against.
#
# A rebuild of the iOS editor that adds, removes or upgrades no package then passes with no fresh
# review, because rebuilt bytes cannot leave a package unlicensed. A package that does move stops
# the run, which is exactly when EDITOR_NOTICE_FILES needs a file.
MAC_EDITOR_SHA256 = "fb7a42f2667763f17882b7c21cc3617c518a4835021d5c12fb1ba19796aa3a55"
MAC_EDITOR_FROM = "61aff21"
MAC_EDITOR_REVIEW = (
    "2026-11-23: the Mac's copy is the iOS editor's build at 61aff21, script and page alike, "
    "with the Mac's own stylesheet line kept in place of the phone's, as before. Between "
    "ca60d74 and 61aff21 the script gained review marks drawn whole and quickly, a ✓ that takes "
    "its block's marks off as it is pressed, code blocks saved between a fence longer than any "
    "run of backticks in them, fenced code left alone by tidying and read by markdown-it, and a "
    "lone CR read as a line end. The Mac draws the review buttons from its own injected "
    "writing-page sheet. No package moved between ca60d74 and 61aff21: the lockfile lists the "
    "same packages at the same versions; @tiptap/extension-code-block, which the starter kit "
    "already brought in at 3.18.0, is now also named in package.json."
)

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
VERSIFICATION_NOTICE = "SIL-libpalaso-versification-MIT.txt"
MAP_NOTICE = "Bible-maps-OpenBible-CC-BY-4.0-Natural-Earth.txt"

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


def versification_notice() -> tuple[str, str, str]:
    """SIL libpalaso's commit, copyright line and licence text.

    Read out of core's generated source rather than restated here. The data and
    its licence travel together in that file's header, so a notice written by
    hand beside them is one that can be dropped by a regeneration — which is
    what happened to the first one.
    """
    if not VERSIFICATION_DATA.exists():
        raise NoticeError(
            f"{VERSIFICATION_DATA} is missing. The app embeds SIL's versification data "
            "through core, and its notice is read from that file."
        )
    header: list[str] = []
    for line in VERSIFICATION_DATA.read_text(encoding="utf-8").splitlines():
        if not line.startswith("//"):
            break
        header.append(line[2:].removeprefix(" "))
    text = "\n".join(header)

    commit = re.search(r"at commit ([0-9a-f]{7,40})", text)
    copyright_line = re.search(r"^(Copyright \(c\) .+)$", text, re.MULTILINE)
    start = text.find("The MIT License")
    if not commit or not copyright_line or start < 0:
        raise NoticeError(
            f"{VERSIFICATION_DATA.name}'s header no longer carries the upstream commit, a "
            "copyright line and the MIT text. Its notice is generated from those three."
        )
    return commit.group(1), copyright_line.group(1), text[start:].strip() + "\n"


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


def editor_packages(text: str, source: str) -> dict[str, str]:
    """Every package the iOS editor project installs, by its place in the dependency tree, with
    the version installed there. Keyed by the lockfile's own path, so a nested copy of a package
    at a second version stays visible instead of collapsing onto the first."""
    try:
        document = json.loads(text)
    except json.JSONDecodeError as error:
        raise NoticeError(f"the iOS editor lockfile, {source}, is not readable JSON: {error}") from error
    packages = document.get("packages")
    if not packages:
        raise NoticeError(
            f"the iOS editor lockfile, {source}, lists no packages (lockfileVersion "
            f"{document.get('lockfileVersion', 'unknown')}); this check reads 2 and 3."
        )
    return {path: meta.get("version", "") for path, meta in packages.items() if path}


def ios_editor_lockfile(rev: str | None) -> tuple[str, str]:
    """The editor project's lockfile from the iOS checkout, at a commit or as it stands now, with
    a name for it that an error message can use."""
    if rev is None:
        path = IOS_REPO / IOS_EDITOR_LOCKFILE
        if not path.exists():
            raise NoticeError(f"{path} is missing, so the editor's packages cannot be checked.")
        return path.read_text(encoding="utf-8"), f"{IOS_EDITOR_LOCKFILE} as it stands"
    shown = subprocess.run(
        ["git", "-C", str(IOS_REPO), "show", f"{rev}:{IOS_EDITOR_LOCKFILE}"],
        capture_output=True,
        text=True,
    )
    if shown.returncode != 0:
        raise NoticeError(
            f"could not read {IOS_EDITOR_LOCKFILE} at {rev} in {IOS_REPO}: {shown.stderr.strip()}\n"
            "Fetch the iOS repository, or correct MAC_EDITOR_FROM."
        )
    return shown.stdout, f"{IOS_EDITOR_LOCKFILE} at {rev}"


def package_changes(before: dict[str, str], after: dict[str, str]) -> list[str]:
    """Each package added, removed, or moved to another version, one line each."""

    def name(path: str) -> str:
        return path.removeprefix("node_modules/")

    lines = [f"added    {name(path)} {after[path]}" for path in sorted(set(after) - set(before))]
    lines += [f"removed  {name(path)} {before[path]}" for path in sorted(set(before) - set(after))]
    lines += [
        f"upgraded {name(path)} {before[path]} -> {after[path]}"
        for path in sorted(set(before) & set(after))
        if before[path] != after[path]
    ]
    return lines


def editor_divergence() -> str | None:
    """The record saying the iOS editor notices describe the Mac's copy as well, or None when the
    two bundles are the same file and there is nothing to say.

    Raises when the Mac's copy is not the one the record describes, or when the editor's packages
    have moved since the build it came from — the only difference that can leave a shipped package
    with no notice.
    """
    ios_editor, mac_editor = sha256(IOS_EDITOR), sha256(MAC_EDITOR)
    if ios_editor == mac_editor:
        print(
            "note: the editor bundles are identical again; the MAC_EDITOR_* record is spent and "
            "can be removed."
        )
        return None
    if mac_editor != MAC_EDITOR_SHA256:
        raise NoticeError(
            "The Mac TipTap editor bundle is not the copy this script records.\n"
            f"  recorded {MAC_EDITOR_SHA256}\n  on disk  {mac_editor}\n"
            "If the Mac took a newer iOS build, set MAC_EDITOR_FROM to the commit it was built at "
            "and MAC_EDITOR_SHA256 to the hash on disk, and say in MAC_EDITOR_REVIEW what changed."
        )
    reviewed = editor_packages(*ios_editor_lockfile(MAC_EDITOR_FROM))
    current = editor_packages(*ios_editor_lockfile(None))
    changes = package_changes(reviewed, current)
    if changes:
        raise NoticeError(
            "The iOS editor's packages have moved since the build the Mac's copy came from "
            f"({MAC_EDITOR_FROM}), so the iOS editor notices may no longer cover the Mac's "
            "bundle:\n"
            + "".join(f"  {line}\n" for line in changes)
            + "Give each added or upgraded package its own notice in EDITOR_NOTICE_FILES. Then "
            "either take the matching iOS bundle into the Mac, updating MAC_EDITOR_FROM and "
            "MAC_EDITOR_SHA256, or say in MAC_EDITOR_REVIEW why the Mac keeps an older build."
        )
    return MAC_EDITOR_REVIEW


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

    reviewed_divergence = editor_divergence()

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

    commit, copyright_line, licence = versification_notice()
    # What it is and why it ships, then the licence. The commit comes from core
    # so it cannot drift from the data; the description is stable enough to live
    # here.
    (OUTPUT / VERSIFICATION_NOTICE).write_text(
        "SIL libpalaso — standard versifications (SIL.Scripture/Resources/*.vrs.txt)\n"
        f"https://github.com/sillsdev/libpalaso, commit {commit}\n"
        "Used by lamp-bible-core to pair verses that translations number differently.\n"
        "\n"
        + licence,
        encoding="utf-8",
    )
    reference_rows = [
        f"- SIL libpalaso standard versifications, commit {commit[:7]} — MIT — {copyright_line}",
        f"  — {VERSIFICATION_NOTICE}",
    ]
    # Read from core, where the map data and its notice are built together.
    if not MAP_NOTICE_SOURCE.exists():
        raise NoticeError(
            f"{MAP_NOTICE_SOURCE} is missing. Slide maps draw OpenBible.info's places (CC BY 4.0), "
            "and their notice is written beside them by core's Scripts/build-map-data.py."
        )
    shutil.copy2(MAP_NOTICE_SOURCE, OUTPUT / MAP_NOTICE)
    reference_rows += [
        "- OpenBible.info Bible Geocoding Data — CC BY 4.0 — places on slide maps",
        "- Natural Earth — public domain — land, water and relief on slide maps",
        f"  — {MAP_NOTICE}",
    ]

    content_lines = []
    # Either spelling: the Strong's KJV was "KJVs" until translation ids dropped
    # their tagging suffix, and the plain KJV that now holds the bare id has never
    # been bundled, so in this database both names mean the CrossWire module. A
    # notice left out because a bundle was built on the other side of the rename
    # would be a licence failure, not a cosmetic one.
    if {"KJV", "KJVs"} & bundled_translation_ids():
        shutil.copy2(IOS_NOTICES / CROSSWIRE_NOTICE, OUTPUT / CROSSWIRE_NOTICE)
        content_lines.append(
            "The bundled library includes the CrossWire KJV v3.1 module, so its source, contributor\n"
            f"credits, licence statements and Lamp Bible conversion record are in {CROSSWIRE_NOTICE}.\n"
        )

    editor_heading = (
        "Writing editor (the iPhone and iPad app's bundle; the Mac's copy is styled for the Mac\n"
        "and adds no packages of its own):"
        if reviewed_divergence
        else "Writing editor (identical to the iPhone and iPad app's):"
    )

    readme = f"""THIRD-PARTY SOFTWARE NOTICES — LAMP BIBLE FOR MAC

Lamp Bible for Mac includes the following third-party software. The complete licence text for
each component, and any NOTICE file it publishes, is in this folder.

Swift packages (in the app and its lamp-mcp helper):
{chr(10).join(swift_rows)}

{editor_heading}
- Tiptap 3.18.0 packages — MIT — Copyright (c) 2025, Tiptap GmbH
- ProseMirror and related packages — principally MIT; exact package notices are included here
- tiptap-markdown 0.9.0 — MIT — Copyright (c) 2021, Antoine Guingand
- markdown-it and related runtime packages — permissive licences; exact notices are included here

Reference data (in lamp-bible-core):
{chr(10).join(reference_rows)}

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
