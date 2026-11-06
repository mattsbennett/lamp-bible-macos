# Comparing the Septuagint

`LXX` is Brenton's Greek OT and `Brenton` his English rendering. Both are bundled
candidates, subject to the module inventory. They have no Strong's tagging or
morphology: neither `analyze_strongs` nor a `strongs_key` search reaches them.
Compare their words by reading the corresponding passages, not by inventing keys.

Their Greek is evidence of an early rendering of Hebrew, not a lexicon range or a
second independent witness to the Hebrew assertion. Comparing `TAHOT`, `LXX` and an
NT quotation can reveal differences in wording; without further evidence it does
not identify a translator's motive or distinguish translation choice from a
different underlying text. Describe the difference and mark that limit.

`Brenton` marks supplied English with `{kind: "added"}` annotations.
`read_study_material` gives his translator footnotes. These can explain his English;
attribute that explanation rather than making it the original's assertion.

## Check references before comparing

`read_passage` performs no versification conversion. Use separate calls and verify
opening wording and context before treating verses as corresponding.

- English Psalms 9–10 are Greek 9, 114–115 are Greek 113, English 116 spans Greek
  114–115, and English 147 spans Greek 146–147. Psalms 148–150 agree again; these
  modules also have Psalm 151. There is no universal one-psalm offset.
- Titles may be verse 1: English Psalm 22:1 is `LXX` 21:2.
- These modules have no separate Nehemiah; it is in Ezra 11–23. Nehemiah 1:1 is
  Ezra 11:1 in their numbering.

If the correspondence or word alignment cannot be checked, report it as unverified
rather than silently comparing different passages or supplying a parsing.
