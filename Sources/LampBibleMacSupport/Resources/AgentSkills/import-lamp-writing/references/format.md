# Lamp writing import format

## The bundle

A folder of Markdown files (`.md` or `.markdown`), one writing per file, in any layout of subfolders. Lamp reads every Markdown file in it except hidden folders and tools' folders (`node_modules`, `venv`). A single `.md` file can be imported on its own.

Beside the Markdown:

- **Pictures and recordings** the text links to by a path inside the folder — a Markdown image whose path is `images/map.png`, say, or a link to `audio/reading.m4a`. They are copied into the writing, and the image's text becomes the picture's description. Pictures: PNG, JPEG, GIF, HEIC, WebP, TIFF, BMP. Recordings: M4A, MP3, WAV, AAC, AIFF, CAF, FLAC. A link to one that is not there, or that lies outside the folder chosen, rejects the file.
- **A deck**: `talk.lampdeck` beside `talk.md` becomes that writing's presentation, with the pictures its slides name in an `Assets` folder beside the deck (`"assetPath": "Assets/cover.jpg"`). Build it with the build-lamp-deck skill's format; Lamp sets which writing it belongs to. It is a row of its own in the report.

To import only some files, put `lamp-import.json` at the top of the folder:

```json
{
  "formatVersion": 1,
  "writings": [
    { "file": "exhortations/2026-01-18-days-of-noah.md" },
    { "file": "studies/man-of-sin/handout.md", "deck": "decks/man-of-sin.lampdeck" }
  ]
}
```

With it, only the files it names are read, and each must be inside the folder. `deck` names a deck for a file when it is not named after it.

## A file

```markdown
---
id: "exhortation-2026-01-18-days-of-noah"
title: "The Days of Noah"
subtitle: "Two lessons on readiness"
author: "Matthew Bennett"
date: "2026-01-18"
category: "exhortation"
tags: ["Matthew", "readiness"]
series:
  name: "Parables of the Kingdom"
  order: 3
keyScriptures:
  - ref: "Matthew 24:36-44"
  - ref: "Genesis 6"
  - ref: "The flood narrative"
    sv: 1006001
    ev: 1009017
summary: "Jesus draws two lessons from the days of Noah."
---

For this morning's exhortation, I'd like to take some thoughts from
[Matthew 24](lampbible://verse/40024001/40024051).

## The days of Noah

> But concerning that day and hour no one knows. (Matthew 24:36 ESV)

A point that needs a source.[^lewis]

---

[^lewis]: C. S. Lewis, *The World's Last Night* (1960), 107.
```

Front matter is optional. Without it, a file that opens with `# Heading` takes that as its title, and one with no heading takes its file name (the report says so).

## Fields

| Field | What it is | Rules |
|---|---|---|
| `id` | The writing's identity across imports. | Letters, numbers, spaces, `.`, `_`, `-`. Unique in the bundle. Optional: without it, Lamp makes one from the file's path. |
| `title` | The title. | Optional if the file opens with `# Title`. A `# heading` that repeats the title is removed from the text. |
| `subtitle` | A line under the title. | Optional. |
| `author` | Who wrote it. | Only if the source says. |
| `date` | When it was given or written. | `YYYY-MM-DD`. Other text is kept as written, with a warning. Only if the source says. |
| `category` | What kind of writing. | The vocabulary is open: any word, kept as you spell it, capitals and all. Lamp's own are `devotional`, `exhortation`, `reflection`, `study`, `prayer`; `sermon` is filed as `exhortation`, and the report says so. Use the person's word — `Handout`, `Bible class`, `Q&A` — rather than forcing one of the five. Two spellings of one word are one kind. |
| `tags` | Topics. | A list — `[a, b]` or `["Matthew", "readiness"]` — or one comma-separated line, `tags: Matthew, readiness`. |
| `series` | A series and its place in it. | Indented `name:` and a whole-number `order:` beneath `series:`. Both go there: a value written on the `series:` line itself is dropped, so a series with no order is still `series:` with `name:` under it. |
| `keyScriptures` | The passages it is about. | A list of entries. Usually `ref:` alone, a reference as people write it — `Matthew 24:36-44`, `Psalm 23` (a whole chapter), `John 3:16` — which Lamp reads into verses itself. A reference Lamp cannot read is left out, with a warning; where that happens, or where the source names a passage in a form Lamp will not parse, give the verses yourself as `sv:` and optional `ev:` in `BBCCCVVV` (`sv: 40024036`, `ev: 40024044`), and `ref:` is then the label shown. |
| `summary` | The writer's own summary. | Optional; a `## Summary` section at the very top of the text is read as one too. |
| `created`, `lastModified` | When the writing was made and last changed. | ISO 8601 (`2026-01-18T09:00:00Z`) or a date. Without `lastModified`, the file's own saved time is used, which is what lets an import tell a file saved since from a copy edited in Lamp since. A document passed in `documents` has no saved time: give `lastModified`, or any change to a writing already in Lamp arrives as a conflict for the person to choose. |
| `source` | Where you converted it from. | Accepted and ignored; useful for your own bookkeeping. |

Any other key is left out, with a warning.

## The text

Write it as Markdown, as Lamp's editors do:

- Headings (`##` and below for sections; the title is not repeated as `#`), paragraphs, **bold**, *italic*, ~~strikethrough~~, lists, task lists, block quotations, horizontal rules, fenced code, and pipe tables.
- Footnotes: a marker `[^label]` in the text, and its definition `[^label]: …` at the end, under a `---` line. A label is any word without spaces; Lamp numbers them 1, 2, 3 in reading order. Every marker needs a definition.
- Scripture links: `[Matthew 24:36](lampbible://verse/40024036)`, and for a range `lampbible://verse/40024036/40024044`. The number is book, chapter and verse: book as in the 66-book order (Genesis 01, Matthew 40), then three digits of chapter and three of verse. Plain references in the prose are fine left as they are; add links only where they help, and only to the verses the prose names.
- Ordinary web links: `[text](https://example.org/page)`.
- A link to another file of the same import, such as one to `handout.md`, opens that writing in Lamp.

What does not come through:

- **HTML** (`<details>`, `<summary>`, `<a>`, `<div>`): Lamp's writing is Markdown. Turn a collapsible section into a heading with its content beneath, a link into a Markdown link, and so on. Lamp warns about any left in.
- **Links to files not in the import**, such as one to `../audits/2PE.md` when the audits are left out, will not open in Lamp. Keep the link text, or say in words where it pointed. Lamp warns about each.
- **Pictures in `documents`**: a document passed in, rather than a folder, carries text only, so its pictures, recordings and deck need the folder's path instead.

## What Lamp checks

A file is **rejected** (not imported) when:
- its `id` uses characters outside the rule, or another file in the bundle has the same `id`;
- it has no text;
- a `lampbible://` link names a verse that is not in the Bible, or is not a link Lamp can open;
- a picture or recording it links to is not in the folder.

A deck is rejected when it is not a valid Lamp deck, when a picture it names is not in the `Assets` beside it, or when its writing is rejected.

A file is imported with a **warning** when it has HTML, links to files not in the import, a footnote marker without a definition, a front matter key Lamp does not know, a date not in `YYYY-MM-DD`, a key scripture Lamp cannot read, or no title.
