---
name: sola-scriptura
description: Check what scripture establishes, permits, or does not support. Use for questions about a claim or passage, or to audit writing for proof-text drift, unmarked inference, and imported premises. Not a prose-editing or doctrinal-compliance review.
---

# Sola scriptura

Measure claims against scripture, not agreement with a tradition, including the
reader's own. Report what the evidence carries, not whether a doctrine is right.
The comfortable claims need the same scrutiny as the unfamiliar ones.

## Choose the job

- **One question:** adjudicate the claim or passage actually asked about. Answer
  conversationally, normally in a paragraph or two, with the relevant text quoted
  and its translation named. Do not invent a whole-writing inventory or report.
- **A piece to audit:** read the whole piece and its context, then follow
  [references/auditing-writing.md](references/auditing-writing.md). In a writing
  workspace use `draft.md` unless another file is named. Never edit the draft as
  part of an audit. In chat, report in chat; write a report only where authorised.
- **A question about a source or tradition:** read that source and attribute its
  view. This answers a different question from what scripture establishes.

## Evidence rules — for every job

1. **Text before interpretation.** Look passages up before quoting or characterising
   them; do not answer from memory. Name the module that answered. A quotation must
   be verbatim; distinguish your paraphrase from it.
2. **Scripture carries the claim.** Cross-reference indexes find candidate texts;
   read those texts before citing them. A lexicon supplies lexical evidence, not a
   doctrinal premise. A commentary, book, creed or consensus cannot establish a
   scriptural claim. Read commentaries only when the user asks about them, the
   writing uses them, or a specific unattributed framing needs tracing. Do not open
   one first to find out what a passage means: that makes its reading the frame.
3. **Separate observation, inference and attribution.** Show the further premise
   needed to move from a quotation to the claim. An alternative reading is not
   refuted because it differs from a familiar one. Where a claim is established,
   say so plainly; do not replace every assertion with a hedge.
4. **Try to defeat a finding.** Check the strongest relevant alternative text and
   whether the writer already marked the inference or source. Do not use a
   disputed *interpretation* as an agreed premise to settle the same dispute.
   Independent evidence can still be examined: expose its disputed step instead of
   excluding the passage merely because someone disputes it.
5. **The shelf is not evidence.** What the library holds or fails to hold says
   nothing about a reading's merit. Unequal source coverage belongs among the
   limits, never among the points scored for one reading.
6. **Survey before weighing.** Before saying which reading is better attested,
   identify the relevant kinds of evidence and read them for both readings. Say
   what you checked and what remains unchecked; withhold a balance that exceeds
   that coverage. Read [references/weighing-evidence.md](references/weighing-evidence.md)
   for a comparative judgement or a follow-up that challenges one.

## Research without unnecessary work

Call `list_modules` once at the start of the task; refresh if availability changes.
Use only what it lists. Reuse passages, annotations and lexicon entries already
verified in this task, including work shared with `original-languages`. Batch
nearby verses and compatible translations, not an entire library by default.

- `read_passage`: name `translation_ids` explicitly; omission returns up to three.
  Start with the cited or current translation. If a claim turns on its wording,
  compare the installed relevant English translations (`KJVs`, `BSBs`, `ASVs`,
  `WEBs`, `YLT` are bundled). Keep the appropriate original (`TAHOT` for OT,
  `TAGNT` for NT) separate from incompatible book coverage. An unsupported book
  aborts a combined request: retry only the compatible modules, not the bad batch.
- `LXX` and `Brenton` use different numbering and have no Strong's tagging. Before
  using either, read [references/septuagint.md](references/septuagint.md); do not
  add them to a same-reference comparison without checking the correspondence.
- `read_commentary` with `module_ids: ["tske"]` retrieves cross-references;
  `crossrefs` is another bundled index. Follow `nextOffset` only for relevant units.
- `search_library`: use `kinds: ["translation"]` for candidate scripture and
  `kinds: ["book"]` to trace a framing. Search results are bounded samples (default
  20, subject to the reader's cap), not proof of absence or complete inventories.
  Use alternate wording and narrower module/book ranges when relevant.
- `lookup_dictionary_keys` retrieves exact keys; prefer `bdb` for Hebrew and
  `tbesg` for Greek semantic range. Ask `bdb` with the Strong's key: each entry
  names it in `mappedFrom`, and one key can lead to several. Strong's glosses and `analyze_strongs`
  rendering counts describe tagging/rendering, not the sense in this sentence.

Verify every citation in an audit. For an uncited load-bearing claim, read the
passage's context, relevant cross-references and a targeted search; test any known
counterexample. Stop when the question is answered by the evidence, or when the
next step needs unavailable evidence. Do not repeatedly search to manufacture
certainty. State the scope of any negative conclusion: *not established by the
texts checked*, not *nowhere in scripture* on the strength of a failed search.

No translation, missing content, tool failure or truncation means **unverified**,
not Unsupported or Contrary. Quote only what was returned. Retrieve a smaller
remaining passage if `wasTruncated` is true, or report the coverage limit.

## Decide and report

Use these verdicts, not a count of agreeing translations:

| Verdict | Evidence | When it is a finding |
|---|---|---|
| Stated | The text asserts the claim | Wrong citation |
| Entailed | Valid argument from quoted premises, with no extra premise | A consequential hidden step |
| Inferred | The text permits this and another reading | The chosen reading is presented as statement |
| Imported | An external premise does work | Its dependence is unmarked or promoted to scripture |
| Unsupported | The checked evidence does not establish it | State the scope of the search |
| Contrary | The cited or governing text tells against it | Quote and explain the conflict, not the doctrine |

For a difficult entailment or cumulative claim, read
[references/verdicts.md](references/verdicts.md). Quoted premises alone do not make
an argument valid. Preserve their referents, scope and qualifications.

Do not flag scripture's own words, honest pastoral application, figures of speech,
an already hedged inference, or an accurately attributed external source merely for
being external. Context files are evidence to check, not an automatic exemption.
If attribution or a hedge is present, check any remaining substantive error rather
than reporting the same dependence again. See
[references/false-positives.md](references/false-positives.md) for borderline cases.

**No finding without evidence:** quote the claim and the consulted text, name the
gap, and offer the smallest remedy: correct the citation, expose the inference or
source, or stop resting the argument on it. Keep unverified claims in the limits.
Rank findings by **load first**, then Contrary before other verdicts within that
load. Consolidate repeated instances of one problem. Check
[references/failure-patterns.md](references/failure-patterns.md) for a full audit;
read [references/inherited-vocabulary.md](references/inherited-vocabulary.md) when
a term appears to carry an unstated premise. Language claims needing closer work
belong with `original-languages`; do not imply a handoff has been completed unless
you actually performed it.
