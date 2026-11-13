# A worked example

Romans 8:3, comparing the bundled English `KJVs`, `BSBs`, `ASVs`, `WEBs` and `YLT`.
The evidence below is a recorded tool result illustrating the method, not live
evidence: retrieve the current module's data for a real answer.

## The text first

`read_passage` with `TAGNT`, annotations on:

> … ὁ θεὸς τὸν ἑαυτοῦ υἱὸν πέμψας ἐν ὁμοιώματι σαρκὸς ἁμαρτίας …

| word | key | form | parsing |
|---|---|---|---|
| υἱὸν | G5207 | υἱός | Noun · Accusative · Singular · Masculine |
| πέμψας | G3992 | πέμπω | Verb · Aorist · Active · Participle · Nominative · Singular · Masculine |
| ὁμοιώματι | G3667 | ὁμοίωμα | Noun · Dative · Singular · Neuter |
| σαρκὸς | G4561 | σάρξ | Noun · Genitive · Singular · Feminine |

A deliberately wooden gloss is *in a likeness of flesh of sin*. The annotation
labels ὁμοιώματι dative and σαρκὸς genitive; it does not identify what governs or
modifies what. Any attachment of the genitives, and its semantic force, is a
construal to argue from context rather than a dependency supplied by the module.

Reading the English shows the difference at issue:

| module | quoted excerpt |
|---|---|
| KJVs | in the likeness of sinful flesh |
| BSBs | in the likeness of sinful man |

## Then the divergence, measured

If rendering practice is part of the question, `analyze_strongs` on G4561 gives
these totals and selected grouped renderings (the BSBs and TAGNT lists are not
exhaustive):

| translation | occurrences | renderings |
|---|---|---|
| KJVs | 153 | flesh (147), carnal (2), of (2), carnally (1), fleshly (1) |
| BSBs | 127 | flesh (84), body (17), bodies (3), people (3), physical (2) |
| TAGNT | 147 | σάρκα (37), σαρκὸς (30), σαρκὶ (21), σαρκί (18), σὰρξ (18) |

`ASVs`, `WEBs` and `YLT` are not in it: `list_modules` gives them
`tagsStrongs: false`, so do not request counts from them; their wording can still
be read and compared. The KJV's "of" group is not a lexical sense of σάρξ: inspect
the tagged phrases and the analysis's `variants` before interpreting an alignment.
In this recorded dataset the Berean has 43 tagged occurrences not grouped under
"flesh", while 147 of the KJV's 153 are grouped under it. That establishes a
distribution difference, not why "man" was chosen at Romans 8:3. The totals are not matched
denominators: editions and tagging can differ. Inspect comparable contexts before
suggesting a translation policy, and mark that suggestion as an inference.

## Then the range, named

`lookup_dictionary_keys` on G4561:

- TBESG (Abbott-Smith, 1922), sense 3(b): "in ethical sense, esp. in Pauline Epp.,
  of the flesh as the seat and vehicle of sinful desires", citing Rom.7:25 and
  Rom.8:4-9. It also notes the word is "in LXX chiefly for בָּשָׂר".
- Dodson Greek Lexicon: *flesh, body, human nature, materiality; kindred*
- Strong's Greek Dictionary: *carnal(-ly, + -ly minded), flesh(-ly)*

The full entry gives a sense near the one "sinful man" paraphrases, attested in
the verses just after. It does not place 8:3 itself, and it does not say whether
"man" keeps what "flesh" carries there; that is the contextual argument still to
make. Dodson's glosses could not show even the sense. Strong's rendering list is
not independent lexical proof. If the available entry does not support the needed
step, report that limit rather than declaring both alternatives inside the range
from a gloss.

## What the report says

The Greek phrase includes σαρκὸς ἁμαρτίας; σαρκὸς is tagged as the genitive singular
of σάρξ. Name the English translations compared and quote their different wording.
The recorded counts show different rendering distributions, but do not settle the
sense or construal here. The cited lexical sense does not by itself settle the
fairness of "sinful man". Identify the contextual argument still needed instead
of making the original sound more decisive than the retrieved data.

This example leaves that judgement open because the evidence stops here, not
because the skill forbids a supported judgement when the necessary contextual
argument has actually been made.
