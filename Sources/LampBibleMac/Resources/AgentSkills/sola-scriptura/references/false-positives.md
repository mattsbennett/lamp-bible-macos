# What not to flag

Read this before the inventory and again before reporting. An audit that flags
figures of speech spends the authority it needs for the finding that matters, and
a writer who gets forty findings reads none of them.

## Not claims at all

**Scripture's own words.** Never an import, however much a system has been built on
them. *Bore our sins in his body*, *a curse for us*, *ransom*, *bought with a
price*, *propitiation* where a translation has it — these are the text. A writer
quoting them is quoting. The finding would be a *gloss* that adds a mechanism the
words do not state, not the words.

**Pastoral application in the writer's own voice.** "And that's a diagnostic I can
use on myself." "What I need is a Nathan." The writer is not claiming the text says
this about you; they are using it. Only flag an application that smuggles in a
claim — *therefore God will do the same for you* is a claim.

**Figures of speech, rhetorical questions, and framing a discussion.** "The question
I'd like us to consider." "That verse is frightening." Not assertions about what
scripture teaches.

**The writer's own experience or their community's practice, stated as such.** "Our
weekly memorial around this table" describes what the hearers do. The claim would be
*as taught in Hebrews*, which attributes the practice to a text.

**A claim the writer has already sourced.** When `DEVOTIONAL_CONTEXT.md` or a file
under `context/` carries the support, the writer has done the work and told you where.
Read it before flagging. An unsourced claim in the prose whose source sits in the
context folder is at most a request to cite it in the text.

## Already honest

**Hedged inference.** *I think*, *as far as we can tell from the text*, *arguably*,
*seems to be*, *on one level*. The writer has marked it. There is nothing left to
find, and re-flagging it teaches them that hedging buys nothing.

**Named external sources.** *Bruce argues*, *this is sometimes called a juridical
parable*, *our statement of faith puts it this way*. Naming is the remedy, so a named
source is already remedied. The finding is unacknowledged dependence, or a named source
promoted to *scripture teaches*.

**A labelled reconstruction.** "Putting the two accounts together." Harmonisation
the writer has owned.

## In the text, therefore checkable, therefore fine

**Literary observation.** Repetition, a recurring word, a chiasm, a parable's
structure, a quotation of one book by another. All of it is in the text, and
verifiable — if you doubt it, look it up rather than flagging it.

**Scripture's own cross-references.** A link the New Testament itself draws is the
New Testament's claim, not the writer's.

**Superscriptions and titles.** Psalm 51's heading is in the text. Treating it as
part of the psalm is a textual position, not an import — and most translations print
it.

## Not this audit's business

**Translation choice.** Quoting one translation is not a finding. A claim that
*depends* on one translation's wording where others read differently is — pass every
translation to `read_passage` and report only the dependency.

**A community's wording rule.** Which terms a community's writing uses for a doctrine
is a separate gate. Note an intersection in a clause; do not enforce it here.

**Prose quality, structure, length, tone.** Another skill's job.

**Whether the doctrine is true.** You are reporting what the cited text carries.
"This is not established by Hebrews" is your finding. "This is wrong" is not, and
"the tradition is right about this" is not either.

## Two rules about volume

**One finding per problem.** If the same drift appears eight times, write it once
and list the other seven references in a line. Eight entries for one mistake reads
as padding, and it is.

**If every remedy is a hedge, the audit is bad.** Writing that hedges everything
asserts nothing, which is not the goal. Where a claim is genuinely established, the
useful service is to say so and point at the text that does it.
