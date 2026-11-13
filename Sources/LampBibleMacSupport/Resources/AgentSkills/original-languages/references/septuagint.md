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

## The Hebrew behind a Greek word

`tbesg` entries often say which Hebrew words the Septuagint renders with the Greek
word: σάρξ is "in LXX chiefly for בָּשָׂר". `lookup_dictionary_keys` returns these
as a sense's `septuagintHebrew`, with `text` and optional `strongs` and `stem`.
Follow a supplied key into `bdb`, or into `analyze_strongs` with `TAHOT`. If no key
is supplied, use `search_dictionary` with the Hebrew `text` and
`module_ids: ["bdb"]`; check the returned headwords and definitions rather than
inventing a Strong's number. A `stem` describes the lexicon's note, not a parsing
retrieved from a particular Hebrew verse. A dictionary link alone establishes
neither word alignment nor which homograph a passage uses.

This is Abbott-Smith's summary of Septuagint usage (1922), not a count of the
bundled `LXX`, which stays untagged. Attribute it to him, and read an actual pair of
passages before resting a claim on the correspondence. Keys above G5624 are
STEPBible's extended numbers, not a guarantee that a word occurs only in the
Septuagint or Apocrypha. `TAGNT` also uses some, such as G6001 at Matthew 13:48.
Check the passage's actual annotations before choosing a key for counts or search.
An extended entry is reachable by exact key or by lemma with `search_dictionary`;
its presence in the lexicon does not establish that a permitted text tags it.
`LXX` itself remains untagged: a `TAGNT` count is not a Septuagint count.

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
