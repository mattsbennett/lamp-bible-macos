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
translator, not on the text. Romans 8:3 is the standing example, and it cuts both
ways: four of the five bundled translations read *in the likeness of sinful flesh*,
and the Berean reads *in the likeness of sinful man*. An argument built on *flesh* is
well founded, and should still say which translations carry it rather than treating
one rendering as the text itself.

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

These are examples of the mechanism, not a list to match against. Apply the tests to
whatever tradition the writing comes out of, including the writer's own — especially
the writer's own, because those are the words they cannot see as words.

Common in wider Christian writing: substitution and exchange language; Christ bearing
wrath or punishment in another's place; justice satisfied; a debt paid; the immortal
soul; dying and going to heaven as the believer's hope; the devil as a supernatural
person; trinitarian vocabulary (*God the Son*, *co-eternal*, *second person*); *the
church age*; inherited guilt as distinct from inherited mortality; *accepting Jesus
into your heart*; hell as conscious eternal torment.

Common in Christadelphian writing: *sin in the flesh* as a technical term rather than
Romans 8:3's phrase in its place; *the Truth* as a proper noun for a body of doctrine;
*the devil is sin in the flesh* stated as the text's own equation; *clean flesh* and
its opposite; *diabolos means slanderer, therefore…* as a lexical argument; *the
Statement of Faith says* offered where a text was asked for; and *representative
sacrifice* itself, which is a summary needing to be shown from Romans 3, Romans 8 and
Colossians 2 rather than asserted.

Shorthand is not false because it is shorthand. A community needs compressed terms and
a writer may use them. The finding is a shorthand carrying a conclusion while presented
as the language of scripture — and the remedy is usually one sentence unpacking it from
the texts.

## What is not an import

Scripture's own vocabulary, in scripture's own sense, whatever has been built on it
since. A technical term the writer defines from texts before using it. A summary word
the writer marks as a summary. The judgement to make is not *is this word in the Bible*
but *is this word standing in for an argument that was never made*.
