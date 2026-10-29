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

Theme fields are `id`, `backgroundColor`, `foregroundColor`, `accentColor`, and optional `typeface` and `highlights` (see Emphasis). Colours use `#RRGGBB`. `typeface` applies presentation-wide; use `system-sans`, `system-serif`, or an installed font family name, and omit it for Lamp Rounded. Prefer one of the built-in themes:

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
| `title` | Opening title and subtitle, with any passages beneath |
| `title-and-body` | Heading with body text, optionally beside a picture |
| `scripture` | Scripture text with citations, optionally beside a picture |
| `quotation` | Quotation with attribution, optionally beside a picture |
| `two-column` | Two related or contrasting columns, each with an optional heading and citation |
| `image` | Image-led slide with optional title, caption, and citations |
| `closing` | Reflection, response, or closing thought, with any passages beneath |
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

`title` and `closing` draw a title, one subtitle (or one body line in its
place), and then any `scripture` or `quotation` blocks, each followed by its
`citation`. The passages are set centred under the heading in much smaller
type, never larger than 32 units against the title's 76, so the slide keeps
the look of a title while a verse waits on screen before a talk begins, or
closes it. A second subtitle or body line is not drawn. Keep the passages
short: past about 450 characters they shrink, and the validator says so. Like
every layout, they can also carry a picture behind them (see "A picture
behind the slide").

### Two columns

A `two-column` slide draws its title and two columns. A headed column is, in
order:

- an optional `subtitle`, drawn as the column's heading in a heavier weight;
- one or more passages, each being `body`, `scripture` or `quotation` blocks
  followed by an optional `citation` in the accent colour.

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

A `subtitle` opens a column and everything after it belongs to that column
until the next subtitle opens another. Inside a headed column a citation closes
the passage it follows rather than the column, so one heading can carry a
writer's sentence and then the verse that answers him, each drawn with its own
citation:

```json
"blocks": [
  { "id": "…", "kind": "title", "text": "Two attitudes" },
  { "id": "…", "kind": "subtitle", "text": "Resignation" },
  { "id": "…", "kind": "quotation", "text": "Nothing to be done." },
  { "id": "…", "kind": "citation", "text": "Beckett, Waiting for Godot" },
  { "id": "…", "kind": "scripture", "text": "We will not walk in it." },
  { "id": "…", "kind": "citation", "text": "Jeremiah 6:16 (ESV)" },
  { "id": "…", "kind": "subtitle", "text": "Expectancy" },
  { "id": "…", "kind": "scripture", "text": "yet I shall again look upon your holy temple." },
  { "id": "…", "kind": "citation", "text": "Jonah 2:4 (ESV)" }
]
```

Without subtitles, each prose block is a column of its own and a citation
attributes the column it follows — so an unheaded column carries one passage.

Do not type a heading or a reference as the first or last line of a `body`
block: it is drawn as body text like the lines around it. A third column, and a
citation with no passage in front of it, are not drawn and are reported.

### Type size

Lamp chooses the size of a slide's prose from how much the slide carries. A
slide with two short lines is set large; a slide with six is set smaller; and
everything on one slide shares one size. There is nothing to set and nothing to
pad: do not add words, split a point across lines, or merge slides to change the
size of the type.

## Content block

Every block has `id`, `kind`, and `text`. It may also contain `assetPath`, `altText`, `placement`, `listStyle`, `scriptureReference`, `chart`, or `emphasis`. Supported kinds are:

- `title`
- `subtitle`
- `body`
- `scripture`
- `quotation`
- `citation`
- `image`
- `caption`
- `chart`

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

## Emphasis

To draw key words bold and in colour, list them in the block's `emphasis`. Each
entry names words in the block's `text`; the text itself stays the words alone,
so a quotation is still checked against its translation and manuscript.

A key detail needs nothing more, and is drawn in the theme's accent colour:

```json
"text": "On the third day there was a wedding at Cana in Galilee",
"emphasis": [{ "text": "third day" }, { "text": "Cana" }]
```

To set ideas, people or sides of a contrast apart, name a colour for each in the
theme's `highlights` and give the name in an entry's `highlight`:

```json
"theme": { "id": "lamp-dark", "backgroundColor": "#111827", "foregroundColor": "#F9FAFB",
           "accentColor": "#F59E0B", "highlights": { "grace": "#60A5FA", "law": "#F87171" } },
…
"text": "For the law was given through Moses; grace and truth came through Jesus Christ.",
"emphasis": [
  { "text": "law", "highlight": "law" },
  { "text": "grace and truth", "highlight": "grace" },
  { "text": "Jesus Christ" }
]
```

One slide can mix both. How an entry matches:

- Exactly as the text has it: case, punctuation and line breaks included. An
  accent typed composed or decomposed is the same letter.
- Whole words only, so `law` does not emphasise part of `lawless`, and a word
  is not matched in part where a combining mark follows it.
- Every appearance, unless `occurrence` names one, counting from 1:
  `{ "text": "holy", "occurrence": 2 }`.
- Where two entries cover the same words, the earlier one is drawn.

Lamp adds no emphasis of its own, and the quotation marks and ellipses it adds
are never emphasised. Use it sparingly: a few words a slide, or none.

Highlight colours use `#RRGGBB` and should reach 3:1 against the background,
like the accent. Over a picture behind the slide, a highlight that would not
read there is drawn in the words' colour, still bold.

An entry that draws nothing — words the text does not have, an `occurrence` past
the last one, a highlight the theme does not name, words an earlier entry
already covers — is a warning, not an error, so the deck still imports. Fix
every one: otherwise the words are simply drawn plain.

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
block's text with that passage as installed and reports a mismatch.

A `scriptureReference` names whole verses. To show part of a verse — a phrase,
or half of one — copy its words exactly, leave the reference off, and name the
passage in the citation. The preview then checks the excerpt against the prose
instead of against the translation, which is the right check for an excerpt.

Keep "paraphrase" for words that are not the translation's. Labelling an exact
excerpt a paraphrase tells a listener the wording is yours when it is not.

### A verse can hold half a quotation

A verse that opens a speech closing in a later verse, or closes one opened
earlier, shows a quotation mark with no partner when it is excerpted alone. In
the ESV, Jeremiah 6:16 opens "Stand by the roads…" and the speech runs on into
verse 17. Start the excerpt after the mark, or include the verse that closes
it.

## Images

Put image files in an `Assets` folder beside `presentation.lampdeck` and
reference them as `Assets/name.jpg`. On import Lamp copies the files the deck
names into the library's presentation assets; files it does not name are left
alone. Until then the preview reads them from where you put them, so an image
can be checked before it has been imported.

An image Lamp cannot find renders as a placeholder on every platform rather
than failing, and both the validator and the preview report it by path.

### A picture behind the slide

Set `"placement": "background"` on an image block and the picture fills the
whole slide behind everything else, on any layout:

```json
"blocks": [
  { "id": "…", "kind": "image", "text": "", "assetPath": "Assets/empire.jpg",
    "altText": "A classical city at the height of its splendour", "placement": "background" },
  { "id": "…", "kind": "title", "text": "Has Mankind Evolved and Become Smarter?" },
  { "id": "…", "kind": "caption", "text": "Thomas Cole, The Consummation of Empire (1836)" }
]
```

- The picture is scaled to fill the slide and centred, so what overflows is
  cropped: a portrait picture loses its top and bottom.
- Lamp chooses the colour of the words. It reads the picture where the words
  fall and sets them in whichever of the theme's two ground colours needs less
  of it covered. Behind the words it blurs the picture slightly, so fine
  detail does not compete with the letters, then darkens or lightens it, in a
  fade the width of the slide, only as far as each block of words needs to
  reach 4.5:1 — a small credit in a dark corner is covered more there without
  the scrim behind the title growing to match. The rest of the picture is left
  as it is. Citations and rules keep the accent colour while it still reads,
  and take the words' colour where it does not.
- A background is not the picture beside the prose. A slide may carry one of
  each; a second background is not drawn.
- With no picture beside the prose, a `caption` credits the background. It is
  drawn small in the slide's lower right corner, on every layout.
- The preview reports, for each slide with a background, the colour chosen and
  how much of the picture was covered. A picture that needs most of itself
  covered for the words to read is named: a quieter picture, or one with open
  space where the words fall, will show more of it.

## Charts

A `chart` block draws where a Strong's key is found, as bars. Name what to
count; never write the numbers. Lamp works the values out from the library when
the deck is built or imported, and overwrites anything it finds there.

```json
{
  "id": "…",
  "kind": "chart",
  "text": "Where ἀγάπη is found",
  "chart": {
    "source": { "strongs": "G26", "translationID": "ESVs", "range": "NT" },
    "style": "columns",
    "by": "book",
    "measure": "occurrences"
  }
}
```

- `source.strongs` is a key such as `G26` or `H3068`.
- `source.translationID` is the translation whose tags are counted. A count is
  only as good as that translation's tagging, so it is not a fact about the
  Bible — name the translation in the caption.
- `source.range` takes whole books: `NT`, `Romans`, `Matthew-John`. Omit it for
  the whole translation.
- `style` is how it is drawn, and decides what the other fields can be:
  - `bars` (the default if absent) ranks the divisions. Keep it under about 24.
  - `columns` stand in Bible order, every book among them including the empty
    ones, so where a word gathers shows as a shape. Twenty-seven or sixty-six
    columns are the point here, not a problem.
  - `grid` shades each book's chapters. It charts `by` book and nothing else,
    and reads badly past about 40 books.
  - `share` is a ring of the whole, largest first. It always counts
    occurrences, whatever `measure` says, because rates per thousand words do
    not add up to a whole. Past eight slices Lamp gathers the smallest into
    "Others".
  - A style Lamp does not know is drawn as bars rather than refused, so a deck
    from a newer Lamp still opens.
- `by` is `book`, `section`, `rendering`, or `form`. Renderings and forms show
  the commonest eight.
- `measure` is `occurrences` or `perThousandWords`. Use the rate when comparing
  books of unequal length, where a raw count mostly measures how long a book is.
- `text` is an optional heading drawn over the bars, and may be empty.
- `values` is Lamp's to write, including each row's `chapters` for a grid.
  Leave it out. The validator warns that a chart
  has none yet, which is the expected state for a deck you have just written.

Use `analyze_strongs` first to find out what is worth charting — which books
stand out, whether the picture is clearer by section, how many bars a grouping
would produce. Charting something and looking at it afterwards wastes a render.

A bar marked `more` or `fewer` means **more or fewer than chance would give**,
tested against the rest of the range, not simply above or below average. Do not
describe it as "Mark's favourite word" or "Paul uses it most" unless the
measure actually says so.

### Where a chart goes

A chart takes the same slot as a picture, so a slide draws one or the other,
never both. It is drawn on `title-and-body`, `scripture`, `quotation`, `blank`,
and `image` slides, and not at all on `two-column`. A `caption` block goes with
it exactly as it would with a picture, and is where the translation belongs.

Keep a *bar* chart under about 24 bars; past that it cannot be read from the
back of a room, and `"by": "section"` is usually the better picture. That limit
is about bars: a `columns` chart of all 27 New Testament books is exactly what
columns are for.

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
| A paragraph a slide *summarises* is reworded | Nothing is reported: what a slide shows does not follow the prose |

That last row is the one to watch. A slide's title and bullets are your reading
of a passage, not a copy of it, so nothing can tell when an edit has left them
behind. After the writing changes, read the slides whose passages changed.
Quotations are the one part that is checked — see "Quotations the manuscript no
longer supports".

`speakerNotes` stays in the file as the resolved result, so the presenter view,
the remote and every export keep reading exactly what they read now.

Lamp derives these notes by itself, whenever the writing is saved, with nothing
running. `lamp-mcp --build-deck presentation.lampdeck --manuscript draft.md`
writes the same notes into the workspace's copy of the deck, so what you have in
front of you matches what Lamp holds. It also gives a UUID to any slide or block
whose `id` is missing, so a slide can be added without inventing identifiers,
and lists a broken anchor both under that slide's entry in `slides` and by slide
number in the top-level `slidesWithProblems`.

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
| `speakerNotes` | When notes follow the manuscript: how many slides `resolved`, how many are `stale`, any `problems`, and `resolvedAt` |
| `lastImport` | The last import that actually happened, kept through later checks that found nothing new |
| `studioEdits` | What the writer has changed in Slide Studio since the last import. Absent when the two copies agree |

A `slideIdentity` showing no reuse means every slide ID was rewritten, which
discards the link between a slide and anything the user has done to it. When
revising a deck, keep the IDs of slides that survive.

`speakerNotes` follows the writing rather than the deck file: Lamp re-splits the
prose across the deck on every save and amends this summary, leaving `outcome`
and `lastImport` describing the artifact. So a reworded anchor shows up here as
`stale` shortly after the writer types it, without the deck being touched. Each
entry in `problems` names its `slide` by one-based position and by `slideID`,
and `resolvedAt` says when the split was last taken.

### What the writer has changed in Slide Studio

There are three copies of a deck and only one of them is yours.
`presentation.lampdeck` is the artifact you write. Slide Studio saves straight
into the library and never touches your file. Lamp records what it put in the
library at the last import, and `studioEdits` is the difference between that
and what is there now.

| Field | Meaning |
| --- | --- |
| `addedSlideIDs` | Slides the writer added, which your import did not put there |
| `removedSlideIDs` | Slides your import put there and the writer has deleted |
| `changedSlideIDs` | Slides in both copies that the writer has edited |
| `reordered` | The shared slides are in a different order |
| `deckSettingsChanged` | The deck's title, theme or aspect ratio |
| `changedAt` | When the library's copy was last written |

**When `studioEdits` is present, writing `presentation.lampdeck` from what you
last wrote will discard every one of those edits on the next import.** Rewriting
the whole artifact is the ordinary way to lose a writer's afternoon. Say what
the file shows and ask, or rewrite only the slides it does not name — their IDs
are given precisely so you can leave the rest alone.

Speaker notes on a deck whose `speakerNotesSource` is `manuscript` are never
reported here. Lamp derives those from the writing and rewrites the deck each
time the prose is saved, so they are Lamp's changes and not the writer's. On a
deck whose notes are `authored`, edited notes do count as the writer's.

## What has changed in the writing

`writing_changes` returns the edits to `draft.md` as unified diffs, newest last,
each saying when it happened and whether it came from the editor — the writer —
or from an agent. Use it instead of keeping copies of the draft to compare:

- `since`: a change `id` from an earlier call, or an ISO 8601 time. Omitted, it
  returns the most recent changes.
- `document_path`: a companion document instead of `draft.md`.
- `limit`, `context`: how many changes, and how many unchanged lines either side.

After a writer's edit, this says what moved; `presentation-import.json` says
whether it broke an anchor.

## Revision stability

When editing an existing deck:

- Preserve its deck ID.
- Preserve slide IDs when the slide retains the same communicative role.
- Preserve block IDs when revising text in place.
- Generate fresh UUIDs only for genuinely new slides and blocks.
- Remove deleted content instead of retaining dead placeholder blocks.
