# Handshake for labeling: chemistry PhDs, on tap

*A pitch, written for a chemistry-based startup. Figures marked "rough" are
illustrative assumptions, not quoted market rates.*

## The one-liner

Handshake, but the students take labeling work instead of internships. You post
a chemistry annotation task; it routes to undergrads, MS students, PhD
candidates and postdocs in *your* subfield, at the school-and-lab level. Volume
work goes to the undergrads, adjudication and gold sets go to the PhDs.

## Why you can't buy this today

Your data is not the kind of data the labeling industry is built for. The
general vendor pools are excellent at "is there a pedestrian in this frame."
They are not people who have run the reaction.

Put a real task in front of them and it falls apart:

- **Reaction extraction.** Pulling reagents, equivalents, solvent, temperature,
  time and isolated yield out of a patent's SI. An annotator who has never
  written a procedure cannot tell a catalyst loading from a stoichiometric
  reagent, or spot that the reported yield is over two steps.
- **Spectra.** Peak assignment and purity calls on 1H/13C, LC-MS, IR. Multiplet
  vs. impurity vs. residual solvent is a judgment call that takes a semester of
  orgo lab to make and a PhD to make consistently.
- **Route plausibility.** Preference pairs over retrosynthetic proposals — which
  of these two routes would you actually run on Monday? This is the label that
  most improves a synthesis model and the one a generic pool literally cannot
  produce.
- **Structure OCR correction.** Fixing machine-extracted SMILES/molfiles against
  the drawn structure. Stereocenters and tautomers are where it breaks.
- **Hazard and handling.** Pyrophoric, peroxide-forming, controlled precursor,
  incompatible waste stream. Wrong labels here are not a metric problem.
- **Eval sets and failure triage.** Adversarial items your model should get
  right, and a read on *why* it got one wrong.

On tasks like these a general pool's inter-annotator agreement collapses. You
pay for the label, then pay again to find out which labels were noise, then pay
a third time to redo them. The expensive part of bad chemistry labels is never
the labels.

## Why students are the right supply

The people who *can* do this work are already sitting in a graduate program,
and every property you need from an annotator, they already have:

- **Credentialed and verifiable.** A `.edu` address, a department, an advisor, a
  lab. Subfield is not a self-reported checkbox — it is a public page.
- **Cheap relative to expertise.** A synthetic chemistry PhD candidate on a
  stipend in the low-to-mid $30Ks (rough) is paid less per hour than a vendor's
  "expert tier" markup, and knows more.
- **Idle capacity, in the right shape.** Column running, reaction stirring,
  instrument queues, waiting on a slot. Labeling fits the gaps in a lab day
  better than almost any other side work.
- **Motivated by more than the rate.** Money, yes — but also a line on the CV
  and a look inside a company they might want to join.

Handshake's whole thesis is that this population is reachable as a graph:
roughly 18M students across 1,500+ institutions, indexed by school, major and
year. Point that graph at labeling instead of internships and the supply
problem is solved before you start.

## The tiering that makes the economics work

Do not send every item to a PhD. Send every item to the cheapest person who can
get it right, and use the PhD where disagreement shows up.

```
undergrad first pass  →  agreement check  →  PhD adjudication on conflicts
   (volume, cheap)        (free, automatic)     (expensive, rare)
```

- **Tier 1 — undergrads (orgo through senior lab).** High-volume extraction,
  transcription, structure-OCR correction, obvious-hazard tagging. 2-3× overlap.
- **Tier 2 — MS/PhD candidates.** Peak assignment, mechanism sanity, yield
  plausibility, subfield-specific schema work.
- **Tier 3 — senior PhDs and postdocs.** Adjudication, gold-set authorship,
  rubric design, preference pairs on routes. This is where the quality ceiling
  of your dataset is actually set.

You get a cost curve under the vendor's expert tier and a quality curve well
above their base tier, because the floor of the pool is a chemistry
undergraduate rather than a generalist.

## Quality control, concretely

The marketplace is not a job board with a Stripe account. What it owes you:

- **Gold seeds** authored by Tier 3 and injected invisibly into every batch.
- **Per-subfield scoring.** An annotator's accuracy is tracked separately for
  organometallic vs. analytical vs. computational. Someone strong on NMR is not
  automatically routed your organometallic work.
- **Overlap and agreement** as the default, not an upsell, with conflicts
  escalating to adjudication automatically.
- **Rubrics co-authored with you**, versioned, so a schema change re-scores
  rather than silently drifts.
- **Per-task NDA and IP assignment** at claim time, with your unpublished
  chemistry never pooled across customers.

## The part you get for free: hiring

This is the piece that makes it Handshake rather than a labeling vendor.

Every annotation task is a paid audition. You will end up with a ranked,
evidence-backed list of chemistry grad students who have demonstrably done good
work on *your* problem, on *your* schema — and you will know their names before
any recruiter does. The person who adjudicated your spectra best for six months
is the person you hire, and you will have better signal on them than a full
interview loop produces.

A labeling vendor gives you labels. This gives you labels and a pipeline.

## What it takes to start

1. Pick one task type and write the rubric with a Tier 3 annotator (one week).
2. Author 200 gold items. This is the whole project's quality ceiling; do not
   rush it.
3. Run a 5,000-item pilot batch with 3× overlap. Measure agreement by tier.
4. Read the disagreements. They will tell you your schema is wrong somewhere —
   it always is — and fix it before scaling.
5. Scale the tier mix against measured agreement, not against a price sheet.

## Why this shape is not hypothetical

slashwork already runs this exact machine for agent work: a task is classified,
routed to a live pool of workers, run, submitted, and scored per class, with
the requester paying credits and the worker building a per-class reputation.
Task classification, routing, claim, submit, score, payout — the mechanics are
built and running. Swapping the worker pool from sessions to chemistry students
changes who claims the task, not the machine that routes it.
