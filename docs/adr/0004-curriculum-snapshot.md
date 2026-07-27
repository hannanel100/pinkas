# ADR-0004 — Snapshot the curriculum when a course is created

**Status:** Accepted · July 2026
**Relates to:** SDD §3.5

## Context

A `curriculum` is a reusable template: an ordered list of topics an instructor teaches. A `course` is that template applied to one bride, with real dates.

Instructors edit their templates continuously — reordering topics, rewording, splitting one session into two — while courses taught from earlier versions are still running or long finished.

If a course referenced the live template, editing it would rewrite history for every past and in-flight bride. A completed session recorded as covering topic #4 would silently come to mean something else. PRD §7.3.א states the consequence: **"otherwise history breaks retroactively."**

## Decision

At course creation, copy the entire curriculum into `course.curriculum_snapshot jsonb`, with a `snapshot_version` for future shape changes. `curriculum_id` is retained for provenance only — it answers "which template did this come from", never "what does this course contain".

`curriculum_id` is `on delete set null`: deleting a template must not destroy the record of courses taught from it, and the snapshot means nothing is lost when it happens.

`session_record.covered_topic_ids` references topic ids **inside the snapshot**, so the reference stays valid no matter what happens to the template afterwards.

## Consequences

**Good.** History is immutable. An instructor can edit templates freely without a warning dialog about affecting existing brides — which is the behaviour she would expect anyway, and the alternative would force the product to nag her about consequences she does not think in terms of. A completion certificate (story G1) produced years later reflects what was actually taught.

**Costs.**

- Improving a template does not propagate to running courses. This is the correct default — a bride mid-course should not have her remaining syllabus change underneath her — but it will eventually be asked for. The answer is an explicit, per-course "update from template" action that shows a diff, never a silent sync.
- Duplicated data. Negligible: a curriculum is a few kilobytes of text and there are tens of courses per instructor per year.
- The snapshot is `jsonb`, so it is not constrained by the relational schema. Mitigated by validating it with a versioned Zod schema on write and on read, keyed by `snapshot_version`.

## Why this is an ADR rather than a schema footnote

This is the decision most likely to be "simplified" away by a future contributor who sees denormalised JSON next to a perfectly good `curriculum_topic` table and reads it as an oversight. It is not an oversight. Replacing the snapshot with a foreign key would pass every test and break the product's historical record silently, months later, the first time an instructor reorders a template while eight courses are running.

## Alternatives rejected

**Version the curriculum, point courses at a version.** Correct, and normalised. Rejected as more machinery than the problem needs at this scale: it requires version rows, immutability enforcement on published versions, and a UI concept ("versions") the persona has no reason to learn.

**Copy-on-write template edits.** Same outcome as versioning, with subtler failure modes and the same conceptual cost.
