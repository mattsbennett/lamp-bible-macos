# Reading the import report

`plan_writing_import` returns, and `import_writings` returns under `report`:

```json
{
  "create": 2, "update": 1, "unchanged": 4, "conflict": 1, "rejected": 1,
  "items": [
    {
      "id": "bible-studies/exhortations/2026JAN18.md",
      "path": "bible-studies/exhortations/2026JAN18.md",
      "writingID": "6F1C…",
      "idDerived": true,
      "title": "The Days of Noah",
      "action": "create",
      "changes": [],
      "errors": [],
      "warnings": ["Contains HTML (<details>, <summary>). …"],
      "normalized": ["Title taken from the heading the file opens with."]
    }
  ]
}
```

- `kind` is `writing`, or `deck` for a deck delivered beside a writing, which has a row of its own after it. A deck in Lamp that differs from the file is a `conflict`, since it may hold changes made in Slide Studio.
- `path` is the file as `<folder>/<path inside it>`. Without an `id`, the writing's id is made from this, so the same path imports to the same writing.
- `action`:
  - `create`: not in the library yet.
  - `update`: in the library, and the file is newer. `changes` names the fields that differ (`title`, `text`, `tags`, …).
  - `unchanged`: in the library exactly as the file has it. Nothing will be written.
  - `conflict`: Lamp's copy may hold edits the person made there: it changed after this file was saved, or the file gives no time to tell (see `lastModified`), or Lamp found the writing only by a path from an earlier import. Lamp keeps their copy unless they choose the file's. Tell them; do not try to get around it.
  - `rejected`: cannot be imported as it is. `errors` says why. Fix the file, or leave it out on purpose and say so.
- `warnings`: imported, but something will not come through as written. Fix what you can (HTML, links to other files, missing footnote definitions) and tell the person about the rest.
- `normalized`: what Lamp tidied on the way in, such as a category filed under its usual name or an opening heading used as the title. Check these are what the writer meant.

When Lamp is not sharing personal writing with agents, the plan cannot see the library: every file reads as `create`, with a warning saying it was not compared. Lamp compares when it shows the import for review, so updates and conflicts appear there.

`import_writings` also returns `requestID`, which `writing_import_status` takes as `request_id`. `writing_import_status` returns `state` (`waiting`, `reviewed` or `cancelled`), and once reviewed, `imported`: the paths of the files whose writings are now in the library. A path missing from it was left out by the person, or changed in Lamp while they were choosing (listed in `refused`).
