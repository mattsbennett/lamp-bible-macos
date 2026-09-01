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
| `title-and-body` | Heading and one focused idea |
| `scripture` | Scripture text with citation |
| `quotation` | Quotation with attribution |
| `two-column` | Two related or contrasting body blocks |
| `image` | Image-led slide with optional title and caption |
| `closing` | Reflection, response, or closing thought |
| `blank` | Deliberate free ordering of supported blocks |

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

## Revision stability

When editing an existing deck:

- Preserve its deck ID.
- Preserve slide IDs when the slide retains the same communicative role.
- Preserve block IDs when revising text in place.
- Generate fresh UUIDs only for genuinely new slides and blocks.
- Remove deleted content instead of retaining dead placeholder blocks.
