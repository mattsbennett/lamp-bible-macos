# Inherited vocabulary

Words that carry a system. The finding is never that a word is unusual — it is that
the word is doing work the text has not done, in language the text does not use,
while sounding like the text.

## The three tests

**Does scripture use this word, in this sense?** `search_library` with
`kinds: ["translation"]`, over whichever translations the reader has.

A phrase that returns nothing is not thereby wrong — scripture has no word for
*trinity* or for *representative sacrifice* either. It means the phrase is a summary,
and a summary must be defended from texts rather than used as one.

**Does the claim survive a change of translation?** Pass every translation in the
library to `read_passage` at once. Lamp always has `KJVs`, `BSBs`, `ASVs`, `WEBs` and
`YLT`; the reader may have more.

A claim that holds in one translation and dissolves in the rest rests on a
translator, not on the text. Romans 8:3 is the standing example: four of the five
bundled translations read *in the likeness of sinful flesh*, and the Berean reads *in
the likeness of sinful man*. An argument that turns on either word should say which
translations carry it, whichever conclusion it is heading for — the finding is the
unnamed dependence on one rendering, not the conclusion.

**Where did the framing come from?** `search_library` with `kinds: ["book"]`, over
whatever books the reader has — `list_modules` says which, and many readers will have
none, in which case this test is simply unavailable and the finding stays at
*imported* without a named source.

Search a distinctive phrase, not a common one: the index matches on words, so *sin in
the flesh* returns anything with *sin* and *flesh* in it. Three or four uncommon words
together are what finds a source. When a phrase turns up almost verbatim in one of the
reader's books, name it — that converts an opinion into a citation, and it is the most
useful thing this file enables. It does not make the book an authority; see the
one-authority rule in `SKILL.md`, which the reader's own books get no exception from.

## Framings to watch for

Examples of the mechanism, not a list to match against. **Assume nothing about the
writer's tradition** — read what the writing does, and apply the tests to whatever
tradition it comes out of. The items that matter most are always the writer's own,
because those are the words they cannot see as words, and every item below is
somebody's own.

Grouped by what is being claimed, so the competing shorthands sit side by side. Two
writers reaching for opposite summaries of one doctrine is the clearest evidence that
both are summaries.

| The question | Framings that carry an answer to it |
|---|---|
| What Christ's death did | substitution or exchange; bearing wrath, punishment or penalty in another's place; justice satisfied; a debt paid; *representative sacrifice*; *God condemned sin in the flesh* as a finished formula |
| What a human being is | the immortal soul; the soul as a separable part; *mortal nature* and *sin in the flesh* as technical terms rather than as phrases in their places; *clean flesh* and its opposite |
| What happens at death | going to heaven as the believer's hope; soul sleep; conscious eternal torment; annihilation |
| Who the adversary is | the devil as a supernatural person; the devil as a figure for sin in the flesh; *diabolos means slanderer, therefore…* as a lexical argument |
| Who Christ is | trinitarian vocabulary (*God the Son*, *co-eternal*, *second person*); pre-existence as assumed or as denied; *merely human* |
| What the kingdom is | *the church age*; the kingdom as the church; the kingdom as a literal future reign, where the writing treats either as the text's own term |
| How one is saved | *accepting Jesus into your heart*; *the Truth* as a proper noun for a body of doctrine; *sound doctrine* standing for a particular list; inherited guilt as distinct from inherited mortality |

Alongside these, one pattern belongs to no tradition in particular: a creed,
confession or statement of faith quoted where a text was asked for. Naming it is the
remedy — *our statement of faith puts it this way* is honest, and *scripture teaches*
of the same sentence is not.

Shorthand is not false because it is shorthand. A community needs compressed terms and
a writer may use them. The finding is a shorthand carrying a conclusion while presented
as the language of scripture — and the remedy is usually one sentence unpacking it from
the texts.

## What is not an import

Scripture's own vocabulary, in scripture's own sense, whatever has been built on it
since. A technical term the writer defines from texts before using it. A summary word
the writer marks as a summary. The judgement to make is not *is this word in the Bible*
but *is this word standing in for an argument that was never made*.
