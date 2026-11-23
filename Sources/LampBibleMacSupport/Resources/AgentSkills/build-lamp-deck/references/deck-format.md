# Lamp presentation deck format

`presentation.lampdeck` is UTF-8 JSON using schema version `1`. Lamp owns visual geometry; the document contains semantic layouts and content roles.

## Deck

| Field | Type | Requirement |
| --- | --- | --- |
| `schemaVersion` | integer | Must be `1` |
| `id` | string | Stable UUID or durable identifier |
| `title` | string | Non-empty |
| `source` | object | For this workspace use `{"kind":"writing","id":"<DEVOTIONAL_ID>"}` (`devotional` is an older name for the same thing, still accepted) |
| `aspectRatio` | string | `widescreen` or `standard` |
| `theme` | object | See Theme |
| `slides` | array | At least one slide |

## Theme

Theme fields are `id`, `backgroundColor`, `foregroundColor`, `accentColor`, and optional `typeface`, `headingTypeface` and `highlights` (see Emphasis). Colours use `#RRGGBB`.

### Typefaces

`typeface` is the deck's body text, and its headings too unless
`headingTypeface` names another. Headings are titles, subtitles and the
headings of columns. Each takes `system-rounded` (Lamp Rounded),
`system-sans`, `system-serif`, or an installed font family name. Omit
`typeface` for Lamp Rounded, and omit `headingTypeface` for headings in the
body's face.

A heading face apart from the body is the simplest way to give a deck
character: a serif title over sans body text, or the reverse. Keep to two
faces. A family another device does not have is drawn in its system font
there, so prefer the `system-` styles for a deck that will travel.

### Built-in themes

Prefer one of Lamp's themes. Copy its colours exactly:

| `id` | Name | `backgroundColor` | `foregroundColor` | `accentColor` | Highlight palette |
| --- | --- | --- | --- | --- | --- |
| `lamp-dark` | Lamp Dark | `#111827` | `#F9FAFB` | `#F59E0B` | `#60A5FA` `#F87171` `#34D399` `#C4B5FD` |
| `parchment` | Parchment | `#F4EBD8` | `#29221B` | `#8B4513` | `#1E5A8C` `#A3242C` `#3F6B2A` `#6B3F8C` |
| `olive-grove` | Olive Grove | `#1C251C` | `#F2EFE4` | `#C8B35A` | `#8EC5E8` `#E8968A` `#A8D08D` `#C9A8E0` |
| `linen` | Linen | `#F8F6F1` | `#1C1C1E` | `#B4432C` | `#1F5FA8` `#8E2C5A` `#2E6B3A` `#7A4FA0` |
| `harbour` | Harbour | `#E9EEF2` | `#13202C` | `#1F5FA8` | `#0F6E78` `#B3261E` `#2E6B3A` `#7A4FA0` |
| `vespers` | Vespers | `#241318` | `#F7EEE9` | `#E39B5C` | `#8FB8E8` `#F28B9B` `#9FD19A` `#C9A8E8` |
| `nocturne` | Nocturne | `#0E1A2B` | `#EEF3F8` | `#7DB7E8` | `#F2B66D` `#F28B9B` `#8FD3A8` `#C9A8E8` |

```json
{
  "id": "olive-grove",
  "backgroundColor": "#1C251C",
  "foregroundColor": "#F2EFE4",
  "accentColor": "#C8B35A",
  "headingTypeface": "system-serif",
  "highlights": { "grace": "#8EC5E8", "law": "#E8968A" }
}
```

The palette is not a field. It lists colours that read on the theme's ground
and stand apart from its accent: a blue, a red, a green and a violet. Take a
deck's `highlights` from it. When the writer switches theme in Slide Studio,
each highlight keeps its name and takes the new theme's colour nearest in hue,
so a deck that set grace in blue still sets it in blue.

### A slide's own background

Set `backgroundColor` on a slide to give it a ground of its own, for a section
break or a slide set apart. The theme's accent, or its `foregroundColor` for a
slide in reverse, are the natural choices. The words take whichever of the
theme's two colours reads better on that ground. The accent and highlights are
kept where they still reach 3:1, and take the words' colour where they do not.
Nothing else needs setting:

```json
{ "id": "…", "layout": "title", "backgroundColor": "#C8B35A",
  "blocks": [{ "id": "…", "kind": "title", "text": "Part Two: The Response" }],
  "speakerNotes": "", "isHidden": false }
```

Use it sparingly: a deck where every slide changes colour has no section breaks
left to mark. A ground on which neither theme colour reaches 4.5:1 is a
warning. A picture behind the slide covers its ground.

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
| `two-column` | Two to four related or contrasting columns, each with an optional heading and citation |
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

### Columns

A `two-column` slide draws its title and two to four columns. The name is the
layout's older one. Two columns suit a contrast; three or four suit
translations or accounts set side by side. Past four, a column is too narrow to
read from the back of a room, so a fifth is not drawn and Lamp warns. A headed
column is, in
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
block: it is drawn as body text like the lines around it. A fifth column, and a
citation with no passage in front of it, are not drawn and are reported.

### Forms of a layout: `variant`

Some layouts have a second form, set with `variant` on the slide. It is
deliberately not a layout of its own: an older Lamp ignores a variant and
draws the plain layout, where an unknown layout would stop the deck opening.

| `variant` | On | Draws |
| --- | --- | --- |
| `statement` | `title`, `closing` | The `title` as large as the slide allows, in heavy type, then any `subtitle` and passages as a title slide sets them. One phrase that lands a point or opens a section: "Grace.", "Who do you say I am?" |
| `word` | `title`, `closing` | A Hebrew or Greek word large: the `title` is the word, a `subtitle` its transliteration, and a `body` block its gloss. Any passages follow, with their citations. |
| `comparison` | `two-column` | The columns, with the words each has and the others lack marked in the accent: translations of one passage, or two accounts of one event. |

```json
{ "id": "…", "layout": "title", "variant": "word",
  "blocks": [
    { "id": "…", "kind": "title", "text": "ἀγάπη" },
    { "id": "…", "kind": "subtitle", "text": "agapē" },
    { "id": "…", "kind": "body", "text": "love: affection, good will, benevolence" },
    { "id": "…", "kind": "scripture", "text": "God is love." },
    { "id": "…", "kind": "citation", "text": "1 John 4:8 (ESV)" }
  ],
  "speakerNotes": "", "isHidden": false }
```

**For a word slide**, take the word, its transliteration and its gloss from
the lexicon `analyze_strongs` returns. Never write them from memory: a
misspelt word or a wrong accent on a slide is read by the whole room.

**For a comparison**, Lamp compares the columns' passages word by word,
ignoring case and punctuation. With two columns, each is marked where the
other lacks a word. With three or four, the first column is the reference: it
is left plain, and each other column is marked where it departs from it, so
put the translation the talk reads from first. Headings are never compared. Put one translation's passage in each column, headed by the
translation's name, with its citation. The marks are drawn as emphasis, so
`revealsEmphasis` lights them on a last click: read the passages through, then
show where they part. Copy each passage exactly from its translation, since
the marks are only as true as the wording.

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

## Figures: timelines and structures

A `body` block can draw its lines as a figure instead of as text. Set `figure`
and write one entry to a line. The figure is the block's own words, so a Lamp
that does not know the figure shows them as the list they are.

A figure is drawn on `title-and-body`, `blank`, `scripture` and `quotation`
slides. A title's line and a column are too narrow for one, so there the lines
are drawn as a list, and Lamp warns.

| `figure` | Each line | Drawn as |
| --- | --- | --- |
| `timeline` | A date, a spaced dash, and what happened: `c. 1000 BC — David king in Jerusalem` | Events evenly along a line in the order written, the date above in the accent, the event below. Keep to 8, or zoom it. |
| `chiasm` | One member of a mirrored structure, in order: the first pairs with the last, the second with the second-last, an odd line is the centre | Lettered A, B, C … C′, B′, A′ in the accent, and stepped in toward the centre. |
| `parallel` | Lines in pairs, as Hebrew poetry sets them: a line, then the line that answers it | Lettered A, A′, B, B′, the answering line set in beneath its partner. |
| `map` | A place the Bible names, as OpenBible.info names it; optionally a spaced dash and what the map should call it | The land around the places, each marked and named. See below. Keep to 16. |

```json
{ "id": "…", "kind": "body", "figure": "timeline",
  "text": "c. 1010 BC — David king in Hebron\nc. 1003 BC — David takes Jerusalem\nc. 966 BC — Solomon begins the temple\nc. 930 BC — The kingdom divides" }
```

- **Timeline dates are the writer's to give.** Biblical chronology is
  disputed, so a timeline shows the dates the talk uses. It does not establish
  them. Say "c." where a date is approximate, and keep one convention (BC/AD
  or BCE/CE) across a deck. The dash between date and event is an em dash, an
  en dash or a hyphen with a space on each side, or a `|`. A colon is not one,
  so "John 3:16" never splits.
- **A chiasm or parallel is a reading of the passage.** The writer has seen
  that structure there, and the slide draws it; it does not prove it. Quote the
  passage's words, or name each member with its verse
  (`Genesis 6:10 — Noah's three sons`), so the room can check the shape against
  the text.
- **Each line arrives on its own click** when the slide sets `"reveal":
  "stepwise"`: a timeline grows an event at a time, and a chiasm can be built in
  to its centre.
- **Emphasis works as anywhere else**, on a date, an event or a word in a
  structure.

### Maps: `"figure": "map"`

A map shows where the places a passage names are, on the land around them,
drawn in the deck's colours with the hills shaded. Write one place per line:

```json
{ "id": "…", "kind": "body", "figure": "map", "map": { "route": true },
  "text": "Antioch 1\nSeleucia\nSalamis\nPaphos\nPerga\nAntioch 2 — Pisidian Antioch\nIconium\nLystra\nDerbe" }
```

- **Name each place as OpenBible.info does.** Lamp ships OpenBible.info's
  Bible Geocoding Data: about 1,250 places, each at its likeliest site. Where two
  places share a name, OpenBible numbers them (`Antioch 1`, Syrian Antioch;
  `Antioch 2`, Pisidian Antioch), and a bare `Antioch` is left off the map with
  a warning. Look names up with the `find_place` tool, which says which name
  draws, the first verse naming each candidate, and how sure the site is.
- **After a spaced dash, what the map prints**:
  `Antioch 2 — Pisidian Antioch`. Without one, the map prints the place's name
  without OpenBible's number.
- **Uncertain sites look uncertain.** Where OpenBible.info's confidence in a
  site is under 50%, the place is an open ring rather than a dot, and the
  validator says so. Many sites are disputed (Bethsaida, Emmaus, Gog and
  Magog). Say so in the talk, or leave the place off; never present one as
  settled.
- **Towns are dots, areas are names.** A land, people or valley (`Galilee 1`,
  `Persia`, `Cush 1`) is a name set wide over its middle; a sea or river is in
  italic; a mountain is a small triangle.
- **`"map": { "route": true }`** joins the places in the order written, for a
  journey. With `"reveal": "stepwise"`, the places arrive one at a time, and the
  route reaches each as it arrives.
- **What the map covers**: Europe, Russia to the Pacific, North Africa, the
  Near East, Arabia and Persia. The closest it goes is about the size of Galilee,
  so places within a couple of kilometres of each other (the hills and quarters
  of Jerusalem) share one mark, with their names set off to the side; the
  validator says so. Name the city instead, or show those places another way.
  The coastlines and rivers are today's, so a harbour that has since silted up
  (Ephesus, Miletus) stands inland.
- **The credit is drawn on the map** ("Places: OpenBible.info · Map: Natural
  Earth"), as OpenBible.info's licence asks. Leave it there.
- A map is drawn on `title-and-body`, `blank`, `scripture` and `quotation`
  slides, filling the room under the heading. A Lamp that does not know maps
  draws the place names as a list.

### A timeline longer than a slide: `zoom`

A timeline of more than 8 events, up to 40, can be shown whole and then a few
events at a time. Add `zoom` to the timeline block:

```json
{ "id": "…", "kind": "body", "figure": "timeline",
  "zoom": { "span": 4, "from": 5, "through": 10 },
  "text": "c. 2000 BC — Abraham called\n…" }
```

| Field | Meaning |
| --- | --- |
| `span` | How many events a zoomed-in view shows, 2 to 8. Defaults to 4. |
| `from`, `through` | The first and last events explored, counted from 1. Absent, the whole timeline is explored. |

The slide arrives showing the whole timeline, its dates thinned so none
runs into the next. Each click then moves the view: in to the first `span`
events of the stretch, along it (each move keeps the last event of the view
before in sight), and back out to the whole, where the stretch explored is
marked. Zoomed in, a small line under the timeline shows the whole and where
the view is. A stretch of `span` events or fewer takes one view, centred on
it.

- **Every move is a click** whether or not the slide sets `"reveal":
  "stepwise"`. With it, the timeline arrives whole on its own click; its events
  do not arrive one at a time.
- **Only a timeline zooms**, and only one with more events than `span`; Lamp
  warns otherwise and draws it whole. A `from` or `through` outside the
  timeline is held to the nearer end.
- **Moves are unhurried and never overshoot**, and with Reduce Motion they
  cut. A Lamp that does not know `zoom` draws the timeline whole.

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

### Where the subject is: `focus`

A picture behind the slide fills it, so what overflows is cropped: a portrait
photograph behind a widescreen slide loses its top and bottom, often the face
at the top. Give the picture a `focus`, the point to keep in view, as fractions
of the picture from its top left, each 0 to 1:

```json
{ "id": "…", "kind": "image", "text": "", "assetPath": "Assets/prophet.jpg",
  "altText": "Rembrandt's Jeremiah, head bowed", "placement": "background",
  "focus": { "x": 0.45, "y": 0.22 } }
```

Lamp slides the crop to keep that point as near the middle as the picture
allows, and never past the picture's edge. Absent means the centre. A picture
beside the prose is shown whole, so a focus there does nothing, and Lamp warns.
The words over the picture are coloured for the part the crop keeps.

### A picture in the deck's colours: `tint`

Pictures from different sources rarely look as if they belong together. Set
`tint` on an image block, behind the slide or beside the prose:

- **`duotone`** draws the picture in two colours, the theme's accent and its
  ground: darks in the darker, lights in the lighter. Lamp Dark gives navy to
  amber, Parchment brown to cream. It is a strong look. Use it for a deck's
  run of background pictures, so they read as one set.
- **`muted`** takes most of the colour out and washes the picture toward the
  theme's ground. Use it for a busy photograph that should sit quietly behind
  words.

Absent, a picture is drawn as it is. The words over a tinted picture are
coloured for it as tinted. Prefer one tint across a deck to a different one on
each slide.

## Charts

A `chart` block puts a figure from Lamp's Strong's analysis on a slide: where a
word falls across the books, how translators rendered it, its original forms
and grammar, the words that keep it company, how each translation tags it, or
the headword card that sums it up. Name what to chart; never write the numbers.
Lamp works the values out from the library when the deck is built or imported,
and overwrites anything it finds there.

```json
{
  "id": "…",
  "kind": "chart",
  "text": "Where ἀγάπη is found",
  "chart": {
    "source": { "strongs": "G26", "translationID": "ESV", "range": "NT" },
    "style": "columns",
    "by": "book",
    "measure": "occurrences"
  }
}
```

### What to count: `source`

- `strongs` is a key such as `G26` or `H3068`.
- `translationID` is the translation whose tags are counted. A count is only
  as good as that translation's tagging, so it is not a fact about the Bible —
  name the translation in the caption. A chart `by` translation compares
  several and does not need this; leave it as `""`.
- `range` takes whole books: `NT`, `Romans`, `Matthew-John`. Omit it for the
  whole translation.
- `filter` narrows the chart to some occurrences only. Give any of these, and
  an occurrence is counted only when it matches every one given:
  - `rendering`: an English rendering, as `analyze_strongs` lists it under
    `renderings` — `"love"`. It matches the word that carries the rendering, so
    `"love"` also keeps "of love" and "love's".
  - `form`: an original-language form, as `analyze_strongs` lists it under
    `originalForms` — `"ἀγάπης"`. Case, and a grave accent standing for an
    acute, are not differences.
  - `grammar`: `{ "feature": "grammaticalCase", "value": "Genitive" }`, the
    feature and value as `analyze_strongs` lists them under `grammar`.
  Everything else in the chart is then of those occurrences alone, each book
  still weighed against all of its tagged words. Say in the heading or caption
  that the chart is narrowed ("where ἀγάπη is rendered *love*"); a narrowed
  figure presented as the whole word misleads.
- `translations` is the list a chart `by` translation compares. Leave it out to
  compare every tagged translation in the library — but naming them keeps the
  slide the same on another device, whose library may hold different ones.
- `includesOriginalLanguages` applies only when `translations` is left out, so
  that the chart compares every tagged translation. Naming a translation is
  asking for it: a named list is drawn as given, original languages included.
  Left to itself, the option lets such a chart count the texts in
  the biblical languages themselves: the Hebrew Bible, the Greek New
  Testament, the Septuagint. **Leave it out unless the reader asks for those
  texts.** Such
  a text does not render the word — it is the word — so its count is the
  tagging restated rather than a translator's choice, and it is usually the
  largest, which sets the scale every real translation is then measured
  against. Set it to `true` only when the point being made is about the
  original text itself, and say so in the caption. It means nothing anywhere
  but a chart `by` translation, which is why naming it elsewhere is a
  warning.

### What to group by: `by`

- `book` and `section` say where the word falls. `section` (Gospels, Paul's
  Letters…) is the clearer picture across a testament.
- `rendering` and `form` rank the English renderings and the original forms;
  a chart shows the commonest eight.
- `grammar` ranks the values of one grammatical feature, named by `feature`
  beside `by`: `partOfSpeech`, `stem`, `form`, `tense`, `voice`, `mood`,
  `person`, `grammaticalCase`, `number`, `gender` or `state`. The feature's
  name as `analyze_strongs` prints it (`"Case"`, `"Part of speech"`) is read
  too.
- `translation` puts the word's count in each translation side by side, with
  its commonest renderings under each name. The counts differ because the
  taggings differ, not because the texts do; say so if it matters to the point.
  The Hebrew and Greek texts are left out unless `includesOriginalLanguages`
  asks for them, so a chart of a Greek key shows what the English Bibles made
  of it rather than being led by the Greek text's own count.
- `companion` ranks the keys that share the word's verses more often than
  chance predicts, named by their lexicon headword and gloss, and measured in
  how many times chance (`9.1×`). Strongest association first, which is not the
  largest multiple: a high multiple over few verses says less than a smaller
  one over many, and the shared-verse count is printed under each for that
  reason.

### How to measure it: `measure`

`occurrences` (the default when absent), `verses`, or `perThousandWords`. Use the
rate when comparing books or translations of unequal length, where a raw count
mostly measures how long a book is. A companion is measured against chance, so
the measure is not read for one.

`verses` counts verses holding the key rather than times it stands, which are
different figures: a word twice in one verse is two occurrences and one verse.
The analysis pane counts verses in several places, so a slide that is meant to
show what the pane shows wants this. Only `book`, `section` and `translation`
can count verses — a rendering, a spelling or a grammatical value is a count of
occurrences, and the verses behind it are not divided that way — and a `grid`
cannot, because it shades chapters, which hold no verse count. Both are errors
rather than warnings: the chart would otherwise draw occurrences under a verses
label.

### How to draw it: `style`

- `bars` (the default when absent) ranks the divisions. Keep it under about 24.
  Bars of a whole — books, sections, renderings, forms, grammar, counted as
  occurrences — print each count with its part of the whole: `12 · 16%`.
- `columns` stand in Bible order, every book among them including the empty
  ones, so where a word gathers shows as a shape. Twenty-seven or sixty-six
  columns are the point here, not a problem.
- `grid` shades each book's chapters. It charts `by` book and nothing else, and
  reads badly past about 40 books.
- `share` is a ring of the whole, largest first: the six largest slices and
  "Other", as Lamp's own analysis draws it. It always counts occurrences,
  whatever `measure` says, because rates per thousand words do not add up to a
  whole. Translations and companions are not parts of one whole, so neither is
  drawn as a share.
- `card` is the analysis's headword card: the word large with its
  transliteration and gloss, three figures saying how common it is, and a
  column for each book beneath. It charts `by` book only. A card makes a good
  opening slide for a word study. Name the three with `figures` to print
  something other than its occurrences, verses and books.
- A style Lamp does not know is drawn as bars rather than refused, so a deck
  from a newer Lamp still opens.

### Which figures a card prints: `figures`

Three names, in the order they are printed, beside `style` on a card:

```json
{ "by": "book", "style": "card", "figures": ["occurrences", "commonest", "forms"] }
```

Leave it out for the card's own three — `occurrences`, `verses` and `books`.
The rest are `chapters` and `sections` (each holding it, of those in range),
`perThousandWords` (the rate, which then leaves the fine print under the
card), `differentWords` (how many different words the translation uses for
it), `forms` (how many spellings it takes in the original) and `commonest`
(the share its commonest word takes, as `67% “love”`).

A figure the word cannot answer is left out rather than filled with something
else, so a word with no forms prints the figures beside it and nothing in that
slot. Only a card reads `figures`, three is all it draws, and a name Lamp does
not know is dropped rather than refused — the validator says so in each case.

### What Lamp writes

`values` — each with its `label` and `value`, and where they apply a
`standing`, a grid row's `chapters`, a bar's `share` of the whole, and a
`detail` line under the label — a card's `headword` (its figures among them),
and `sources` are Lamp's
to write. `sources` says what was matched to the counted translation when its
module was built and the chart rests on, such as Strong's numbers aligned by
machine or Greek spellings carried onto a translation whose source tags only
numbers; the slide prints it under the chart, so a figure never passes for
the translation's own print. Leave them all out. The validator warns that a chart has none yet, which is the
expected state for a deck you have just written. `text` is an optional heading
drawn over the chart, and may be empty.

### Naming the word

A slide is mostly read by people without Greek or Hebrew. Name the word in a
heading or title with its transliteration beside it — "Where ἀγάπη (agapē) is
found" — taking the transliteration from the lexicon `analyze_strongs`
returns, not writing your own.

### From a request to a chart

Use `analyze_strongs` first. It tells you what is worth charting — which books
stand out, whether the picture is clearer by section, how many bars a grouping
would produce — and it gives the exact rendering, form and grammar names a
filter or a grammar chart needs. Charting something and looking at it
afterwards wastes a render.

| Asked for | Chart |
| --- | --- |
| "a ring of how the ESV renders ἀγάπη in John" | `source: {strongs: "G26", translationID: "ESV", range: "John"}`, `by: "rendering"`, `style: "share"` |
| "where it's rendered *love*, book by book" | `source.filter: {rendering: "love"}`, `by: "book"`, `style: "columns"` |
| "only the genitives" | `source.filter: {grammar: {feature: "grammaticalCase", value: "Genitive"}}` |
| "its cases" / "its tenses" | `by: "grammar"`, `feature: "grammaticalCase"` / `"tense"` |
| "compare the translations" | `by: "translation"`, `source.translations: [...]`, `translationID: ""` |
| "what words go with it" | `by: "companion"` |
| "the headword card" | `by: "book"`, `style: "card"` |

Examples of the newer kinds:

```json
{ "kind": "chart", "text": "How the ESV renders ἀγάπη in John",
  "chart": { "source": { "strongs": "G26", "translationID": "ESV", "range": "John" },
             "by": "rendering", "style": "share" } }
```

```json
{ "kind": "chart", "text": "ἀγάπη rendered “love”",
  "chart": { "source": { "strongs": "G26", "translationID": "ESV", "range": "NT",
                         "filter": { "rendering": "love" } },
             "by": "section" } }
```

```json
{ "kind": "chart", "text": "The cases of ἀγάπη",
  "chart": { "source": { "strongs": "G26", "translationID": "BSB" },
             "by": "grammar", "feature": "grammaticalCase" } }
```

```json
{ "kind": "chart", "text": "ἀγάπη in four translations",
  "chart": { "source": { "strongs": "G26", "translationID": "",
                         "translations": ["ESV", "BSB", "KJV", "WEB"] },
             "by": "translation", "measure": "perThousandWords" } }
```

```json
{ "kind": "chart", "text": "Words that keep ἀγάπη company",
  "chart": { "source": { "strongs": "G26", "translationID": "ESV", "range": "NT" },
             "by": "companion" } }
```

```json
{ "kind": "chart", "text": "",
  "chart": { "source": { "strongs": "G26", "translationID": "ESV", "range": "NT" },
             "by": "book", "style": "card" } }
```

(Each block needs its `id` as well; they are left out here for space.)

A bar marked `more` or `fewer` means **more or fewer than chance would give**,
tested against the rest of the range, not simply above or below average. Do not
describe it as "Mark's favourite word" or "Paul uses it most" unless the
measure actually says so. In the same way, renderings are the choices
translators made, not the range of what the word means.

### Where a chart goes

A chart takes the same slot as a picture, so a slide draws one or the other,
never both. It is drawn on `title-and-body`, `scripture`, `quotation`, `blank`,
and `image` slides, and not at all on `two-column`. A `caption` block goes with
it exactly as it would with a picture, and is where the translation belongs.

Keep a *bar* chart under about 24 bars; past that it cannot be read from the
back of a room, and `"by": "section"` is usually the better picture. That limit
is about bars: a `columns` chart of all 27 New Testament books is exactly what
columns are for.

## Presenting: reveals and transitions

Motion in a Lamp deck is deliberately quiet. Slides dissolve into each other,
and content fades in where it will sit. Nothing flies in, spins or zooms, and
Reduce Motion turns all of it off.

### Between slides

Set `transition` on the deck to `dissolve`, which is the default when the field
is absent, or to `cut`. There is nothing else to choose, and nothing to set per
slide.

### A slide a part at a time

Set `"reveal": "stepwise"` on a slide to bring its content in one part per
click while presenting:

| Layout | One part is |
| --- | --- |
| `scripture`, `quotation`, `title-and-body`, `title`, `closing` | each `scripture`, `quotation` or `body` block, with a passage's `citation` arriving alongside its last block, under the words it credits; each item of a list |
| `two-column` | each column, its heading and passages together |
| `blank` | each prose block; each item of a list |
| `image` | nothing: an image slide arrives whole |

- **The first part arrives with the slide**, so no click lands on an empty
  slide.
- **Titles, pictures, charts and credits are there from the start.**
- **Parts still to come are laid out in their place and drawn clear,** so
  nothing on the slide moves as each one arrives, and the type is the size it
  will be when the slide is complete.
- **Going back** returns to the previous slide as it was left, complete.
- **Everywhere but the presenter**, including Slide Studio, thumbnails, the
  remote's next slide and every PDF, shows the slide complete.

Use it where the order of the words matters to the talk, such as a passage
read a verse at a time, a list built point by point, or a contrast given one
side before the other. Leave it off where the room needs the whole slide at
once to follow you. A slide with fewer than two parts arrives whole, and Lamp
warns.

### Emphasis that lights up

Set `"revealsEmphasis": true` on a slide whose blocks carry `emphasis`. The
emphasised words are drawn in their weight but the plain text colour until a
last click of their own, after every part has arrived. Then they take their
colour. Nothing moves when they light, since their weight never changes. It
suits a verse read through once and then looked at again for its key words.
Without any emphasis on the slide it does nothing, and Lamp warns.

```json
{
  "id": "…",
  "layout": "scripture",
  "reveal": "stepwise",
  "revealsEmphasis": true,
  "blocks": [
    { "id": "…", "kind": "scripture", "text": "In the beginning was the Word,",
      "emphasis": [{ "text": "the Word" }] },
    { "id": "…", "kind": "scripture", "text": "and the Word was with God, and the Word was God." },
    { "id": "…", "kind": "citation", "text": "John 1:1 (ESV)" }
  ],
  "speakerNotes": "",
  "isHidden": false
}
```

That slide arrives with the first line. One click brings the second line and
the citation, and one more lights "the Word". Omit both fields for a slide that
arrives whole. An older Lamp ignores them and shows the slide complete.

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
