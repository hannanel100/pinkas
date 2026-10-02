-- =============================================================
-- 0007 — portal path objects: portal_bride_view + portal_rate_limit
-- Issue #37. Relates to SDD §6.2 (bride portal), §5 (private/public
-- boundary), §4.2 (security_invoker), §17.1; ADR-0003, ADR-0005.
-- Invariants in play: 2, 5, and 1 with the caveat spelled out below.
--
-- Expand-only (docs/runbooks/migrations.md): one view, one table, one
-- function, and their grants. Nothing existing is dropped, renamed, altered
-- or repurposed, so this is safe to apply ahead of #7 (lib/data/portal.ts),
-- which is the only intended consumer of all three objects.
-- =============================================================


-- =============================================================
-- 1. portal_bride_view
-- =============================================================
--
-- WHAT THIS IS FOR
--
-- Portal token resolution has to find the bride a token belongs to. `bride`
-- also holds phone, last_name, city, groom_name, wedding_date, referral_source
-- and status. This view exposes exactly the five columns token resolution and
-- the portal page need, so lib/data/portal.ts never names the `bride` table
-- at all, and schema.test.sql pins the column list the same way §17.1 pins
-- portal_session_view's seven.
--
-- WHAT THIS DOES *NOT* DO — read this before trusting it
--
-- This view is COLUMN NARROWING, NOT ISOLATION. It does not protect one
-- tenant's brides from another, and it does not stop the service role from
-- reading anything.
--
--   * `security_invoker = on` is declared because every view in this schema
--     must declare it (SDD §4.2) — not because it buys anything here. The
--     portal reads with the service role, and the service role bypasses RLS
--     (BYPASSRLS). Invoker or owner, no RLS policy is ever consulted on this
--     path. The bride_tenant policy does not apply to the portal read.
--   * The only row-level control on the portal path is the predicate
--     portal.ts writes: an equality match on portal_token_hash. That hash is
--     unique (bride_portal_token_hash_key), so a correct lookup returns at
--     most one row. A lookup that forgets the predicate returns every tenant's
--     resolvable brides. Nothing in the database prevents that.
--   * On a live Supabase project the service role also holds table-level
--     privileges on `bride` by default, so the key can still `select phone
--     from bride` directly. The column-level grant below is the complete set
--     this view needs; it narrows the service role only on a database where
--     service_role's table-level grant on `bride` has been revoked (an open
--     decision recorded on #37, deliberately not taken in this migration).
--
-- What it does buy: lib/data/portal.ts has no select list a developer can
-- widen by typing one more column name; the portal surface is asserted by
-- test rather than by review; and the private fields of session_record are
-- not reachable from it by construction (it reads `bride` and nothing else —
-- `bride` deliberately has no notes column, SDD §3.4).
--
-- ROWS IT EXPOSES (fail closed)
--
--   * deleted_at is null           — a soft-deleted bride's link is dead.
--   * portal_token_hash is not null — no token, nothing to resolve; revocation
--                                     (nulling the hash, §6.2) removes the row.
--   * portal_expires_at > now()    — an expired link resolves to nothing, the
--                                     same as a wrong one. A NULL expiry also
--                                     resolves to nothing: issuance must set
--                                     one (§6.2 default wedding_date + 14).
--
-- Expiry is enforced here rather than left to an `if` in portal.ts because a
-- forgotten check is a link that works forever (E4). The column is still
-- exposed so the page can show the bride the date (plate 04 note 4). The
-- consequence, accepted: the portal cannot tell "expired" from "never valid",
-- and shows one neutral page for both — which is also what discretion (§6.3)
-- asks for.
create view public.portal_bride_view with (security_invoker = on) as
select
  b.id,
  b.tenant_id,
  b.portal_expires_at,
  b.portal_token_hash,
  b.first_name
from public.bride b
where b.deleted_at is null
  and b.portal_token_hash is not null
  and b.portal_expires_at > now();

comment on view public.portal_bride_view is
  'Portal token resolution (SDD 6.2, issue #37). Exactly five columns. '
  'COLUMN NARROWING, NOT ISOLATION: the service role bypasses RLS, so '
  'security_invoker buys nothing here and the caller''s portal_token_hash '
  'equality predicate is the only row filter. Excludes soft-deleted, '
  'tokenless and expired brides.';

-- Grants. Nothing is inherited from defaults.
--   * service_role: select on the view, plus column-level select on exactly
--     the `bride` columns the view references. A security_invoker view checks
--     the invoker's privileges on the base table, column by column, so these
--     six are the minimum that makes the view readable — and the complete
--     list, so that once service_role's table-level grant on `bride` is
--     revoked, `phone`, `groom_name` and `referral_source` become unreadable
--     to the portal key rather than merely unselected.
--   * anon, authenticated, PUBLIC: nothing. Instructors read `bride` itself
--     under RLS; the browser never reads this view (ADR-0006).
revoke all on public.portal_bride_view from public, anon, authenticated, service_role;
grant select on public.portal_bride_view to service_role;
grant select (id, tenant_id, first_name, portal_token_hash, portal_expires_at, deleted_at)
  on public.bride to service_role;


-- =============================================================
-- 2. portal_rate_limit — fixed-window counter
-- =============================================================
--
-- SDD §6.2: rate-limit per IP and per token prefix. The edge/WAF layer is the
-- primary control (filed separately as infra work). This is the in-code
-- backstop that still holds when a request reaches the application. It lives
-- in Postgres because an in-memory counter on serverless is per instance —
-- N instances, N independent limits, i.e. no limit.
--
-- HASH PREFIX, NEVER TOKEN PREFIX — decided, not inherited.
--   §6.2 says "per token prefix". A prefix of the token is a partial
--   credential; storing it here would put plaintext credential material in a
--   table nobody thinks of as sensitive. The bucket key is therefore a prefix
--   of sha256(token) — the same hash bride.portal_token_hash holds — which
--   buckets identical tokens identically and carries no plaintext. The column
--   is named token_hash_prefix so nobody can read it as anything else, and the
--   CHECK caps it at 16 bytes so it stays a bucket key, not the lookup key.
--
-- WHY IP AND HASH PREFIX ARE SEPARATE ROWS
--   Each request bumps two independent counters: one for the client IP, one
--   for the hash prefix. Exactly one of the two key columns is set per row
--   (num_nonnulls = 1), and each kind has its own partial unique index, which
--   is the ON CONFLICT arbiter for that kind.
--
-- CONCURRENCY
--   portal_rate_limit_hit() increments with INSERT ... ON CONFLICT DO UPDATE
--   SET hits = hits + 1. Under READ COMMITTED that statement either inserts or
--   takes the row lock on the conflicting row and re-reads it before
--   updating, so concurrent requests serialise on the row and no increment is
--   lost. There is no read-then-write in application code to race.
--   The arbiters are ordinary (non-deferrable) unique indexes — a deferrable
--   one could not be an ON CONFLICT arbiter.
--
-- NOT TENANT DATA
--   No tenant_id: a request is rate-limited before it is known to belong to
--   any tenant, and most abusive requests belong to none. RLS is enabled with
--   no policies so that anon/authenticated are refused even if a default grant
--   ever leaks onto the table; only the service role (BYPASSRLS) reaches it.
--
-- RETENTION
--   client_ip is personal data. Rows are only useful for the window they
--   count; portal_rate_limit_prune() deletes expired windows and is meant to be
--   scheduled (pg_cron, infra) — see the open item on #37. The window_start
--   index serves it.
create table public.portal_rate_limit (
  id                bigint generated always as identity primary key,
  client_ip         inet,
  token_hash_prefix bytea,       -- prefix of sha256(token); NEVER of the token
  window_start      timestamptz not null,
  window_seconds    integer     not null,
  hits              integer     not null default 1,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint portal_rate_limit_one_key
    check (num_nonnulls(client_ip, token_hash_prefix) = 1),
  constraint portal_rate_limit_prefix_len
    check (token_hash_prefix is null or octet_length(token_hash_prefix) between 4 and 16),
  constraint portal_rate_limit_window
    check (window_seconds between 1 and 86400),
  constraint portal_rate_limit_hits
    check (hits >= 1)
);

create unique index portal_rate_limit_ip_key
  on public.portal_rate_limit (client_ip, window_seconds, window_start)
  where client_ip is not null;
create unique index portal_rate_limit_prefix_key
  on public.portal_rate_limit (token_hash_prefix, window_seconds, window_start)
  where token_hash_prefix is not null;
create index portal_rate_limit_window_idx
  on public.portal_rate_limit (window_start);

create trigger portal_rate_limit_touch before update on public.portal_rate_limit
  for each row execute function set_updated_at();

alter table public.portal_rate_limit enable row level security;
-- No policies, on purpose: see NOT TENANT DATA above.

comment on table public.portal_rate_limit is
  'Fixed-window portal rate-limit counters (SDD 6.2, issue #37). One row per '
  '(client_ip | token_hash_prefix, window). token_hash_prefix is a prefix of '
  'sha256(token), never of the token. Written only via portal_rate_limit_hit().';
comment on column public.portal_rate_limit.token_hash_prefix is
  'Leading 4-16 bytes of sha256(portal token). A prefix of the HASH, never of '
  'the token: a token prefix is a partial credential.';


-- portal_rate_limit_hit — count one request against both buckets.
--
-- Returns the post-increment count for each bucket in the current window and
-- when the window ends (for Retry-After). It does not decide; the limits live
-- in lib/data/portal.ts so they can change without a migration. Pass NULL for
-- a bucket that does not apply (e.g. a request with no parseable token): its
-- count comes back NULL and nothing is written for it. Passing both NULL is an
-- error — a call that counts nothing is a bug in the caller.
--
-- security invoker: the caller (service_role) needs insert/update/select on
-- the table, granted below. No elevation is needed for a table that is not
-- tenant data and that the caller already reaches.
create function public.portal_rate_limit_hit(
  p_client_ip         inet,
  p_token_hash_prefix bytea,
  p_window_seconds    integer
)
returns table (
  ip_hits                integer,
  token_hash_prefix_hits integer,
  window_ends_at         timestamptz
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $fn$
declare
  v_start      timestamptz;
  v_ip_hits    integer;
  v_pref_hits  integer;
begin
  if p_client_ip is null and p_token_hash_prefix is null then
    raise exception 'portal_rate_limit_hit: at least one bucket key is required'
      using errcode = '22023';
  end if;
  if p_window_seconds is null or p_window_seconds not between 1 and 86400 then
    raise exception 'portal_rate_limit_hit: p_window_seconds must be 1..86400'
      using errcode = '22023';
  end if;

  -- Fixed window aligned to the epoch, so every instance agrees on where a
  -- window starts without coordinating.
  v_start := date_bin(make_interval(secs => p_window_seconds), now(),
                      timestamptz '1970-01-01 00:00:00+00');

  if p_client_ip is not null then
    insert into portal_rate_limit (client_ip, window_seconds, window_start)
    values (p_client_ip, p_window_seconds, v_start)
    on conflict (client_ip, window_seconds, window_start) where client_ip is not null
    do update set hits = portal_rate_limit.hits + 1
    returning hits into v_ip_hits;
  end if;

  if p_token_hash_prefix is not null then
    insert into portal_rate_limit (token_hash_prefix, window_seconds, window_start)
    values (p_token_hash_prefix, p_window_seconds, v_start)
    on conflict (token_hash_prefix, window_seconds, window_start) where token_hash_prefix is not null
    do update set hits = portal_rate_limit.hits + 1
    returning hits into v_pref_hits;
  end if;

  return query select v_ip_hits, v_pref_hits,
                      v_start + make_interval(secs => p_window_seconds);
end
$fn$;

comment on function public.portal_rate_limit_hit(inet, bytea, integer) is
  'Increment the per-IP and per-token-hash-prefix fixed-window counters and '
  'return both counts (SDD 6.2, issue #37). Atomic under concurrency via '
  'INSERT ... ON CONFLICT DO UPDATE. Decides nothing; limits live in '
  'lib/data/portal.ts.';


-- portal_rate_limit_prune — delete windows that have ended.
-- Returns the number of rows deleted. Intended for a scheduled job.
create function public.portal_rate_limit_prune()
returns integer
language sql
security invoker
set search_path = public, pg_temp
as $fn$
  with gone as (
    delete from portal_rate_limit
    where window_start + make_interval(secs => window_seconds) < now()
    returning 1
  )
  select count(*)::integer from gone;
$fn$;

comment on function public.portal_rate_limit_prune() is
  'Delete ended rate-limit windows (issue #37). client_ip is personal data '
  'and has no use after its window closes.';


-- Grants. Explicit and minimal; nothing relies on default privileges.
--   * service_role: execute on hit (the portal route) and prune (a scheduled
--     job, if it runs as service_role rather than as the owner); select,
--     insert, update on the table for the invoker-rights function; delete for
--     prune. No direct table writes are expected from application code.
--   * anon, authenticated, PUBLIC: nothing at all. Supabase's default
--     privileges grant EXECUTE on new functions in `public` to anon and
--     authenticated directly, so those are revoked by name (#31).
revoke all on public.portal_rate_limit from public, anon, authenticated, service_role;
grant select, insert, update, delete on public.portal_rate_limit to service_role;

revoke execute on function public.portal_rate_limit_hit(inet, bytea, integer)
  from public, anon, authenticated, service_role;
grant  execute on function public.portal_rate_limit_hit(inet, bytea, integer) to service_role;

revoke execute on function public.portal_rate_limit_prune()
  from public, anon, authenticated, service_role;
grant  execute on function public.portal_rate_limit_prune() to service_role;
