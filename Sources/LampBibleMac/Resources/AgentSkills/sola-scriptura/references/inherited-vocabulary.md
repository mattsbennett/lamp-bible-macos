# Inherited vocabulary

Words that carry a system. The finding is never that a word is unusual — it is that
the word is doing work the text has not done, in language the text does not use,
while sounding like the text.

## Three tests the library can answer

**Does scripture use this word, in this sense?** `search_library` with
`kinds: ["translation"]`, over whichever translations the reader has.

A phrase that returns nothing is not thereby wrong — scripture has no word for
*canon* or for *monotheism* either. It means the phrase is a summary, and a summary
must be defended from texts rather than used as one.

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

Search a distinctive phrase, not a common one: the index matches on words rather than
on the phrase, so a term built from ordinary words returns everything containing any of
them. Three or four uncommon words together are what finds a source. When a phrase turns up almost verbatim in one of the
reader's books, name it — that converts an opinion into a citation, and it is the most
useful thing this file enables. It does not make the book an authority; see the
one-authority rule in `SKILL.md`, which the reader's own books get no exception from.

## Recognising one

There is no list here, for two reasons. A list invites matching, and matching against
a vocabulary is the one thing this test is not: the same word can be a quotation in
one sentence and a smuggled conclusion in the next. And any such list is a list of
somebody's doctrine, which a skill that audits against scripture alone has no business
shipping.

**Assume nothing about the writer's tradition.** Read what the writing does. The terms
that matter in any pass are the writer's own, because those are the words they cannot
see as words.

Recognise a framing by its shape:

- **It names a mechanism where the text states an event.** Scripture says a thing
  happened, and what it accomplished; the framing says *how* it worked, in a word the
  text never uses. The tell is that the word answers a question the passage did not
  ask.
- **It bundles several claims into one noun phrase.** Unpack it into the claims it
  contains and ask for a text for each. A compound term usually holds one claim with
  support and one without, and the supported one is carrying the other.
- **It is capitalised, or used as a proper noun, for a body of teaching.** A term that
  names a position rather than describing a thing is a summary by construction.
- **It rests on an etymology or a gloss.** *The word means X, therefore…* is an
  argument about a word standing in for an argument about a text. Read a lexicon for
  range, cite the lexicon, and then make the argument from the passage.
- **It works in one translation and not the others.** See the translation test above.
- **A creed, confession or statement of faith is quoted where a text was asked for.**
  Naming it is the remedy: *our statement of faith puts it this way* is honest, and
  *scripture teaches* of the same sentence is not.
- **The writer defines it once and then uses it as evidence.** A term defined from
  texts is fine. A term defined and thereafter treated as a premise the texts no
  longer need is the framing doing the work.

## The test that settles it

**Rewrite the sentence in scripture's own vocabulary, using the words of the passages
it cites.**

If the rewrite keeps the claim, the term was shorthand and there is nothing to report.
If the rewrite loses the claim, the claim was living in the term rather than in the
text, and the writing needs one of two things: the passages that establish it, or a
mark saying it is a summary.

Shorthand is not false because it is shorthand. A community needs compressed terms and
a writer may use them. The finding is a shorthand carrying a conclusion while presented
as the language of scripture — and the remedy is usually one sentence unpacking it from
the texts.

## Weighing a reading that needs the term

The tests above are aimed at a writing in front of you. The same rewrite settles
something else: what a *reading* is worth when it cannot be stated without a word
scripture does not use.

Put the reading, not the sentence, through the rewrite. If it survives in the
vocabulary of the passages cited for it, the term was shorthand and nothing follows.
If the claim disappears the moment the term does, the term is carrying the reading,
and the texts offered for it are supporting a word rather than a claim. **That is
the weaker-attested reading**, and where scripture permits it and permits another
that can be said in scripture's own words, say which is which.

What this asks for is unpacking, not dismissal. A term that will not reduce usually
bundles several claims: separate them and ask for a text for each. Some will have
one, and that is worth saying. The finding is the ones that do not, and that the
bundle was carrying them.

Two things to keep straight, because this test is easy to run badly:

- **Look the word up, rather than matching it against a list.** A term may be absent
  from every translation the reader has, or present in one translation's English and
  absent from the rest, or present in all of them in a different sense from the one
  the claim needs — three different findings with three different remedies.
  `search_library` over the reader's translations tells you which. Your sense of
  which words sound extrabiblical does not, and two terms that feel equally
  technical routinely come back one in the text and one nowhere in it.
- **A word scripture does not use is not an error.** It is a summary, and a summary
  has to be defended from texts rather than used as one. The verdict on a reading
  that needs one is *imported*, with the term named — never *wrong*. This is not a
  gate on which words a writer may use; that gate belongs to the community whose
  wording rule it is, and `SKILL.md` keeps the two apart.

## What is not an import

Scripture's own vocabulary, in scripture's own sense, whatever has been built on it
since. A technical term the writer defines from texts before using it. A summary word
the writer marks as a summary. The judgement to make is not *is this word in the Bible*
but *is this word standing in for an argument that was never made*.
