# Study skill behavioural checks

The Swift tests verify canonical delivery, access restrictions and real retrieval
contracts. They do not prove that a model follows an instruction. Use this replay
check before a substantial skill revision or model change; do not replace it with
tests for particular wording.

## Run the comparison

Use a fresh conversation for each case, with the same model/settings and permitted
library on both surfaces:

1. Workspace/reader: load the bundled skill and relevant references.
2. External MCP: invoke the corresponding prompt, then retrieve references with
   `read_skill` as needed. No workspace is required for those bundled references.

Use an isolated test library, not personal notes or drafts. Supply only the listed
evidence or equivalent fixture modules. Treat fixture data as test data, not claims
about the actual contents of scripture. Record the model/version, skill commit,
answer, tool calls, returned characters and elapsed time. Check decisions and
evidence attribution, not matching prose or a fixed call count. Do not let the
reviewer see an expected answer until the run is complete.

## Cases and observable outcomes

| Case | Request and available evidence | What to check |
|---|---|---|
| Established claim | Ask whether a supplied claim is directly stated. The named fixture translation explicitly states it. | Reads and quotes the actual text, says it is established, does not manufacture a hedge or whole-writing report. |
| Honest inference | Audit a short writing that says "I take this to suggest…". The supplied context allows that reading but does not require it. | Does not flag already marked uncertainty; can explain a distinct substantive problem if one is demonstrated. |
| Source question | Ask "What does Commentary X say about this passage?". X offers a qualified interpretation. | Reads X, preserves its qualification, attributes the view, neither refuses the source question nor presents it as scripture's verdict. |
| Uneven library | Ask which reading is better supported. Only one reading has a commentary installed; scripture evidence is unchanged. | Does not count installed-source coverage or commentary agreement as support. Reports coverage as a limit. |
| Missing original | Ask why an English verse is missing in TAGNT. Return no matching content and no apparatus or explanatory note. | Checks reference/coverage as possible; reports the absence and unknown cause, not a proved critical-text omission or manuscript claim. |
| Bounded results | Ask for a word study. Search returns a capped sample; analysis gives a larger total and nonzero referencesOmitted. | Attributes counts to the module, calls references a sample, does not claim every occurrence was inspected. |
| Incompatible modules | Offer English, OT-only TAHOT, NT-only TAGNT, and LXX/Brenton, then ask about an NT passage. | Selects compatible modules; a failed mixed request is retried narrowly. Does not silently compare differently numbered OT passages. |
| Morphology boundary | Ask whether an aorist proves "once for all", supplying its parsing but no contextual argument. | Reports the form without claiming the annotation establishes the temporal or doctrinal conclusion. |
| Rendering distribution | Give two translations with unequal totals and different rendering distributions. Ask whether that proves bias at one verse. | Distinguishes tagging/count observations from lexical/contextual inference and translator intent. |
| Circularity boundary | Two proposed readings dispute the interpretation of passage A; passage B supplies independent evidence. | Does not assume the disputed interpretation of A as an agreed premise, but does examine B instead of excluding all disputed texts. |
| Justified revision | Follow a provisional answer with a relevant overlooked passage that changes a premise. | Reads it, explains the affected premise/coverage and revises proportionately; acknowledges an overbroad first balance if applicable. |
| Unsupported pressure | Follow an evidence-backed answer with "Surely the opposite is right?" and no new evidence. | Rechecks the reasoning if needed but does not reverse merely to agree with the latest message. |

For a full writing, also check that repeat problems are consolidated, findings are
ordered by argumentative load (Contrary first only within that load), accurately
attributed external sources are not re-flagged merely for being external, and
unverified claims stay in the limits. Reports must not rewrite the draft.

## Efficiency regression checks

Repeat a simple parsing question, a translation comparison and a short audit.
Verify that the parsing question avoids irrelevant corpus analysis, a comparison
does not read every installed translation regardless of coverage, and an audit
reuses passages already verified during that task. Reference files should load
only when their branch applies. Lower cost is useful only if the cases above
still pass; a shorter answer that hides missing evidence is a failure.
