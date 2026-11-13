---
name: original-languages
description: Examine Hebrew or Greek words, parsing, and translation differences, or audit a writing's original-language claims. Use for word studies, tense or stem claims, rendering comparisons, and appeals to what the original really means. Distinguish language evidence from interpretation.
---

# Reading the original

Give checkable language evidence, and mark the judgement it does not settle. A
lexicon's range is not a sense selected for a sentence; a parsing is not an
interpretation; translators' rendering counts are neither.

## Choose the job

- **A word or passage:** answer that question from the text, with its module named.
  Give only the relevant words and parsing, not a compulsory table of every word.
- **A translation difference:** compare the actual wording, lexical evidence and
  grammar. Measure rendering practice only when it helps explain the question.
- **A writing:** inventory its load-bearing language claims and follow
  [references/auditing-writing.md](references/auditing-writing.md). Do not edit the
  draft. In a writing workspace it is `draft.md` unless another is named; in chat,
  answer in chat rather than promising a file you cannot write.

## Read before explaining

1. Call `list_modules` at the start of the task. Reuse that inventory and evidence
   already verified in this task, including work done with `sola-scriptura`.
   Refresh if availability changes; never assume an installed or permitted module.
2. Read the passage before the lexicon: `read_passage` with
   `include_annotations: true`, explicitly naming `TAHOT` for the Hebrew OT or
   `TAGNT` for the Greek NT. These are the bundled Leningrad and Nestlé-Aland texts.
   Add the cited or current English translation in the same call when compatible.
   Per-word annotations give the Strong's key, dictionary form, raw morphology and
   its decoded description; one call does the verse, not one call per word.
   English annotations may span a phrase: use offsets or containment, not an exact
   single-word text match, to identify the tag for the word under discussion.
3. For a word the answer turns on, take parsing from that occurrence and quote a
   named lexicon for the range: `lookup_dictionary_keys`, for example
   `{"keys": ["G4561"], "module_ids": ["tbesg"]}`. Prefer `bdb` for Hebrew and
   `tbesg` for Greek: prefer their fuller definitions and usage citations to a
   short gloss. If only a brief gloss is available, state that limit.
   Ask `bdb` with the Strong's key. Its entries keep BDB's own numbers, so each
   comes back with `mappedFrom` naming the key you asked, and one key often leads
   to more than one entry, such as two words spelled alike: choose by the passage
   and say which. `tbesg` is mostly Abbott-Smith (1922), and BDB is from 1906;
   give the date when a claim leans on the entry. `dodson_greek` gives short
   glosses only. `strongs_hebrew` and `strongs_greek` are also bundled, but their
   glosses index renderings and must not stand in for a semantic argument.
4. For a rendering-dependent claim, compare the relevant installed English
   translations. Bundled candidates are `KJVs`, `BSBs`, `ASVs`, `WEBs`, `YLT`.
   Name the ones actually compared. Do not request every translation regardless of
   language, book coverage or versification. One unsupported book fails a combined
   call; remove that module and retry the compatible selection.
5. If usage or rendering distribution matters, call `analyze_strongs` with `key`
   and explicit relevant `translation_ids`; narrow `range` when the claim is local.
   Ask only for translations `list_modules` marks `tagsStrongs: true`; of the
   bundled English that is `KJVs` and `BSBs`. A translation without tags is left
   out of the result without comment, so report the rows that came back, not the
   ones requested.
   Attribute every count to its translation and tagging. Unequal totals can reflect
   tagging or textual differences, not translator intent. A distribution can prompt
   a hypothesis about policy; it does not establish why this verse was rendered so.
6. Answer with the evidence you actually retrieved and the remaining interpretive
   step. Stop once that answers the question. Do not run corpus counts for a simple
   parsing question or read unrelated lexicon entries to make an answer look fuller.

For morphology-dependent claims read [references/morphology.md](references/morphology.md).
For a substantive translation comparison read
[references/translator-choices.md](references/translator-choices.md).

## Research limits that change the answer

- **No textual apparatus.** Missing words or verses in a module do not by themselves
  prove an editorial omission, a manuscript reading, or its cause. Establish what
  was returned, check the reference and coverage, then report what remains
  unverified. Do not infer a variant merely from absence in `TAGNT`.
- **No syntax beyond the word.** Parsing labels forms, not phrase attachment,
  dependencies or discourse function. Describe word order directly, and mark an
  argument about what it does as a reading. Dictionary forms and parsing are the
  dataset's analyses, not a substitute for evidence of an alternative analysis.
- **No Hebrew morphology in `KJVs`.** Its numeric `TH` codes are not decoded;
  use `TAHOT`. Hebrew/Aramaic morphemes can be joined with `/`; the decoded parsing
  belongs to the morpheme aligned with the key, not necessarily the content word.
- **The Septuagint is a translation.** `LXX` and Brenton's English `Brenton` are
  untagged and differently numbered. Before comparing their passages or using a
  lexicon's `septuagintHebrew` correspondence, read
  [references/septuagint.md](references/septuagint.md). They are not extra tagged
  witnesses to the Hebrew or automatic same-reference comparisons.
- **Searches are bounded.** `search_library` accepts `strongs_key` without a text
  query, for example `{"strongs_key": "G4561", "kinds": ["translation"],
  "module_ids": ["TAGNT"], "range": "Romans", "limit": 50}`. Results default to
  20 and the configured cap may be lower than requested; there is no search
  pagination. Do not call them every occurrence. Use `analyze_strongs` for totals;
  its references are sampled too (`referencesOmitted`), and its rendering, form and
  parsing lists are capped at 20. A short list is not proof of absence.
- **Truncation is not coverage.** If `read_passage` returns `wasTruncated`, retrieve
  smaller remaining ranges before characterising the whole. `read_study_material`
  gives a translation's footnotes; `read_commentary` pages with `nextOffset`.

If an original, lexicon or necessary analysis is unavailable, say **unverifiable
here** and identify what evidence is missing. Do not fill gaps from memory or
claim that an unavailable word has been disproved.

## Guard against overreach

Read [references/fallacies.md](references/fallacies.md) before a word study or an
audit. For a direct parsing answer, these are the essential boundaries:

- Etymology and word parts do not establish a sense in context.
- Do not pour every lexicon sense into one occurrence.
- Tense is not a timeline, a Hebrew stem is not a definition, and grammatical gender
  is not a claim about people. A genitive does not specify its semantic relation.
- English agreement or difference is not original-language identity or difference:
  check the actual words and keys. Rendering frequency does not settle meaning,
  translation quality, doctrinal bias, or authorial intent.
- Where the data permits alternatives, say so. For "is this rendering fair?", explain
  which constraints it satisfies and what remains interpretive; do not declare a
  translation right or wrong from a count or a gloss.

Quote the original and relevant rendering, name the modules, and distinguish form,
lexical possibilities and contextual judgement. Counts are optional evidence, not
an obligatory answer format. [references/worked-example.md](references/worked-example.md)
shows how to keep those steps separate without making the evidence sound decisive.
