# Where the English is a decision

A reader asking "why do the translations differ here?" is asking something answerable.
Most differences are one of four things, and telling them apart is the work.

## Measure first

`analyze_strongs` on the word's key gives every tagged translation's renderings with
counts. That answers the question that opinion cannot: **is this translation doing
here what it does everywhere?**

```
G4561 σάρξ
  ASVs  136 occurrences:  flesh (136)
  BSBs  127:              flesh (84), body (17), bodies (3), people (3), physical (2)
```

A translation tagged with the same rendering 136 times is more uniform in this
dataset than one tagged with several renderings. That describes the data, not the
translator's intent, the fairness of a particular rendering, or a policy already
proved. Check comparable occurrences before proposing a policy as an explanation.

`TAGNT`'s own row lists Greek forms rather than renderings, there being nothing to
render. It is a comparison corpus, not automatically the exact text every English
translation follows. Unequal totals can arise from text, tagging, or alignment.
Attribute totals to the module and do not treat them as matched denominators.

## The four kinds of difference

**A different text.** The translations are not rendering the same words. This is the
one to investigate first, because it can look like a translation difference.
Absence from `TAGNT` alone does not establish a variant or its cause. Check the
reference, book coverage and returned text; without an apparatus or an explicit
translator's note, leave the textual explanation unverified.

**A different sense, within the range.** Both renderings are available for the word and
the translators chose differently. Give the lexicon's range, name the lexicon, and say
what each chose. This is the commonest kind and the least interesting to dramatise.

**A different reading of the grammar.** The same words parsed the same way can still be
construed differently — which noun a genitive attaches to, whether a participle is
attendant or causal. The parsing is in the module; the construal is not, and cannot be
settled from it.

**An interpretive rendering.** The English says something the word does not, or says
less than it does, to make a sentence read. Often marked in a translation's own
footnotes, which `read_study_material` will show.

## Four questions to ask of any divergence

1. **Is the text the same?** Read the available original. Report a demonstrated
   difference, but do not infer what unavailable editions or manuscripts contain.
2. **Is each rendering inside the word's range?** Read a lexicon and quote it.
3. **Does the parsing allow both?** Read it. Sometimes a rendering requires a form the
   word does not have, which settles it.
4. **How does this rendering compare with the translation's tagged practice?**
   Measure when relevant, then inspect comparable contexts. A rare rendering may
   be contextually justified; a common one may still need explanation here.

## How to report it

Give the original, the renderings side by side, the lexical range with its source, and
the counts. Then say which of the four kinds the difference is, and if the answer needs
a judgement about the sentence, say so and attribute it.

For a question about fairness, explain which lexical and grammatical constraints a
rendering satisfies and what remains interpretive. Counts alone establish neither
which translation is right nor a translator's bias.
