#!/usr/bin/env python3
"""Validate a Lamp Bible schema-version-1 presentation deck."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


LAYOUTS = {
    "title",
    "title-and-body",
    "scripture",
    "quotation",
    "two-column",
    "image",
    "closing",
    "blank",
}
BLOCK_KINDS = {
    "title",
    "subtitle",
    "body",
    "scripture",
    "quotation",
    "citation",
    "image",
    "caption",
}
HEX_COLOR = re.compile(r"^#[0-9A-Fa-f]{6}$")


def nonempty(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def positive_integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def validate(deck: object) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []

    if not isinstance(deck, dict):
        return (["$: expected a JSON object"], warnings)

    if deck.get("schemaVersion") != 1:
        errors.append("schemaVersion: expected 1")
    if not nonempty(deck.get("id")):
        errors.append("id: a deck ID is required")
    if not nonempty(deck.get("title")):
        errors.append("title: a deck title is required")
    if deck.get("aspectRatio") not in {"widescreen", "standard"}:
        errors.append("aspectRatio: expected widescreen or standard")

    source = deck.get("source")
    if source is not None:
        if not isinstance(source, dict):
            errors.append("source: expected an object")
        else:
            if source.get("kind") not in {"devotional", "writing", "scripture", "standalone"}:
                errors.append("source.kind: unsupported source kind")
            if not nonempty(source.get("id")):
                errors.append("source.id: a linked source ID is required")

    theme = deck.get("theme")
    if not isinstance(theme, dict):
        errors.append("theme: expected an object")
    else:
        if not nonempty(theme.get("id")):
            errors.append("theme.id: a theme ID is required")
        if theme.get("typeface") is not None and not nonempty(theme.get("typeface")):
            errors.append("theme.typeface: expected a font family or system style")
        for key in ("backgroundColor", "foregroundColor", "accentColor"):
            value = theme.get(key)
            if not isinstance(value, str) or HEX_COLOR.fullmatch(value) is None:
                errors.append(f"theme.{key}: expected #RRGGBB")

    slides = deck.get("slides")
    if not isinstance(slides, list) or not slides:
        errors.append("slides: at least one slide is required")
        return errors, warnings

    slide_ids: set[str] = set()
    for slide_index, slide in enumerate(slides):
        path = f"slides[{slide_index}]"
        if not isinstance(slide, dict):
            errors.append(f"{path}: expected an object")
            continue
        slide_id = slide.get("id")
        if not nonempty(slide_id):
            errors.append(f"{path}.id: a slide ID is required")
        elif slide_id in slide_ids:
            errors.append(f"{path}.id: duplicate slide ID {slide_id!r}")
        else:
            slide_ids.add(slide_id)
        if slide.get("layout") not in LAYOUTS:
            errors.append(f"{path}.layout: unsupported layout")
        if not isinstance(slide.get("speakerNotes"), str):
            errors.append(f"{path}.speakerNotes: expected a string")
        elif len(slide["speakerNotes"]) > 5_000:
            warnings.append(f"{path}.speakerNotes: exceeds 5,000 characters")
        if not isinstance(slide.get("isHidden"), bool):
            errors.append(f"{path}.isHidden: expected true or false")

        blocks = slide.get("blocks")
        if not isinstance(blocks, list):
            errors.append(f"{path}.blocks: expected an array")
            continue
        if not blocks and slide.get("layout") != "blank":
            errors.append(f"{path}.blocks: this layout requires content")
        block_ids: set[str] = set()
        for block_index, block in enumerate(blocks):
            block_path = f"{path}.blocks[{block_index}]"
            if not isinstance(block, dict):
                errors.append(f"{block_path}: expected an object")
                continue
            block_id = block.get("id")
            if not nonempty(block_id):
                errors.append(f"{block_path}.id: a block ID is required")
            elif block_id in block_ids:
                errors.append(f"{block_path}.id: duplicate block ID {block_id!r}")
            else:
                block_ids.add(block_id)
            kind = block.get("kind")
            if kind not in BLOCK_KINDS:
                errors.append(f"{block_path}.kind: unsupported content role")
                continue
            list_style = block.get("listStyle")
            if list_style is not None:
                if list_style not in {"unordered", "ordered"}:
                    errors.append(f"{block_path}.listStyle: expected unordered or ordered")
                elif kind != "body":
                    errors.append(f"{block_path}.listStyle: list formatting requires body content")
            scripture_reference = block.get("scriptureReference")
            if scripture_reference is not None:
                reference_path = f"{block_path}.scriptureReference"
                if not isinstance(scripture_reference, dict):
                    errors.append(f"{reference_path}: expected an object")
                else:
                    if kind != "scripture":
                        errors.append(f"{reference_path}: requires scripture content")
                    if not nonempty(scripture_reference.get("translationID")):
                        errors.append(f"{reference_path}.translationID: a translation ID is required")
                    for key in ("bookNumber", "chapterNumber", "startVerse", "endVerse"):
                        if not positive_integer(scripture_reference.get(key)):
                            errors.append(f"{reference_path}.{key}: expected a positive integer")
                    start_verse = scripture_reference.get("startVerse")
                    end_verse = scripture_reference.get("endVerse")
                    if positive_integer(start_verse) and positive_integer(end_verse) and end_verse < start_verse:
                        errors.append(f"{reference_path}: endVerse must not precede startVerse")
            if kind == "image":
                if not nonempty(block.get("assetPath")):
                    errors.append(f"{block_path}.assetPath: an image path is required")
                if not nonempty(block.get("altText")):
                    warnings.append(f"{block_path}.altText: describe the image for accessibility")
            elif not nonempty(block.get("text")):
                errors.append(f"{block_path}.text: content cannot be empty")
            text = block.get("text", "")
            if kind == "title" and isinstance(text, str) and len(text) > 90:
                warnings.append(f"{block_path}.text: title may be too long")
            if kind == "body" and isinstance(text, str) and len(text) > 700:
                warnings.append(f"{block_path}.text: body may be too dense")

    return errors, warnings


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate_deck.py <presentation.lampdeck>", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"ERROR {path}: {error}", file=sys.stderr)
        return 1

    errors, warnings = validate(document)
    for warning in warnings:
        print(f"WARNING {warning}")
    for error in errors:
        print(f"ERROR {error}", file=sys.stderr)
    if errors:
        print(f"Invalid Lamp deck: {len(errors)} error(s), {len(warnings)} warning(s)", file=sys.stderr)
        return 1
    print(f"Valid Lamp deck: {len(document['slides'])} slide(s), {len(warnings)} warning(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
