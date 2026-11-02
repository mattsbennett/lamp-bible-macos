---
name: sola-scriptura
description: Audit writing for conclusions, claims and teachings that cannot be established from scripture alone. Use when asked to check an exhortation, sermon, study, talk, devotional, article or doctrinal prose for proof-text drift, inherited framing, smuggled background, or inference presented as statement — or whether one particular claim is actually in the text.
---

# Sola scriptura audit

Check whether the writing's claims stand on scripture, with the text in front of
you. You are not the writer's doctrinal opponent and not their editor. Every
finding is about evidence: *this is not established by the text you cite*. Never
*this is wrong*.

Audit the complete `draft.md` in the current workspace unless the user names
something else to audit. Read `DEVOTIONAL_CONTEXT.md` and the files under
`context/` when they are there — a claim the writer has sourced in their own
context files is sourced, and `false-positives.md` says why that matters. Do not
modify `draft.md`: this skill reports, and applies nothing unless asked.

## The one authority

The audit measures claims against the text of scripture and nothing else. Not
against a creed, a confession or a statement of faith; not against any commentary,
lexicon or book in the library, including the ones the writer's own community
wrote; not against what the writer has held before; not against scholarly
consensus.

A claim that agrees with the writer's tradition is not thereby established. A claim
that cuts against it is not thereby refuted. The whole value of this audit is that
it will tell the writer when something they believe is not in the text they cite,
and nothing else they have will do that. So flag the comfortable claims too — those
are the findings worth having.

Where a community has a rule about *wording* — which terms its writing uses for a
doctrine — that is a separate gate from this one. Note an intersection in a clause
and keep the two apart.

## Two jobs

**Audit (default).** Work the procedure below and report. Do not rewrite the piece.
Offer the remedies; apply none unless asked.

**Adjudicate.** The user asks about one claim or sentence — "is that actually in the
text?" Skip the inventory, do steps 0, 3, 4, 5 and 6 on that claim alone, and answer
in a paragraph with the text quoted.

## Step 0 — find out what the library holds

Nothing in this audit may be answered from memory. Verse wording, who said what,
what a Hebrew or Greek word covers, whether a phrase occurs anywhere — all of it
gets looked up, every time, including the verses you are sure of. Your recall of
scripture is good enough to be dangerous and not good enough to audit with.

So start with `list_modules`, because what you can check depends on what this reader
has. **Only these come with Lamp and can be relied on:**

- **Translations** — `KJVs`, `BSBs`, `ASVs`, `WEBs`, `YLT`. All five carry Strong's
  numbers.
- **Cross-reference indexes** — `tske`, the Treasury of Scripture Knowledge
  (Enhanced), whose references are grouped under the catchword each one attaches to,
  so it shows *which phrase* in a verse an index thought needed support; and
  `crossrefs`, a flat second index.
- **Lexicons** — `bdb` (Brown-Driver-Briggs), `strongs_hebrew`, `strongs_greek`,
  `dodson_greek`.

Everything else in the list is the reader's own: other translations, commentaries,
dictionaries and books. Use what is there, name it when you cite it, and never
assume a particular module exists — a reader may have no commentary at all, and the
audit still works, because none of them can establish anything anyway.

If `list_modules` shows no translation, say so at the top of the report and audit
only what reasoning alone reaches — structure, hedging, self-contradiction — and say
that is all you did.

### The tools, and what each is for

| Tool | Use |
|---|---|
| `read_passage` | Verbatim text. Pass `translation_ids` with **every** translation you mean to compare: it returns three by default, which is how a claim resting on one wording stays hidden. `include_annotations: true` adds Strong's keys as `{kind: "strongs", strongs: "H959", text: "…"}` — the `text` can span a phrase, so match by containment. |
| `read_commentary` | Cross-references, with `module_ids: ["tske"]`. The candidate texts a claim would need. |
| `search_library` | Whether scripture says a thing anywhere, with `kinds: ["translation"]`. Also provenance, with `kinds: ["book"]`. |
| `lookup_dictionary_keys` | A word's range, from a Strong's key: `{"keys": ["H959"]}`. |
| `analyze_strongs` | How one key is used across the translations that tag it. |
| `read_study_material` | The notes, footnotes and highlights on a verse. |

Three rules about the sources themselves:

- **A cross-reference index is human work.** `tske` and `crossrefs` find candidate
  texts; they establish nothing. Read every text they name before citing it.
- **Commentaries and books are external sources**, including the ones the writer's
  community wrote. They can show where a framing came from. They can never carry a
  claim.
- **Translators' renderings are not a word's range.** `analyze_strongs` reports the
  choices translators made. For range read a lexicon, and then cite the lexicon.

## Procedure

1. **Read the whole piece once.** Write its thesis in one sentence, then the chain
   of claims that carries the thesis. You cannot judge what a claim is holding up
   until you can see the chain.
2. **Inventory the testable claims.** Every assertion doing doctrinal or factual
   work — not every sentence. Read [references/false-positives.md](references/false-positives.md)
   first and leave out what belongs there.
3. **Verify every citation in the piece.** Look up each reference verbatim. Then ask
   the only question that matters: *does this text carry the weight the claim puts on
   it?* Proof-text drift is the most common finding by a wide margin.
4. **For each uncited load-bearing claim, find the text it would need.** Cross-
   reference the passage under discussion, and search for the phrase. Look up what
   you find. If nothing carries it, that is the finding.
5. **Adjudicate** each claim as verdict × load, per [references/verdicts.md](references/verdicts.md).
   The catalog of what goes wrong is [references/failure-patterns.md](references/failure-patterns.md).
6. **Try to defeat each finding before reporting it.** Is there another text that
   does carry the claim — did you check it? Did the writer already mark it as an
   inference, so there is nothing to flag? Is the word you called inherited one
   scripture itself uses? A finding that does not survive this pass does not go in
   the report. Findings dropped here are worth one line at the end.

   Run this step evenly, because it is where the audit most easily goes soft. A
   claim the writing takes for granted feels defended when it is only familiar, and
   this is the one step that lets you talk a finding out of existence. A finding
   survives or falls on whether a text carries the claim, and on nothing about how
   settled the claim sounds or whose position it is.
7. **Report** to the contract below. [references/worked-example.md](references/worked-example.md)
   shows one finding and two non-findings in the register to use.

## Reporting

Rank by load, not by how wrong something is. A load-bearing inference is a worse
problem than a decorative import, and a forty-item nitpick list is worse than
useless because it buries the two findings that matter.

- Every load-bearing finding gets its own entry.
- Supporting findings get an entry when they change what a reader would conclude.
- Decorative ones go in a single closing list, one line each, no ceremony.

**No finding without a quotation.** If you cannot show the text that fails to carry
the claim, you have no finding — you have a suspicion, and it stays out. This is the
rule that keeps the audit honest, and the one you will be tempted to skip.

Each entry carries four things and stops:

1. The sentence from the writing, quoted.
2. The text consulted, quoted verbatim, named with the module it came from.
3. The gap, in a sentence: what the claim needs that the text does not give.
4. The smallest remedy that makes it honest — one of: **cite the text that does
   carry it**, **mark it as inference**, or **drop the load** (keep the sentence,
   stop the argument resting on it).

Then the report's frame:

```
# <piece> — sola scriptura audit

<n> claims inventoried, <n> verified against <the modules that answered>.
<One sentence on the piece's thesis.>

| Claim | Verdict | Load |
|---|---|---|

## Findings
<entries, heaviest load first>

## Minor
<one-liners>

## What this pass did not do
<the limits, plainly>
```

That last section is not a disclaimer, it is part of the finding. Name what you
could not check, which claims rest on a text no available module carried, and what a
second pass should look at. An audit that hides its own gaps is the thing it was
written to catch.

Write the report where the user asked for it. In a workspace, a Markdown file beside
`draft.md` becomes a live editor tab, which is usually what they want; say where you
put it.
