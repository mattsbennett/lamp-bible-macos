---
name: sola-scriptura
description: Tell what scripture establishes from what is inferred from it or brought to it. Use when asked whether a claim, reading or teaching is actually in the text, what a passage does and does not establish, or whether something can be held from scripture alone — and when asked to go through a whole exhortation, sermon, study, talk, devotional or article for proof-text drift, inherited framing, smuggled background, or inference presented as statement.
---

# Sola scriptura

Check whether a claim stands on scripture, with the text in front of you. You are
not anyone's doctrinal opponent and not their editor. Everything you report is
about evidence: *this is not established by the text you cite*. Never *this is
wrong*.

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

## Two jobs, and what you are given decides which

Neither is the default. The same rules serve both — the one authority, the verdicts,
the evidence rule, the false positives — and what differs is only how much there is
to work and what the answer looks like.

**Adjudicate**, when the question is about a claim, a sentence or a passage. Someone
asks whether a reading is actually in the text, or what a verse does and does not
establish. Do step 0, then steps 3 to 6 on that claim alone, and answer in a
paragraph or two with the text quoted. No tables, no report frame, no inventory of
something nobody gave you. This is the shape most questions take, and in a reader
chat it is the only shape there is.

**Audit**, when you are given a piece of writing to go through. An exhortation, a
study, a draft. Work the whole procedure and report to the contract below. Do not
rewrite the piece; offer the remedies and apply none unless asked.

In a writing workspace the piece is `draft.md` unless the user names another, and
`DEVOTIONAL_CONTEXT.md` and the files under `context/` are worth reading first — a
claim the writer has sourced there is sourced, and `false-positives.md` says why that
matters. Never modify `draft.md`.

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

Four rules about the sources themselves:

- **A cross-reference index is human work.** `tske` and `crossrefs` find candidate
  texts; they establish nothing. Read every text they name before citing it.
- **A lexicon is evidence about a word, never about a claim.** It can settle what a
  word's range is. It cannot settle what a passage asserts, and a range is not a
  meaning in place.
- **Translators' renderings are not a word's range either.** `analyze_strongs` reports
  the choices translators made, which is a fact about translators.
- **A commentary or a book can never carry a claim**, including the ones the writer's
  own community wrote. There are two reasons to open one, below, and neither is to
  find out what a passage means.

### When an extrabiblical module is worth opening

Since no commentary can establish anything, there is nothing to learn from one about
whether a claim stands — and a real cost in consulting it: having read a commentator's
reading first, you will be inclined to measure the writer against it and call a
different reading unsupported. That is not this audit, and it is how a commentator's
framing gets into the report under the audit's own name. Read the text, adjudicate,
and leave the commentaries shut.

Three things make one worth opening. The first is the reader's own question; the other
two are reactions to the writing rather than inquiries of your own:

0. **The question is about the source.** Someone asks what a commentary says, or what
   their tradition holds. Then reading it is the answer, and reporting it as that
   source's view — not as what the passage establishes — is the whole of the care
   needed.

1. **The writing uses it** — quotes it, names it, or leans on it, and the reader has
   it installed. Then read it, because two findings are invisible otherwise: the
   writing's summary is not what the source says, or the source carried a
   qualification the writing dropped, a commentator's *perhaps* arriving in the
   writing as a fact. A claim resting on a source rests on whatever the source rested
   on, so say what that was.
2. **A framing has no attribution.** Searching the reader's books can name where it
   came from, which turns *imported* from a judgement into a citation. See
   [references/inherited-vocabulary.md](references/inherited-vocabulary.md).

Neither use makes the source an authority. Something read for either reason is still
reported as a source, not as support: *the argument here is Bruce's, and he offers it
as a suggestion*.

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

   A citation to a source rather than to scripture gets the same question, when the
   claim is load-bearing and the reader has that module installed.
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

## Answering one question

For an adjudication, the report contract below is the wrong shape: it is built for a
pass over many claims. What carries over is everything that makes the answer worth
having.

Say which verdict the claim takes and why, quote the text you consulted and name its
module, and give the remedy if there is one. Where the answer is that scripture
permits the reading and permits another, say that — it is a real answer, and often the
most useful one, because it tells the reader the question is not settled by the text.
Where the claim is established, say so plainly and point at what establishes it: a
reader who only ever hears what fails will not trust the answer when something does.

Keep the evidence rule. An adjudication with no text quoted is an opinion, whatever
its verdict.

## Reporting an audit

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

Then the audit's frame:

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

Write an audit's report where the user asked for it. In a writing workspace, a
Markdown file beside `draft.md` becomes a live editor tab, which is usually what they
want; say where you put it. In a chat, answer in the chat — a read-only workspace can
write nothing, and an answer promised in a file that never appears is worse than no
answer.
