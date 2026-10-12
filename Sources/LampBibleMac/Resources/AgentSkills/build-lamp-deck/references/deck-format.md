# Lamp presentation deck format

`presentation.lampdeck` is UTF-8 JSON using schema version `1`. Lamp owns visual geometry; the document contains semantic layouts and content roles.

## Deck

| Field | Type | Requirement |
| --- | --- | --- |
| `schemaVersion` | integer | Must be `1` |
| `id` | string | Stable UUID or durable identifier |
| `title` | string | Non-empty |
| `source` | object | For this workspace use `{"kind":"devotional","id":"<DEVOTIONAL_ID>"}` |
| `aspectRatio` | string | `widescreen` or `standard` |
| `theme` | object | See Theme |
| `slides` | array | At least one slide |

## Theme

Theme fields are `id`, `backgroundColor`, `foregroundColor`, `accentColor`, and optional `typeface`. Colours use `#RRGGBB`. `typeface` applies presentation-wide; use `system-sans`, `system-serif`, or an installed font family name, and omit it for Lamp Rounded. Prefer one of the built-in themes:

```json
{
  "id": "lamp-dark",
  "backgroundColor": "#111827",
  "foregroundColor": "#F9FAFB",
  "accentColor": "#F59E0B"
}
```

The alternative built-in theme is `parchment` with background `#F4EBD8`, foreground `#29221B`, and accent `#8B4513`.

## Slide

Every slide has:

- `id`: stable UUID or durable identifier.
- `layout`: one supported layout.
- `blocks`: ordered content blocks.
- `speakerNotes`: a string, including an empty string.
- `isHidden`: boolean.

Supported layouts:

| Layout | Intended use |
| --- | --- |
| `title` | Opening title and subtitle |
| `title-and-body` | Heading with body text, optionally beside a picture |
| `scripture` | Scripture text with citations, optionally beside a picture |
| `quotation` | Quotation with attribution, optionally beside a picture |
| `two-column` | Two related or contrasting body blocks |
| `image` | Image-led slide with optional title, caption, and citations |
| `closing` | Reflection, response, or closing thought |
| `blank` | Deliberate free ordering of supported blocks |

### What each layout draws

A `scripture`, `quotation`, or `title-and-body` slide draws **every** quotation
and body block it is given, and **every** citation block — so a passage of three
verses belongs on one slide as three blocks, and a source belongs in a
`citation` block rather than being repeated as a trailing "Source: …" body line.
Several quotations on one slide are set slightly smaller so they share it.

An `image` block is **not** limited to the `image` layout. Add one to a
`scripture`, `quotation`, or `title-and-body` slide and the picture is laid
beside the prose, with a `caption` block beneath it — which is what a cover
image wants, rather than a separate image slide under a headline. Use the
`image` layout when the picture itself is the slide.

Two layouts are deliberately sparing and drop what they are not given room for:
`title` and `closing` draw a title and one subtitle, and `two-column` draws its
title and the first two `body` blocks. Put anything further on its own slide.

## Content block

Every block has `id`, `kind`, and `text`. It may also contain `assetPath`, `altText`, `listStyle`, or `scriptureReference`. Supported kinds are:

- `title`
- `subtitle`
- `body`
- `scripture`
- `quotation`
- `citation`
- `image`
- `caption`

Non-image blocks require non-empty `text`. An image block requires `assetPath` and useful `altText`; its `text` can be empty. Omit optional keys rather than writing `null`.

`assetPath` is a relative path inside the presentation folder, and names a file in its `Assets` directory, such as `Assets/olive-grove.jpg`. It is rejected if it is absolute, starts with `~`, contains a `..` or hidden component, or uses a backslash — a deck travels between machines, so it may only name files the library itself owns. Lamp copies images into `Assets` under generated names when they are chosen in Slide Studio, so prefer referencing an image that is already there over inventing a filename: a path with no file behind it renders as a placeholder on every platform.

For a body block that represents a list, set `listStyle` to `unordered` or `ordered` and put one unadorned list item on each line of `text`. Do not add bullet characters or numbers to the text itself. List formatting is not valid on other block kinds.

A scripture block may preserve the source chosen in Slide Studio with:

```json
"scriptureReference": {
  "translationID": "NRSVue",
  "bookNumber": 43,
  "chapterNumber": 3,
  "startVerse": 16,
  "endVerse": 17
}
```

The copied quotation remains in `text`, and its human-readable reference and translation belong in a separate `citation` block. `scriptureReference` is optional for compatibility with manually supplied quotations, but when present it is valid only on a `scripture` block and must describe a same-chapter ascending verse range.

## Scripture references

`bookNumber` is the book's canonical position, 1 (Genesis) to 66 (Revelation);
`chapterNumber` and `startVerse`/`endVerse` are one-based. These are the same
numbers that appear in Lamp's verse identifiers, which are
`bookNumber * 1000000 + chapterNumber * 1000 + verse` — so John 1:1 is book 43,
chapter 1, verse 1, and the identifier 43001001.

`translationID` is the module ID of an installed translation, not a name you
choose. Ask the `lamp` MCP server with `list_modules` and use the `id` of a
module whose `kind` is `translation`. A reference naming a translation the
library does not have cannot be checked, and the preview says so.

When a scripture block carries a `scriptureReference`, the preview compares the
block's text with that passage as installed and reports a mismatch. Copy the
translation's wording exactly, or drop the reference and label the text a
paraphrase.

## Images

Put image files in an `Assets` folder beside `presentation.lampdeck` and
reference them as `Assets/name.jpg`. On import Lamp copies the files the deck
names into the library's presentation assets; files it does not name are left
alone. Until then the preview reads them from where you put them, so an image
can be checked before it has been imported.

An image Lamp cannot find renders as a placeholder on every platform rather
than failing, and both the validator and the preview report it by path.

## Import status

Each time Lamp looks at `presentation.lampdeck` it writes
`presentation-import.json` beside it. Read it to confirm what happened; do not
write to it.

| Field | Meaning |
| --- | --- |
| `outcome` | `imported`, `unchanged`, `absent`, or `failed` |
| `message` | The same sentence shown in the agent pane |
| `deckID`, `deckTitle`, `slideCount` | What was taken |
| `slideIdentity` | How many slide IDs were `reused`, `added`, and `removed` against the deck already in the library |
| `importedAssets`, `missingAssets` | Images that arrived, and images the deck names that are nowhere to be found |
| `issues` | Everything the validator said, warnings included |

A `slideIdentity` showing no reuse means every slide ID was rewritten, which
discards the link between a slide and anything the user has done to it. When
revising a deck, keep the IDs of slides that survive.

## Revision stability

When editing an existing deck:

- Preserve its deck ID.
- Preserve slide IDs when the slide retains the same communicative role.
- Preserve block IDs when revising text in place.
- Generate fresh UUIDs only for genuinely new slides and blocks.
- Remove deleted content instead of retaining dead placeholder blocks.
