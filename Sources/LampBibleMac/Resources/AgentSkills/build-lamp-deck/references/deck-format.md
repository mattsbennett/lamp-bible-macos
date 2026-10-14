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
| `two-column` | Two related or contrasting columns, each with an optional heading and citation |
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

`title` and `closing` are deliberately sparing: they draw a title and one
subtitle, and drop anything further. Put it on its own slide.

### Two columns

A `two-column` slide draws its title and two columns. Each column is, in order:

- an optional `subtitle`, drawn as the column's heading in a heavier weight;
- its prose: `body`, `scripture` or `quotation` blocks;
- an optional `citation`, drawn under the column in the accent colour.

```json
"blocks": [
  { "id": "…", "kind": "title", "text": "Ecclesiastes 7:25 and 7:29" },
  { "id": "…", "kind": "subtitle", "text": "The Preacher’s search" },
  { "id": "…", "kind": "scripture", "text": "to seek wisdom and the scheme of things" },
  { "id": "…", "kind": "citation", "text": "Ecclesiastes 7:25 (ESV)" },
  { "id": "…", "kind": "subtitle", "text": "Mankind’s search" },
  { "id": "…", "kind": "scripture", "text": "they have sought out many schemes." },
  { "id": "…", "kind": "citation", "text": "Ecclesiastes 7:29 (ESV)" }
]
```

A `subtitle` opens a column, and the prose after it belongs to that column
until a citation closes it or the next subtitle opens another. Without
subtitles, each prose block is a column of its own. Do not type a heading or a
reference as the first or last line of a `body` block: it is drawn as body text
like the lines around it. A third column, and a citation that does not directly
follow a column's prose, are not drawn and are reported.

### Type size

Lamp chooses the size of a slide's prose from how much the slide carries. A
slide with two short lines is set large; a slide with six is set smaller; and
everything on one slide shares one size. There is nothing to set and nothing to
pad: do not add words, split a point across lines, or merge slides to change the
size of the type.

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

## Quotations

Lamp sets a quotation rather than expecting you to. On `quotation`, `scripture`,
`title-and-body` and `two-column` slides, each `quotation` and `scripture` block
is drawn:

- wrapped in “curly” quotation marks;
- opening with an ellipsis when the excerpt starts mid-sentence, which is judged
  by a lowercase first letter;
- closing with an ellipsis when it stops mid-sentence, replacing a trailing
  comma, semicolon, colon or dash;
- with any quotation marks inside stepped down to ‘single’ ones.

So type the words and nothing else. An ellipsis you type in the *middle*, where
words are left out, is kept. The stored text never changes — only what is drawn
— so a listener using VoiceOver hears the words as written.

The one case the rule cannot see is an excerpt beginning mid-sentence with a
capitalised word, such as a name. Type the leading ellipsis yourself there; a
typed one is left alone.

To draw a block exactly as stored — poetry, or a deck that wants bare scripture:

```json
"typography": "verbatim"
```

`body`, `caption` and `citation` blocks are never touched: there you type what
you mean. A `quotation` or `scripture` block in a column is set like any other.

### One citation per quotation

A citation closes the passage above it. Two passages from two places are two
quotations, each with its own citation directly after it, and each is drawn with
its own accent rule. Two passages from the same place are one quotation, joined
with an ellipsis, with a single citation.

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

## Speaker notes from the manuscript

A talk has two artifacts that must agree: the writing and the deck. Pasting the
prose into `speakerNotes` by hand goes stale at the first edit and nothing
notices. Instead, let Lamp derive the notes.

Set on the deck:

```json
"speakerNotesSource": "manuscript"
```

`authored` — the default when the field is absent — keeps today's behaviour, in
which `speakerNotes` is whatever you wrote. `manuscript` means Lamp splits the
writing the deck is linked to across its slides, and re-splits it whenever the
prose changes, with no agent running.

Set on each spoken slide:

```json
"notesAnchor": "The first dial is capacity"
```

The opening words of the passage spoken over that slide. Its notes run from
there to the next anchored slide's phrase. A slide with no anchor is silent and
its passage stays with the slide before it, which is how a title slide carries
no notes.

Anchors are searched in slide order, each from where the last one ended, so a
phrase only has to be unique after the previous one. Matching ignores how
whitespace is wrapped and treats straight and curly quotation marks alike.

| If | Then |
| --- | --- |
| A paragraph is reworded, anchor intact | The notes update on that slide |
| An anchor phrase is reworded | The slide keeps its last notes and is reported; its passage reads on under the previous slide |
| A phrase appears twice | The first after the cursor wins, and a longer phrase is suggested |
| Slides are reordered past their passages | Reported, because anchors are never searched backwards |

`speakerNotes` stays in the file as the resolved result, so the presenter view,
the remote and every export keep reading exactly what they read now.

Run `lamp-mcp --build-deck presentation.lampdeck --manuscript draft.md` to fill
them in. It also gives a UUID to any slide or block whose `id` is missing, so a
slide can be added without inventing identifiers.

### Quotations checked against the prose

Every `quotation` block, and every `scripture` block with no
`scriptureReference`, is checked against the manuscript; a fragment of 15
characters or more that no longer appears there is reported on its slide. Text
is split at ellipses first, so an elided quotation is checked in halves. A
scripture block that names its reference is left to the stronger check against
the installed translation.

For a slide that deliberately shows fuller text than the prose quotes:

```json
"manuscriptCheck": "skip"
```

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
| `speakerNotes` | When notes follow the manuscript: how many slides `resolved`, how many are `stale`, and any `problems` |
| `lastImport` | The last import that actually happened, kept through later checks that found nothing new |

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
