# A worked example

Romans 8:3, where four of the five bundled translations read "sinful flesh" and one
reads "sinful man". Every number here came from the tools; the point of the example is
the order the work was done in.

## The text first

`read_passage` with `TAGNT`, annotations on:

> … ὁ θεὸς τὸν ἑαυτοῦ υἱὸν πέμψας ἐν ὁμοιώματι σαρκὸς ἁμαρτίας …

| word | key | form | parsing |
|---|---|---|---|
| υἱὸν | G5207 | υἱός | Noun · Accusative · Singular · Masculine |
| πέμψας | G3992 | πέμπω | Verb · Aorist · Active · Participle · Nominative · Singular · Masculine |
| ὁμοιώματι | G3667 | ὁμοίωμα | Noun · Dative · Singular · Neuter |
| σαρκὸς | G4561 | σάρξ | Noun · Genitive · Singular · Feminine |

So the phrase is *in a likeness of flesh of sin*: a dative noun governing two
genitives. That is the whole of what the parsing gives, and it is worth noticing what
it does **not** give — whether *of sin* describes the flesh or qualifies the likeness is
a construal, and nothing in the module decides it.

## Then the divergence, measured

`analyze_strongs` on G4561:

| translation | occurrences | renderings |
|---|---|---|
| ASVs | 136 | flesh (136) |
| WEBs | 147 | flesh (145), human (1), life (1) |
| KJVs | 153 | flesh (147), carnal (2), carnally (1), fleshly (1) |
| BSBs | 127 | flesh (84), body (17), bodies (3), people (3), physical (2) |
| TAGNT | 147 | σάρκα (37), σαρκὸς (30), σαρκὶ (21), σαρκί (18), σὰρξ (18) |

That reframes the question. The Berean's "sinful man" at Romans 8:3 is not a one-off:
it renders σάρξ as something other than "flesh" in 43 of 127 places. The ASV never
does, in 136. So this is a translation policy showing up at this verse, not a decision
made about this verse — which is a different thing to tell a reader, and checkable.

## Then the range, named

`lookup_dictionary_keys` on G4561:

- Dodson Greek Lexicon: *flesh, body*
- Strong's Greek Dictionary: *carnal(-ly, + -ly minded), flesh(-ly)*

Both renderings are inside the range, so this is a difference of sense within the
range, the second of the four kinds. Note also what the Strong's entry is: a list of
KJV renderings, which is why the lexicon proper was read as well.

## What the report says

The Greek is σαρκὸς ἁμαρτίας, a genitive singular of σάρξ. Four translations render
σάρξ with its most common English equivalent; the Berean renders it interpretively
here, as it does in a third of its occurrences. Both are inside the lexical range. The
parsing settles the form and not the construal, so whether *of sin* describes the flesh
or qualifies the likeness is a reading, and an argument resting on either should say
which translations carry it.

What the report does not say is which is right. The evidence is all above, and a reader
can weigh it.
