#!/usr/bin/env python3
"""Validate a Lamp Bible schema-version-1 presentation deck."""

from __future__ import annotations

import json
import re
import sys
import unicodedata
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

# What each layout actually draws. This mirrors `LampPresentationSlidePlan` in
# LampCore, which the renderer itself draws from; the two must agree, or this
# script will approve a slide the app then shows differently.
#
# A value is the set of block kinds drawn, with how many of each. `None` means
# every block of that kind is drawn.
LAYOUT_CAPACITY: dict[str, dict[str, int | None]] = {
    # A heading, one line under it, and any passages beneath those.
    "title": {
        "title": 1, "subtitle": 1, "body": 1, "scripture": None,
        "quotation": None, "citation": None,
    },
    "closing": {
        "title": 1, "subtitle": 1, "body": 1, "scripture": None,
        "quotation": None, "citation": None,
    },
    "title-and-body": {
        "title": 1, "subtitle": None, "body": None, "scripture": None,
        "quotation": None, "citation": None, "image": 1, "caption": 1,
    },
    "scripture": {
        "scripture": None, "quotation": None, "body": None,
        "citation": None, "image": 1, "caption": 1,
    },
    "quotation": {
        "scripture": None, "quotation": None, "body": None,
        "citation": None, "image": 1, "caption": 1,
    },
    # Columns are grouped rather than counted; see `undrawn_in_columns`.
    "two-column": {},
    "image": {"title": 1, "image": 1, "caption": 1, "citation": None},
    "blank": {
        "title": None, "subtitle": None, "body": None, "scripture": None,
        "quotation": None, "citation": None, "image": 1, "caption": 1,
    },
}
# `title` and `closing` draw one line under the heading, from either kind.
SHARED_SUBTITLE_SLOT = {"title", "closing"}
# Past this much text a slide is shrinking its own type to fit. Halved when an
# image takes the other half of the slide.
CROWDING_CEILING = 900
SPEAKER_NOTES_SOURCES = {"authored", "manuscript"}
MANUSCRIPT_CHECKS = {"skip"}
# Notes can only follow writing Lamp holds.
MANUSCRIPT_SOURCE_KINDS = {"devotional", "writing"}
TYPOGRAPHY = {"verbatim"}
PLACEMENTS = {"background"}
# Lamp sets quotations on these layouts, so it adds the marks itself.
QUOTE_TYPOGRAPHY_LAYOUTS = {
    "quotation", "scripture", "title-and-body", "two-column", "title", "closing",
}
# Layouts that read their prose as passages, each closed by its citation.
QUOTE_GROUP_LAYOUTS = {"quotation", "scripture", "title-and-body", "title", "closing"}
# Passages under a title share the slide with its heading.
UNDER_TITLE_LAYOUTS = {"title", "closing"}
COLUMN_PROSE = {"body", "scripture", "quotation"}
QUOTE_MARKS = {'"', "\u201c", "\u201d"}


def has_typed_outer_quotation_marks(text: str) -> bool:
    trimmed = (text or "").strip()
    if len(trimmed) < 2 or trimmed[0] not in QUOTE_MARKS or trimmed[-1] not in QUOTE_MARKS:
        return False
    # Marks at both ends with another between them belong to the text.
    return not any(ch in QUOTE_MARKS for ch in trimmed[1:-1])


def quote_groups(blocks: list) -> list[tuple[int, int]]:
    """(quotations, citations) per group, reading the slide in order.

    Only quoted matter counts. A slide with a bulleted list, one quotation and
    its citation has one thing quoted, not two.
    """
    groups: list[tuple[int, int]] = []
    pending = 0
    for block in blocks:
        if not isinstance(block, dict):
            continue
        kind = block.get("kind")
        if kind in {"quotation", "scripture"}:
            pending += 1
        elif kind == "citation":
            groups.append((pending, 1))
            pending = 0
    if pending:
        groups.append((pending, 0))
    return groups


def characters(text: str) -> list[str]:
    """`text` as Lamp reads it to find emphasised words: composed (NFC), with
    each combining mark kept with the letter before it.

    Swift compares grapheme clusters by canonical equivalence and Python
    compares code points, so without this the two disagree on a decomposed
    accent, and on pointed Hebrew, which has no composed forms.

    Emoji sequences are the known gap: Swift keeps a joined family, a flag or
    a skin tone as one character, and this splits them. The two disagree only
    when emphasis names part of one, and full segmentation needs a module the
    standard library lacks.
    """
    result: list[str] = []
    for ch in unicodedata.normalize("NFC", text):
        if result and unicodedata.category(ch).startswith("M"):
            result[-1] += ch
        else:
            result.append(ch)
    return result


def is_word_character(character: str) -> bool:
    return character[:1].isalnum()


def emphasis_matches(phrase: str, text: str) -> list[range]:
    """Where `phrase` appears in `text` as whole words, as character offsets,
    left to right and never overlapping. Mirrors `LampPresentationEmphasis`."""
    words = characters(phrase)
    chars = characters(text)
    if not words:
        return []
    found: list[range] = []
    start = 0
    while start + len(words) <= len(chars):
        end = start + len(words)
        if (
            chars[start:end] == words
            and not (start > 0 and is_word_character(chars[start - 1]) and is_word_character(words[0]))
            and not (end < len(chars) and is_word_character(chars[end]) and is_word_character(words[-1]))
        ):
            found.append(range(start, end))
            start = end
        else:
            start += 1
    return found


def emphasis_issues(block: dict, highlight_names: set[str]) -> tuple[list[str], list[str]]:
    """Errors for emphasis Lamp cannot read, and warnings, by the path of the
    entry within the block, for emphasis that will not be drawn as written.

    The second are warnings, never errors: Lamp refuses to save or sync a deck
    with errors, and rewording a slide must not make its deck unsavable.
    """
    emphasis = block.get("emphasis")
    if emphasis is None:
        return [], []
    if not isinstance(emphasis, list):
        return ["emphasis: expected an array of entries"], []
    errors: list[str] = []
    for index, entry in enumerate(emphasis):
        path = f"emphasis[{index}]"
        if not isinstance(entry, dict):
            errors.append(f"{path}: expected an object")
            continue
        if not isinstance(entry.get("text"), str):
            errors.append(f"{path}.text: expected the words to emphasise")
        if entry.get("highlight") is not None and not isinstance(entry.get("highlight"), str):
            errors.append(f"{path}.highlight: expected the name of a theme highlight")
        occurrence = entry.get("occurrence")
        if occurrence is not None and (not isinstance(occurrence, int) or isinstance(occurrence, bool)):
            errors.append(f"{path}.occurrence: expected a whole number")
    if errors or not emphasis:
        return errors, []
    if block.get("kind") == "image":
        return [], ["emphasis: emphasis is drawn on words, and an image block has none"]

    warnings: list[str] = []
    text = block.get("text") if isinstance(block.get("text"), str) else ""
    taken = [False] * len(characters(text))
    for index, entry in enumerate(emphasis):
        path = f"emphasis[{index}]"
        phrase = entry["text"]
        if not phrase:
            warnings.append(f"{path}: name the words to emphasise")
            continue
        name = entry.get("highlight")
        if name is not None and name not in highlight_names:
            warnings.append(
                f"{path}: the theme has no highlight named {name!r}, so these words "
                "take the accent colour"
            )
        matches = emphasis_matches(phrase, text)
        if not matches:
            warnings.append(
                f"{path}: {phrase!r} is not in this block's text as whole words, so "
                "nothing is emphasised; copy the words exactly as the text has them"
            )
            continue
        occurrence = entry.get("occurrence")
        if occurrence is not None and not 1 <= occurrence <= len(matches):
            warnings.append(
                f"{path}: count occurrences from 1" if occurrence < 1 else
                f"{path}: {phrase!r} appears {len(matches)} time(s) in this block's text, "
                f"so occurrence {occurrence} emphasises nothing"
            )
            continue
        drawn = matches if occurrence is None else [matches[occurrence - 1]]
        overlaps = False
        for match in drawn:
            if any(taken[offset] for offset in match):
                overlaps = True
            else:
                for offset in match:
                    taken[offset] = True
        if overlaps:
            warnings.append(
                f"{path}: {phrase!r} overlaps words an earlier entry emphasises, so it "
                "is not drawn there"
            )
    return [], warnings


def relative_luminance(value: str) -> float | None:
    if not HEX_COLOR.match(value or ""):
        return None
    rgb = int(value[1:], 16)
    channels = []
    for shift in (16, 8, 0):
        channel = ((rgb >> shift) & 0xFF) / 255
        channels.append(
            channel / 12.92 if channel <= 0.03928 else ((channel + 0.055) / 1.055) ** 2.4
        )
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]


def contrast_ratio(first: str, second: str) -> float | None:
    a, b = relative_luminance(first), relative_luminance(second)
    if a is None or b is None:
        return None
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)


def undrawn_in_columns(blocks: list) -> list[tuple[int, str]]:
    """Mirror of Lamp's two-column reading.

    A `subtitle` opens a column and names it; everything after it is that
    column's until the next subtitle opens another. Inside a headed column a
    citation closes the passage it follows rather than the column, so a column
    can credit a writer and then the verse that answers him, each passage drawn
    with its own citation.

    With no subtitles, every prose block is a column of its own and a citation
    attributes the column it follows. Only the first two columns are drawn.
    """
    kinds = [b.get("kind") if isinstance(b, dict) else None for b in blocks]
    uses_headings = "subtitle" in kinds
    columns: list[dict] = []
    undrawn: list[tuple[int, str]] = []
    title_taken = False
    # Prose read since the last citation, waiting to be attributed.
    pending: list[int] = []

    def close(citation: int | None) -> None:
        """Closes what has been read into the open column as one passage."""
        nonlocal pending
        if not pending or not columns:
            return
        columns[-1]["indexes"].extend(pending)
        columns[-1]["prose"] += len(pending)
        if citation is not None:
            columns[-1]["indexes"].append(citation)
        pending = []

    for index, kind in enumerate(kinds):
        if kind is None:
            continue
        if kind == "title":
            if title_taken:
                undrawn.append((index, kind))
            title_taken = True
        elif kind == "subtitle":
            # Whatever is still open belongs to the column being left.
            close(None)
            columns.append({"indexes": [index], "prose": 0, "cited": False})
        elif kind in COLUMN_PROSE:
            if uses_headings and columns:
                pending.append(index)
            else:
                columns.append({"indexes": [index], "prose": 1, "cited": False})
        elif kind == "citation":
            if uses_headings:
                if pending:
                    close(index)
                else:
                    undrawn.append((index, str(kind)))
            elif columns and columns[-1]["prose"] and not columns[-1]["cited"]:
                columns[-1]["indexes"].append(index)
                columns[-1]["cited"] = True
            else:
                undrawn.append((index, str(kind)))
        else:
            undrawn.append((index, str(kind)))
    # A column may end on an unattributed passage, which still draws.
    close(None)
    for column in columns[2:]:
        undrawn.extend((index, str(kinds[index])) for index in column["indexes"])
    return sorted(set(undrawn))


def is_background(block: object) -> bool:
    return (
        isinstance(block, dict)
        and block.get("kind") == "image"
        and block.get("placement") == "background"
    )


def undrawn_blocks(layout: str, blocks: list) -> list[tuple[int, str]]:
    """Indexes and kinds of blocks this layout will not draw.

    A picture behind the slide is taken first, on every layout, and the rest
    is read as if it were not there. A second one is not drawn. With no
    picture beside the prose, the first caption credits the one behind.
    """
    backgrounds = [index for index, block in enumerate(blocks) if is_background(block)]
    rest = [None if is_background(block) else block for block in blocks]
    undrawn_backgrounds = [(index, "image") for index in backgrounds[1:]]
    if backgrounds and not any(
        isinstance(b, dict) and b.get("kind") == "image" for b in rest
    ):
        credit = next(
            (i for i, b in enumerate(rest) if isinstance(b, dict) and b.get("kind") == "caption"),
            None,
        )
        if credit is not None:
            rest[credit] = None
    return sorted(set(undrawn_backgrounds + undrawn_in_layout(layout, rest)))


def undrawn_in_layout(layout: str, blocks: list) -> list[tuple[int, str]]:
    if layout == "two-column":
        return undrawn_in_columns(blocks)
    capacity = LAYOUT_CAPACITY.get(layout)
    if capacity is None:
        return []
    used: dict[str, int] = {}
    subtitle_slot_taken = False
    undrawn: list[tuple[int, str]] = []
    for index, block in enumerate(blocks):
        if not isinstance(block, dict):
            continue
        kind = block.get("kind")
        if kind not in capacity:
            undrawn.append((index, str(kind)))
            continue
        if layout in SHARED_SUBTITLE_SLOT and kind in {"subtitle", "body"}:
            if subtitle_slot_taken:
                undrawn.append((index, str(kind)))
            subtitle_slot_taken = True
            continue
        limit = capacity[kind]
        if limit is None:
            continue
        used[kind] = used.get(kind, 0) + 1
        if used[kind] > limit:
            undrawn.append((index, str(kind)))
    # A caption belongs to a picture; without one it is never drawn.
    if layout != "image" and not any(
        isinstance(b, dict) and b.get("kind") == "image" for b in blocks
    ):
        for index, block in enumerate(blocks):
            if isinstance(block, dict) and block.get("kind") == "caption":
                if (index, "caption") not in undrawn:
                    undrawn.append((index, "caption"))
    return sorted(set(undrawn))


def safe_asset_path(value):
    """Mirror Lamp's own check: a relative path that cannot leave the folder.

    A deck travels between machines, so an absolute path, a `..` component, or a
    hidden or Windows-style path names a file the library does not own and is
    refused on import.
    """
    if not isinstance(value, str):
        return False
    value = value.strip()
    if not value or len(value) > 1024:
        return False
    if value[0] in ("/", "~", "\\"):
        return False
    if "\\" in value or ":" in value or "\0" in value:
        return False
    parts = value.split("/")
    return all(part and part not in (".", "..") and not part.startswith(".") for part in parts)


def nonempty(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def positive_integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def validate(deck: object, deck_directory: Path | None = None) -> tuple[list[str], list[str]]:
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
        background = theme.get("backgroundColor", "")
        for key, floor in (("foregroundColor", 4.5), ("accentColor", 3.0)):
            ratio = contrast_ratio(theme.get(key, ""), background)
            if ratio is not None and ratio < floor:
                warnings.append(
                    f"theme.{key}: contrasts with the background at only {ratio:.1f}:1; "
                    f"aim for {floor:.1f}:1 or more"
                )
        highlights = theme.get("highlights")
        if highlights is not None and not isinstance(highlights, dict):
            errors.append("theme.highlights: expected an object of names and #RRGGBB colours")
        elif isinstance(highlights, dict):
            # Held to the accent's 3:1, WCAG's level for large and bold text,
            # which emphasised words on a slide always are.
            for name in sorted(highlights):
                value = highlights[name]
                if not name.strip():
                    errors.append("theme.highlights: a highlight needs a name for emphasis to give")
                elif not isinstance(value, str) or HEX_COLOR.fullmatch(value) is None:
                    errors.append(f"theme.highlights.{name}: expected #RRGGBB")
                else:
                    ratio = contrast_ratio(value, background)
                    if ratio is not None and ratio < 3.0:
                        warnings.append(
                            f"theme.highlights.{name}: highlighted words contrast with the "
                            f"background at only {ratio:.1f}:1; aim for 3.0:1 or more"
                        )

    notes_source = deck.get("speakerNotesSource")
    follows_manuscript = notes_source == "manuscript"
    if notes_source is not None and notes_source not in SPEAKER_NOTES_SOURCES:
        errors.append(
            "speakerNotesSource: expected 'authored' or 'manuscript'"
        )
    if follows_manuscript:
        source = deck.get("source")
        kind = source.get("kind") if isinstance(source, dict) else None
        if kind is None:
            warnings.append(
                "speakerNotesSource: notes follow the manuscript but this deck is "
                "linked to no writing"
            )
        elif kind not in MANUSCRIPT_SOURCE_KINDS:
            warnings.append(
                f"speakerNotesSource: notes can only follow a devotional or writing "
                f"source, and this deck's is {kind!r}"
            )

    theme_highlights = theme.get("highlights") if isinstance(theme, dict) else None
    highlight_names = set(theme_highlights) if isinstance(theme_highlights, dict) else set()

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
        anchor = slide.get("notesAnchor")
        if anchor is not None and not isinstance(anchor, str):
            errors.append(f"{path}.notesAnchor: expected a string")
        elif isinstance(anchor, str) and not anchor.strip():
            errors.append(f"{path}.notesAnchor: cannot be empty; omit it instead")
        elif isinstance(anchor, str) and not follows_manuscript:
            warnings.append(
                f"{path}.notesAnchor: ignored unless speakerNotesSource is 'manuscript'"
            )

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
                asset_path = block.get("assetPath")
                if not nonempty(asset_path):
                    errors.append(f"{block_path}.assetPath: an image path is required")
                elif not safe_asset_path(asset_path):
                    errors.append(
                        f"{block_path}.assetPath: use a relative path inside the "
                        "presentation folder, such as Assets/photo.jpg"
                    )
                if not nonempty(block.get("altText")):
                    warnings.append(f"{block_path}.altText: describe the image for accessibility")
            placement = block.get("placement")
            if placement is not None:
                if placement not in PLACEMENTS:
                    errors.append(f"{block_path}.placement: expected 'background'")
                elif kind != "image":
                    errors.append(f"{block_path}.placement: placement requires image content")
            if kind != "image" and not nonempty(block.get("text")):
                errors.append(f"{block_path}.text: content cannot be empty")
            text = block.get("text", "")
            if kind == "title" and isinstance(text, str) and len(text) > 90:
                warnings.append(f"{block_path}.text: title may be too long")
            if kind == "body" and isinstance(text, str) and len(text) > 700:
                warnings.append(f"{block_path}.text: body may be too dense")
            typography = block.get("typography")
            if typography is not None and typography not in TYPOGRAPHY:
                errors.append(f"{block_path}.typography: expected 'verbatim'")
            if (
                kind in {"quotation", "scripture"}
                and typography != "verbatim"
                and slide.get("layout") in QUOTE_TYPOGRAPHY_LAYOUTS
                and isinstance(text, str)
                and has_typed_outer_quotation_marks(text)
            ):
                warnings.append(
                    f"{block_path}.text: Lamp adds the quotation marks; remove these"
                )
            check = block.get("manuscriptCheck")
            if check is not None:
                if check not in MANUSCRIPT_CHECKS:
                    errors.append(f"{block_path}.manuscriptCheck: expected 'skip'")
                elif kind not in {"quotation", "scripture"}:
                    warnings.append(
                        f"{block_path}.manuscriptCheck: only quotation and scripture "
                        "content is checked against the manuscript, so this has no effect"
                    )
            emphasis_errors, emphasis_warnings = emphasis_issues(block, highlight_names)
            errors.extend(f"{block_path}.{issue}" for issue in emphasis_errors)
            warnings.extend(f"{block_path}.{issue}" for issue in emphasis_warnings)

        # Images the deck names but nobody delivered. They render as
        # placeholders rather than failing, so this is a warning.
        if isinstance(blocks, list) and deck_directory is not None:
            for index, block in enumerate(blocks):
                if not isinstance(block, dict) or block.get("kind") != "image":
                    continue
                asset = block.get("assetPath")
                if not isinstance(asset, str) or not safe_asset_path(asset):
                    continue
                if not (deck_directory / asset).is_file():
                    warnings.append(
                        f"{path}.blocks[{index}].assetPath: no file at {asset!r}; "
                        "the slide renders a placeholder until the image is delivered "
                        "beside the deck"
                    )

        # Blocks the layout will never draw. Saying nothing here is what sent
        # deck authors to read the renderer to find out why a slide was bare.
        if isinstance(blocks, list):
            for index, kind in undrawn_blocks(slide.get("layout", ""), blocks):
                warnings.append(
                    f"{path}.blocks[{index}]: a {slide.get('layout')} slide does not draw "
                    f"{kind} content; move it to another slide or change the layout"
                )

            # Several passages sharing one attribution read as one passage with
            # a list of sources under it.
            if slide.get("layout") in QUOTE_GROUP_LAYOUTS:
                groups = [g for g in quote_groups(blocks) if g[0] > 0]
                if len(groups) == 1 and groups[0][0] > 1 and groups[0][1] == 1:
                    warnings.append(
                        f"{path}.blocks: {groups[0][0]} quotations share one citation; "
                        "give each its own, directly after it"
                    )

            under_title = slide.get("layout") in UNDER_TITLE_LAYOUTS
            # A title's body block is the line under its heading, not prose.
            counted = (
                {"scripture", "quotation", "citation"}
                if under_title
                else {"body", "scripture", "quotation", "citation"}
            )
            drawn_text = sum(
                len(block.get("text", ""))
                for block in blocks
                if isinstance(block, dict) and block.get("kind") in counted
            )
            # A picture behind the slide leaves the prose the whole slide.
            has_image = any(
                isinstance(block, dict) and block.get("kind") == "image"
                and not is_background(block)
                for block in blocks
            )
            ceiling = CROWDING_CEILING // 2 if has_image or under_title else CROWDING_CEILING
            if drawn_text > ceiling:
                if under_title:
                    where = "the passages under this slide's title"
                elif has_image:
                    where = "the half of this slide left by its image"
                else:
                    where = "this slide"
                warnings.append(
                    f"{path}.blocks: about {drawn_text} characters of text for {where}; "
                    "text shrinks to fit before it is clipped, so split this across slides"
                )

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

    errors, warnings = validate(document, deck_directory=path.resolve().parent)
    if document.get("speakerNotesSource") == "manuscript" and not any(
        isinstance(slide, dict) and (slide.get("notesAnchor") or "").strip()
        for slide in document.get("slides", [])
        if isinstance(slide, dict)
    ):
        warnings.append(
            "slides: notes follow the manuscript but no slide says where its passage "
            "begins; give each spoken slide a notesAnchor"
        )
    if document.get("speakerNotesSource") == "manuscript":
        print(
            "NOTE anchors are resolved against the manuscript by "
            "`lamp-mcp --build-deck`, which this script cannot do."
        )
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
