---
name: import-lamp-writing
description: Bring existing writing (talks, exhortations, studies, handouts, essays) into Lamp Bible as editable writings, one document or a whole folder. Use when asked to import, migrate or move writing into Lamp, or to prepare files so Lamp can import them faithfully.
---

# Import Lamp Writing

Lamp imports writing from Markdown files: one writing per file, its details in YAML front matter, its text in Markdown as Lamp's editors write it. How you get the source there is yours to decide: read Word or Pages exports, plain Markdown, notes apps' folders, whatever the person has. Lamp's part is to check the files, say exactly what it would do with each, and import only what the person accepts.

## Workflow

1. Read [references/format.md](references/format.md): the front matter fields, the Markdown Lamp keeps, and the rules a file is checked against.
2. Look at the source before converting anything. Decide with the person which files are writing and which are working files (status notes, templates, audits, build scripts). Ask rather than guess when it is unclear.
3. Write the files to import into a folder of your own, outside Lamp's library: the bundle. Leave the person's source files as they are. Add `lamp-import.json` if the folder also holds files that are not writing.
4. Check the bundle with `plan_writing_import`, passing the folder's absolute path. Read [references/report.md](references/report.md) for what it returns. Fix every error in a file you mean to import, and read every warning: each one is something that will not come through as written.
5. Run it again until no file you mean to import is rejected.
6. Ask Lamp to import it with `import_writings`, giving the same path and a short `note` for the person: what the files are, and anything you were unsure of.
7. Tell the person it is waiting for their review in Lamp. Nothing is in the library until they tick it there; never say it has been imported.
8. Later, `writing_import_status` with the `request_id` says which files' writings they imported.

A single document goes the same way: pass its path, or pass it in `documents` with the path it would have in a folder.

## Faithful, not invented

- Change the markup, never the meaning. Do not reword, summarise, correct, modernise or "tidy" the prose. A spelling the writer used is theirs.
- Fill a field only from what the source says: a date in a filename or heading, an author named on the page, a series the folder or a numbered filename shows. Leave a field out rather than guess it; say what you were unsure of in the `note`.
- A summary is the writer's own, if the source has one. Do not write one.
- Key scriptures are the passages the writing is about, as it names them. Do not add passages it does not discuss.
- A scripture link must name the verses the prose names. Lamp rejects a link to a verse that does not exist, but cannot tell a real verse that is the wrong one.
- Keep quotations, including scripture, exactly as the source has them.

## Identity and importing again

- Each writing's identity is its `id`. Give one when the source has a stable name for the writing; otherwise leave it out and Lamp makes one from the file's path in the folder.
- Without an `id`, the same path is the same writing. Keep the bundle's layout and file names the same from one import to the next, or set `id`s yourself: a renamed or moved file becomes a new writing.
- Importing again updates writings whose files changed, leaves unchanged ones alone, and marks one the person has edited in Lamp since as a conflict, which keeps their copy unless they choose otherwise. Do not try to work around a conflict.

## Do not

- Do not write into Lamp's library folder or its database. Lamp writes the library; the import is how writing gets there.
- Do not split one source document into several writings, or join several into one, unless the person asks.
- Do not import working files, templates or tool output as writing.
