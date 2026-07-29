# `lib/data/` — the single door to the database

**Owning agent:** `backend` · **Design:** SDD §13 · **Reviewed by:** `security`

Empty by design; the modules are ticketed.

Expected modules, per SDD §13:

| Module | Responsibility |
|---|---|
| `brides.ts` | `listBrides`, `getBrideCard`, `createBride` |
| `courses.ts` | `createCourse` (snapshot), `recomputeSchedule`, `confirmSchedule` |
| `sessions.ts` | `markDone`, `cancel`, `reschedule` |
| `records.ts` | `upsertSessionRecord` — private data, §5 |
| `today.ts` | `getTodayScreen` — the single aggregated query, §18.1 |
| `portal.ts` | `resolvePortalToken`, `getPortalView` — Path 2 only, service role |
| `audit.ts` | `logAccess` — called by every function above |

**Why one place (invariant 3).** PRD §10.1 requires a log of every viewing of bride data. Postgres
has no `AFTER SELECT`, so no trigger can write it; the log exists only where reads are issued, and
is *complete* only because reads are issued here. A direct browser-to-Supabase query would be an
unlogged read.

`portal.ts` is the only module that may import `lib/supabase/service`, and `app/(portal)/` may not
import any of the others. Both directions are enforced in `eslint.config.mjs`.
