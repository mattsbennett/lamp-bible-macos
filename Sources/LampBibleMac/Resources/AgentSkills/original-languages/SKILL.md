---
name: original-languages
description: Read the Hebrew or Greek behind an English verse, show where a translation reflects a translator's decision rather than the text, and audit a writing's claims about the original. Use when asked what a word means in the original, what a verb's tense or stem is, why translations differ at a verse, whether a rendering is fair, for a word study, or to check whether an exhortation, study or article's appeals to the Greek or Hebrew hold up.
---

# Reading the original

Two jobs, and the honest answer to a great many questions is the second one.

**Read the text.** What the Hebrew or Greek actually says at a passage: the words, in
order, each with its dictionary form and its parsing.

**Show where the English is a decision.** Where the translations differ, what each
chose, and whether the difference is a translator's judgement or a difference in the
text. This is usually what someone is really asking, and it can be measured rather
than asserted.

**Audit a writing's claims about the original.** The third job, and in a writing
workspace usually the one being asked for. See **Auditing a writing** below.

What you are given decides which: a passage, a word, or a piece of writing. The
evidence and the care are the same in all three.

What this skill will not do is tell anyone what a passage means. It reports the form
of the words and the range of their senses, and a sense in place is chosen by the
sentence and the argument around it, not by a lexicon. Where a question needs that
judgement, give the evidence and say whose judgement the rest is.

## What the library has

`list_modules` first, because what you can check depends on what this reader has. Only
these come with Lamp:

- **`TAHOT`** — the Hebrew Old Testament, Leningrad text, 23,259 verses.
- **`TAGNT`** — the Greek New Testament, Nestlé-Aland text, 7,918 verses.
- **`LXX`** — Brenton's Greek Septuagint, the Greek Old Testament, 38 books, and
  **`Brenton`**, his English of it. Untagged: no Strong's keys and no morphology, so
  `analyze_strongs` and a `strongs_key` search reach neither, and
  `include_annotations` returns only the words Brenton supplied. See "The Septuagint"
  below.
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

## The Septuagint, and what it can show

`LXX` is the oldest rendering of the Hebrew there is. Reading it beside `TAHOT` is the
same measurement as reading the Berean beside the ASV — a translator's choice, made
before Christ rather than this century. Three uses, and one trap.

- **The Greek word the translators chose shows how they read the Hebrew.** It is
  evidence about them, not about the Hebrew word's range, which comes from a lexicon.
  Untagged, so this comparison is by hand: read the verse in both, and say which word
  stands where.
- **An Old Testament quotation in the New often follows the Septuagint's wording.**
  Where a writing leans on the wording of a quotation, reading `TAGNT`, `LXX` and
  `TAHOT` at that verse is what says whether the point is in the Hebrew, in the Greek
  rendering, or in the writer's own adjustment of it.
- **`Brenton` marks what he supplied and says what he left behind.**
  `include_annotations: true` returns the words he added as `{kind: "added"}`, and
  `read_study_material` gives his footnotes, which give the literal Greek where he
  rendered freely. That is a translator explaining himself, which is the evidence this
  skill is made of.
- **Neither is numbered as the English is, and nothing converts it.** The Psalms run
  one lower through most of the book, but not by a constant offset — English 9 and 10
  are their single 9, English 114 and 115 their single 113, their 114 and 115 are both
  English 116, English 147 is their 146 and 147, and 148 to 150 agree again. A psalm's
  title is their verse 1, so the verses shift too: English Psalm 22:1 is `LXX` 21:2.
  There are 151 psalms. And there is no Nehemiah,
  which the Septuagint numbers inside Ezra as chapters 11–23. `read_passage` labels
  what it returns with the reference you asked for, so pass the Septuagint's own
  number and check the opening words against an English translation before citing it.

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

## Auditing a writing

Someone hands you an exhortation, a study or a draft and asks whether its claims about
the original hold up. This is worth doing well, because these are the claims a writer
cannot check for themselves and a hearer takes on trust: *the Greek here really means*
is load-bearing and unverifiable from the pew.

In a writing workspace the piece is `draft.md` unless another is named, and the report
goes in a Markdown file beside it, which becomes a live editor tab. Never modify
`draft.md`.

**Inventory the claims that rest on the Hebrew or Greek.** Not every mention of a word
— the ones doing work:

- a word's meaning, or what it "really" means
- a tense, aspect, stem, voice or mood, and what is drawn from it
- an etymology, or a meaning taken from a word's parts
- a distinction between two English words said to be in the original, or a connection
  said to be there because the English matches
- an appeal to what a translation says, or to a translator's bias
- a count: how often a word appears, where, or with what
- a claim about word order, syntax or construction

**Work each one as you would work it as a question**, then give it a verdict. These are
the verdicts for a language claim, and they are not `sola-scriptura`'s — that skill
asks whether scripture establishes a claim, this one asks whether the language data
carries it:

- **Carried** — the parsing, the lexicon or the counts show it. Say which.
- **Permitted** — the data allows it and allows otherwise. A reading, and the writing
  should mark it as one.
- **Not carried** — the data does not show it. Either it needs support the language
  cannot give, or it needs dropping.
- **Overreach** — a fact about form presented as a fact about sense, or one of the
  named fallacies. `references/fallacies.md` has them; name the one.
- **Translation-dependent** — true of one translation's rendering and presented as true
  of the word. Give the counts.
- **Unverifiable here** — it needs an apparatus, a syntax analysis or a module that is
  not installed. Say so plainly rather than reaching for an answer; see the limits
  below.

**Report per claim**, quoting the writing's sentence and then the evidence, which is
`sola-scriptura`'s contract and worth following so a writer gets one shape of answer
rather than two. Quote no verdict without the data behind it. Rank by what the piece
rests on: a decorative etymology that carries nothing is worth a line, a conclusion
standing on a tense is worth the whole treatment. Close with what you could not check.

Where a claim fails for a reason that is not about language — a verse cited for
something it does not say — that is `sola-scriptura`'s work, and saying so is better
than half-doing it here. The two audits pair: it flags a claim about the original and
hands it over, and this is where it lands.

## What is not here, and must not be implied

- **No tagged text but these two.** `TAHOT` is Leningrad and `TAGNT` is
  Nestlé-Aland. Variants, Qere readings and Textus-Receptus-only words are in the
  upstream datasets, not in these modules, so a verse absent from `TAGNT` is absent
  because the critical text omits it, which is itself worth saying. `LXX` is a third
  running text, with no tagging at all: no key, no parsing, and no lexicon for the
  words the Septuagint has and the New Testament does not.
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
