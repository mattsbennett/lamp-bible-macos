---
name: import-lamp-writing
description: Bring existing writing (talks, exhortations, studies, handouts, essays) into Lamp Bible as editable writings, one document or a whole folder. Use when asked to import, migrate or move writing into Lamp, or to prepare files so Lamp can import them faithfully.
---

# Import Lamp Writing

Lamp imports writing from Markdown files: one writing per file, its details in YAML front matter, its text in Markdown as Lamp's editors write it. How you get the source there is yours to decide: read Word or Pages exports, plain Markdown, notes apps' folders, whatever the person has. Lamp's part is to check the files, say exactly what it would do with each, and import only what the person accepts.

## Workflow

1. Read [references/format.md](references/format.md): the front matter fields, the Markdown Lamp keeps, and the rules a file is checked against.
2. Look at the source before converting anything. Decide with the person which files are writing and which are working files (status notes, templates, audits, build scripts). Ask rather than guess when it is unclear.
3. Go through the fields below for each file and fill every one the source answers. A writing that arrives with a title and nothing else has lost what its source already knew about it, and nobody goes back later to type it in.
4. Write the files to import into a folder of your own, outside Lamp's library: the bundle. Leave the person's source files as they are. Add `lamp-import.json` if the folder also holds files that are not writing.
5. Check the bundle with `plan_writing_import`, passing the folder's absolute path. Read [references/report.md](references/report.md) for what it returns. Fix every error in a file you mean to import, and read every warning: each one is something that will not come through as written.
6. Run it again until no file you mean to import is rejected.
7. Ask Lamp to import it with `import_writings`, giving the same path and a short `note` for the person: what the files are, and anything you were unsure of.
8. Tell the person it is waiting for their review in Lamp. Nothing is in the library until they tick it there; never say it has been imported.
9. Later, `writing_import_status`, given the `requestID` that `import_writings` returned as its `request_id`, says which files' writings they imported.

A single document goes the same way: pass its path, or pass it in `documents` with the path it would have in a folder (text only: pictures and decks need a path).

From a shell, `lamp-mcp --plan-writing-import <path>` prints the same report as `plan_writing_import` and exits non-zero when a file would be rejected.

## Every field, and where it comes from

Lamp keeps these for a writing. Fill each one the source answers; leave out the ones it does not. The rules in **Faithful, not invented** below hold for every line of this: read the source for the answer, never supply one.

| Field | Where it usually is | Fill it when |
|---|---|---|
| `title` | The opening `#` heading, the document's own title, a subject line, a filename like `2026-01-18 The Days of Noah.md`. | Always. Without one Lamp falls back to the file's name and says so in the report. |
| `subtitle` | A second line under the title, a dash or colon in a long title (`The Days of Noah — two lessons on readiness`), a strapline. | The source has a second line of title. Do not cut a title in half to make one. |
| `author` | A byline, a signature at the end, a `by …` line, a speaker named on a handout, consistent authorship across a folder the person has confirmed. | A person is named as having written or given it. One name, as the source spells it. |
| `date` | A date in the filename, a heading, a byline, "Given at … on …", a folder named by year. | The source dates it. `YYYY-MM-DD`. A year alone is not a date: leave it out and say so in the `note`. |
| `category` | What the source calls itself — "Exhortation", "Bible class", "Study notes", "Handout" — or the folder it sits in (`exhortations/`, `studies/`). | The source or its folder names a kind. The vocabulary is open: use the person's own word. |
| `tags` | Recurring subjects in a heading list, a `Topics:` line, keywords the source itself lists. | The source lists them. Do not read the prose and invent topics. |
| `series` | A numbered filename (`03-parables.md`), a folder that is plainly one series, a "Part 3 of 5" line, a running title repeated across files. | Several files belong together and the source says so. `order` only when the source gives the place. |
| `keyScriptures` | The passage read at the start, a reference under the title, the passages the writing is actually about. | The writing names the passages it treats. Not every verse it quotes — the ones it is about. |
| `summary` | A `## Summary` section, an abstract, an editor's note, a first paragraph that is plainly a summary and not the opening of the talk. | The source has one of its own. Never write one. |
| `created`, `lastModified` | The source file's own dates, a "revised" line, document metadata from a Word or Pages export. | Converting from another format, where the file you write has today's date and the original does not. This is what lets a second import tell a changed source from a writing edited in Lamp. |
| `id` | A stable name the source already has: a talk number, a slug, a database key. | The source has one. Otherwise leave it out — Lamp derives one from the path, which is stable as long as the file stays where it is. |

Two more that are not front matter and are worth as much:

- **Pictures and recordings** the source carries: put them in the bundle and link them from the text, and give each image a description as its alt text. A picture left behind is lost; nothing in Lamp goes looking for it later.
- **Scripture links** on the references the prose names, as `lampbible://verse/…`. These are what make a writing navigable in Lamp, and they are the one thing the person cannot add in bulk afterwards.

Say in the `import_writings` `note` which fields you could not fill and why, where it is not obvious: a folder of talks with no dates anywhere is worth a sentence.

## Faithful, not invented

- Change the markup, never the meaning. Do not reword, summarise, correct, modernise or "tidy" the prose. A spelling the writer used is theirs.
- Fill a field only from what the source says. Look for the answer properly first — the table above says where each one usually hides — and leave the field out when the source truly does not answer it. An empty field is a gap; a guessed one is a false record, and the person has no way to tell which they are reading.
- A summary is the writer's own, if the source has one. Do not write one.
- Key scriptures are the passages the writing is about, as it names them. Do not add passages it does not discuss.
- A scripture link must name the verses the prose names. Lamp rejects a link to a verse that does not exist, but cannot tell a real verse that is the wrong one.
- Keep quotations, including scripture, exactly as the source has them.

## Identity and importing again

- Each writing's identity is its `id`. Give one when the source has a stable name for the writing; otherwise leave it out and Lamp makes one from the file's path in the folder.
- Without an `id`, the same path is the same writing. Lamp also looks for a writing imported before from a folder above or inside this one, and offers what it finds for the person to confirm, since a path alone does not prove it is the same file. Keep file names and their folders the same from one import to the next, or set `id`s yourself: a renamed or moved file becomes a new writing.
- Importing again updates writings whose files changed, leaves unchanged ones alone, and marks one the person has edited in Lamp since as a conflict, which keeps their copy unless they choose otherwise. Do not try to work around a conflict.

## Do not

- Do not write into Lamp's library folder or its database. Lamp writes the library; the import is how writing gets there.
- Do not tell the person an import cannot be taken back: Lamp keeps the last few, and they can undo one from the Import window. Undoing leaves anything they have changed since.
- Do not split one source document into several writings, or join several into one, unless the person asks.
- Do not import working files, templates or tool output as writing.
