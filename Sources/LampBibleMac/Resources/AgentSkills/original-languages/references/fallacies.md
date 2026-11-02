# What goes wrong in a word study

Every one of these makes the original sound decisive when it is not. They are easy to
commit by accident, and they are what a reader cannot check.

## The root fallacy

Taking a word's meaning from its parts or its etymology. The standard example is
reading ἐκκλησία as "the called-out ones" from ἐκ and καλέω, when in use it means an
assembly. Hebrew roots invite this especially, because the system is so visible.

**Test:** does the claim rest on how the word is built, or on how it is used?

## Strong's as a definition

Strong's glosses are a 19th-century index of how the KJV rendered words, not a lexicon.
`strongs_greek` on σάρξ answers "carnal(-ly, + -ly minded), flesh(-ly)" — a list of KJV
renderings, not a semantic range. Read a lexicon for range: `bdb` for Hebrew,
`dodson_greek` for Greek. And name whichever you used, because they differ.

## Illegitimate totality transfer

Collecting every sense a word has anywhere and pouring them all into one verse. A word
in a sentence carries one sense. The range tells you what was available; the sentence
chose.

**Test:** would the sentence still work if only this sense were available?

## Renderings read as meaning

A rendering count tells you what translators did. It is strong evidence about
translators and weak evidence about the word, and it is not the word's range. The two
get confused constantly because `analyze_strongs` reports them so clearly.

## Counting as meaning

Frequency is not significance. That a word appears more in one book than chance would
give is a fact about distribution; what it means is a reading. `analyze_strongs`
reports "more" and "fewer" against what chance would give for that book's size — which
is the right comparison, and still only a prompt to look.

## A distinction with no original behind it

Two English words translating one original word, read as a distinction the original
made. Also its mirror: one English word for two different originals, read as a
connection. Check the keys before building on either.

The best-known case is ἀγαπάω and φιλέω in John 21, preached as a contrast — where the
same chapter's other pairs are interchanged freely. The way to check is to read every
occurrence, which `search_library` with `strongs_key` will give you.

## Semantic anachronism

Reading a later meaning back into an earlier text — most often an English word's modern
sense, sometimes a technical sense a word acquired after the text was written. δύναμις
is not "dynamite".

## A parsing doing a lexicon's work

Treating a fact about form as a fact about sense: the aorist "meaning" once for all, a
stem "meaning" a particular nuance, a gender "meaning" something about people. See
`morphology.md` for what a parsing settles.

## Certainty the evidence does not carry

The quiet one, and the most common. Everything above can be avoided and a report can
still imply that the original settles a question it leaves open. If the honest answer
is that the Greek or Hebrew permits both readings, that is the answer, and it is a
useful one — it tells a reader the question is not decided by the language.
