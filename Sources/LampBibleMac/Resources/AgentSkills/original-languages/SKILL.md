---
name: original-languages
description: Read the Hebrew or Greek behind an English verse, word by word, and show where a translation reflects a translator's decision rather than the text. Use when asked what a word means in the original, what a verb's tense or stem is, why translations differ at a verse, whether a rendering is fair, or for a word study.
---

# Reading the original

Two jobs, and the honest answer to a great many questions is the second one.

**Read the text.** What the Hebrew or Greek actually says at a passage: the words, in
order, each with its dictionary form and its parsing.

**Show where the English is a decision.** Where the translations differ, what each
chose, and whether the difference is a translator's judgement or a difference in the
text. This is usually what someone is really asking, and it can be measured rather
than asserted.

Both are answers to a question about a passage, and both end the same way — the
evidence, then what of it is a reading. There is no second output shape to choose
between, so unlike `sola-scriptura` this skill has no audit mode and needs none.

What it does have is a third thing to do when you are handed a piece of writing
rather than a question: see **Going through a piece of writing** below.

What this skill will not do is tell anyone what a passage means. It reports the form
of the words and the range of their senses, and a sense in place is chosen by the
sentence and the argument around it, not by a lexicon. Where a question needs that
judgement, give the evidence and say whose judgement the rest is.

## What the library has

`list_modules` first, because what you can check depends on what this reader has. Only
these come with Lamp:

- **`TAHOT`** — the Hebrew Old Testament, Leningrad text, 23,259 verses.
- **`TAGNT`** — the Greek New Testament, Nestlé-Aland text, 7,918 verses.
- **Five English translations with Strong's numbers** — `KJVs`, `BSBs`, `ASVs`,
  `WEBs`, `YLT`.
- **Lexicons** — `bdb` (Brown-Driver-Briggs), `strongs_hebrew`, `strongs_greek`,
  `dodson_greek`.

Anything else listed is the reader's own, and a reader may have none of it. Never
assume a particular module; name what answered.

## Reading a passage

`read_passage` with `translation_ids: ["TAHOT"]` or `["TAGNT"]` and
`include_annotations: true` gives the original text and, for every word, its Strong's
key, its dictionary form, its morphology code and that code **read out**:

```
σαρκός     G4561  σάρξ   Noun · Genitive · Singular · Feminine
πέμψας     G3992  πέμπω  Verb · Aorist · Active · Participle · Nominative · Singular · Masculine
בָּרָא       H1254  בָּרָא   Verb · Qal · Perfect · Third · Singular · Masculine
```

So reading a verse takes one call, not one per word. Ask for the English alongside by
naming more translations in the same call: the original and the renderings together is
what most questions need.

[references/morphology.md](references/morphology.md) says what each field means in
each language, and — the part that matters most — what a parsing does and does not
settle.

## Showing where the English is a decision

`analyze_strongs` with a `key` reports, for every translation that tags that word, how
its translators rendered it and how often. That turns "this translation is
interpretive here" from an opinion into a count:

```
G4561 σάρξ
  ASVs  136 occurrences:  flesh (136)
  KJVs  153:              flesh (147), carnal (2), carnally (1), fleshly (1)
  BSBs  127:              flesh (84), body (17), bodies (3), people (3), physical (2)
```

Read against TAGNT's own entry, which lists the Greek forms rather than renderings,
since there is nothing to render.

The method, and the four questions to ask of a divergence, are in
[references/translator-choices.md](references/translator-choices.md).

## The other tools

| Tool | Use |
|---|---|
| `lookup_dictionary_keys` | A word's range, from its key: `{"keys": ["G4561"]}`. Quote the lexicon and name it. |
| `search_library` | Every verse tagged with a key, using `strongs_key` rather than `query`. The way to see a word across a corpus. |
| `read_study_material` | The notes and footnotes on one verse in one translation, where a translator explained themselves. |

## How to work

1. **Read the passage in the original first**, before any lexicon. The sentence is
   what decides a sense, and a word study begun at the lexicon tends to end there.
2. **Read the same passage in every translation the library has.** Where they agree
   there is usually nothing to explain; where they differ is the question.
3. **For a word that matters, get its parsing and its range** — the parsing from the
   passage, the range from a lexicon, named.
4. **Where the translations differ, measure it.** `analyze_strongs` on that key, and
   ask whether this translation is doing here what it does everywhere.
5. **Check the fallacies** in [references/fallacies.md](references/fallacies.md) before
   writing. Every one of them is a way of making the original sound decisive when it is
   not, and they are easy to commit by accident.
6. **Report the evidence and mark the judgement.** Quote the text, name the modules,
   give the counts. Then say plainly which part is a reading rather than a datum.

[references/worked-example.md](references/worked-example.md) works Romans 8:3 through,
with the measurements.

## Going through a piece of writing

Someone may give you an exhortation or a study and ask whether its claims about the
original hold up. That is not a different method, only longer: find the claims
that rest on the Hebrew or Greek — a word's meaning, a tense, a stem, an etymology, a
distinction between two English words, an appeal to what a translation "really" says —
and work each one the way you would work it as a question.

Two things to carry over rather than invent. Report per claim, quoting the writing's
sentence and then the evidence, which is `sola-scriptura`'s contract and worth
following here so a writer gets one shape of answer rather than two. And rank by what
the piece rests on: a decorative etymology that carries nothing is worth a line, and a
conclusion standing on a tense is worth the whole treatment.

Where a claim fails for a reason that is not about language — a verse cited for
something it does not say — that is the other skill's work, and saying so is better
than half-doing it.

## What is not here, and must not be implied

- **No running text but these two.** `TAHOT` is Leningrad and `TAGNT` is
  Nestlé-Aland. Variants, Qere readings and Textus-Receptus-only words are in the
  upstream datasets, not in these modules, so a verse absent from `TAGNT` is absent
  because the critical text omits it, which is itself worth saying.
- **No textual apparatus.** You cannot say which manuscripts read what.
- **No syntax beyond the word.** Every word carries its own parsing; nothing marks
  clauses, phrases or dependencies. Word order is visible in the text and may be
  described; a claim about what the order *does* is a reading.
- **No morphology for the Hebrew in `KJVs`.** It tags with CrossWire's numeric `TH`
  codes, which Lamp does not read. For Hebrew parsing, use `TAHOT`.
- **Renderings are translators' choices, not a word's range.** For the range, read a
  lexicon. The two are different evidence and answer different questions.
- **A dictionary form is STEPBible's**, and a lexicon's headword may differ.

Where a question needs something on this list, say so. A plausible answer assembled
without the evidence is the one thing this skill exists to prevent.
