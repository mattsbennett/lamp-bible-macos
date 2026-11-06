# What a parsing says

Two code systems, read out for you. You rarely need the raw code, but you do need to
know which fields exist, because a field that is absent is not a field that is unknown
— it is one the form does not carry.

## Greek

Robinson's codes, as `TAGNT` and the tagged English translations use them:
part of speech, then tense, voice and mood for a verb, or case, number and gender for
anything declined.

`Verb · Aorist · Active · Participle · Nominative · Singular · Masculine` is a
participle, so it has a case; `Verb · Aorist · Active · Indicative · Third · Singular`
is finite, so it has a person instead. A second aorist reads as an aorist: "second"
describes how the stem is formed, not a tense of its own.

## Hebrew and Aramaic

STEPBible's codes, which `TAHOT` uses. A verb carries a **stem** as well as a form, and
the stem is the thing with no Greek equivalent:

`Verb · Qal · Perfect · Third · Singular · Masculine`

The stem — Qal, Niphal, Piel, Pual, Hiphil, Hophal, Hithpael and the Aramaic ones —
says how the action is shaped: simple, passive, intensive or causative. It is part of
the form, not of the lexeme, so the same dictionary word appears in several stems and
means correspondingly different things. That is worth reporting whenever it is the
point: `H1254`, *bara*, stands in Qal 39 times, Niphal 10, Piel 5 and Hiphil once.

A noun or adjective carries a **state** — absolute, construct or definite — where
Greek carries a case. Construct is the one to watch: it binds a noun to the one after
it, which is how Hebrew says *the ark of the covenant*.

A word can be several morphemes, written with `/`: `Hc/Vqw3ms` is a conjunction joined
to a verb, `HNcmsc/Sp3ms` a construct noun with a pronominal suffix. The parsing you
are given is for the one morpheme the Strong's key names, which is usually the noun or
the verb but need not be: `HC/To` is אֵת with a conjunction on it, and parses as the
object marker, not as a conjunction. Where the word is nothing but grammar the key can
even name a suffix. When a prefix or a suffix is itself the point, the raw code is
there to read, and it is the only place the prefix appears at all — so a claim resting
on the presence of a waw or an article is read off the code, not off the parsing.

## What a parsing settles, and what it does not

**It reports the dataset's analysis of the form.** Whether a verb is perfect or
participle, whether a noun is plural, whether a pronoun is second person. These
can be checked against the annotations rather than asserted from recall. They do
not expose alternative parsings or establish a clause's dependencies.

**It does not settle the meaning.** The commonest overreach in the whole subject is to
take a fact about form and present it as a fact about sense:

- A tense is not a timeline. Greek aspect and Hebrew form resist the mapping English
  speakers reach for, and "the aorist means once for all" is the best-known example of
  a claim the form does not carry.
- A stem is not a definition. Qal and Piel shape the action; they do not tell you which
  of a word's senses is in play.
- A construct chain is a grammatical bond, not a meaning. *Flesh of sin* is a genitive
  in Greek and a construct in Hebrew, and what the relation asserts is a question for
  the sentence.
- A gender is grammatical. A feminine noun is not thereby about a woman.

So report the parsing as the parsing, and when a reading depends on it, say which step
is the form and which is the inference. The skill that audits writing for this is
`sola-scriptura`, and its lexical-overreach pattern is the same mistake seen from the
other side.
