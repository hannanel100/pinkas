-- =============================================================
-- 0007 — portal path objects: portal_bride_view + portal_rate_limit
-- Issue #37. Relates to SDD §6.2 (bride portal), §5 (private/public
-- boundary), §4.2 (security_invoker), §17.1; ADR-0003, ADR-0005.
-- Invariants in play: 2, 5, and 1 with the caveat spelled out below.
--
-- Expand-only (docs/runbooks/migrations.md): one view, one table, two
-- functions, and their grants. Nothing existing is dropped, renamed, altered
-- or repurposed, so this is safe to apply ahead of #7 (lib/data/portal.ts),
-- which is the only intended consumer of these objects.
--
-- GO-LIVE PRECONDITION for #7: a scheduled job running
-- portal_rate_limit_prune() must exist before the portal route serves
-- traffic. See RETENTION in section 2.
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
--   * Five columns is not "nothing sensitive". A forgotten predicate
--     discloses, for every tenant's resolvable bride: her first name, which
--     instructor she is with (tenant_id), and portal_expires_at — which
--     defaults to wedding_date + 14 (§6.2), so in practice it IS her wedding
--     date, minus a constant. The view keeps phone, last_name, city,
--     groom_name, referral_source and status out of reach; it does not keep
--     the wedding date out of reach.
--   * On a live Supabase project the service role also holds table-level
--     privileges on `bride` by default, so the key can still `select phone
--     from bride` directly. The column-level grant below is the complete set
--     this view needs; it narrows the service role only on a database where
--     service_role's table-level grant on `bride` has been revoked (tracked
--     in #53, deliberately not taken in this migration; the #37 test pins it).
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
-- WHAT EACH BUCKET THROTTLES — they are not interchangeable
--
--   * The IP bucket is the ONLY control on token guessing. A guessed token
--     has a random hash, so guesses scatter across hash-prefix buckets and
--     never accumulate in one. Its worth therefore depends entirely on the IP
--     being real: portal.ts must take the client IP from the hosting
--     platform's trusted header (the address the platform itself observed),
--     never the leftmost X-Forwarded-For entry, which the client writes.
--   * The hash-prefix bucket only throttles one link being hammered — a
--     leaked link replayed at volume. It does nothing against guessing.
--
-- HASH PREFIX, NEVER TOKEN PREFIX — decided, not inherited
--
--   §6.2 says "per token prefix". A prefix of the token is a partial
--   credential; storing it here would put plaintext credential material in a
--   table nobody thinks of as sensitive. The bucket key is a prefix of
--   sha256(token) — the same hash bride.portal_token_hash holds — which
--   buckets identical tokens identically and carries no plaintext. The column
--   is named token_hash_prefix so nobody can read it as anything else.
--   It is EXACTLY 8 bytes (a CHECK): a range would let two callers bucket the
--   same link differently and split its count, and 8 bytes is far too short to
--   serve as the lookup key itself.
--
-- THIS TABLE MUST NOT BECOME A PER-BRIDE IP ACCESS LOG
--
--   A real token's hash prefix is, in practice, unique to one bride. Every
--   hit writes an IP row and a prefix row; anything that lets a reader pair
--   those two rows turns this table into "bride X opened her link from IP Y
--   at time T" — location data about the women this product promises
--   discretion to (PRD §10.1, SDD §6.3). So, deliberately:
--
--   * No raw IP. The IP bucket is keyed by client_ip_hmac = HMAC-SHA256(key,
--     ip), 32 bytes, computed in lib/data/portal.ts. The key is a server-side
--     secret (an environment variable alongside the service-role key) that
--     never enters the database, so a dump of this table cannot be reversed
--     to IPs — the IPv4 space is small enough that an unkeyed hash could.
--     Bucketing needs equality only, which a keyed hash preserves. Rotating
--     the key just resets every IP counter, which is harmless.
--   * No surrogate id, no created_at, no updated_at. Each of those, identical
--     or consecutive across the two rows written by one call, was a join key.
--     A row is identified by its bucket and window (the two partial unique
--     indexes below), and carries nothing else but the count. This is a
--     deliberate exception to the created_at/updated_at convention.
--   * Residual, stated honestly: rows written in one call share a
--     transaction id (system column xmin) and tend to sit on the same page.
--     A superuser-level reader can still pair them that way. What they can
--     pair is a bride's link with an IP *pseudonym*, at window granularity,
--     for as long as the rows exist — which is why pruning is mandatory.
--
-- RETENTION — a precondition for #7, not a nicety
--
--   Rows are useless once their window ends. portal_rate_limit_prune()
--   deletes them, and a scheduled job running it (pg_cron, at least as often
--   as the shortest window portal.ts uses; infra) MUST be in place before
--   #7's portal route goes live. Without it this table accumulates every
--   portal visit forever.
--
-- CONCURRENCY
--
--   portal_rate_limit_hit() increments with INSERT ... ON CONFLICT DO UPDATE
--   SET hits = hits + 1. Under READ COMMITTED that statement either inserts or
--   takes the row lock on the conflicting row and re-reads it before
--   updating, so concurrent requests serialise on the row and no increment is
--   lost. There is no read-then-write in application code to race.
--   The arbiters are ordinary (non-deferrable) unique indexes — a deferrable
--   one could not be an ON CONFLICT arbiter.
--
-- NOT TENANT DATA
--
--   No tenant_id: a request is rate-limited before it is known to belong to
--   any tenant, and most abusive requests belong to none. RLS is enabled with
--   no policies so that anon/authenticated are refused even if a default grant
--   ever leaks onto the table; only the service role (BYPASSRLS) reaches it.
--   No primary key: the natural key has a nullable half by design (exactly
--   one of the two bucket columns is set), so it is enforced by two partial
--   unique indexes instead.
create table public.portal_rate_limit (
  client_ip_hmac    bytea,       -- HMAC-SHA256(server-side key, client IP); never the IP
  token_hash_prefix bytea,       -- first 8 bytes of sha256(token); NEVER of the token
  window_start      timestamptz not null,
  window_seconds    integer     not null,
  hits              integer     not null default 1,
  constraint portal_rate_limit_one_key
    check (num_nonnulls(client_ip_hmac, token_hash_prefix) = 1),
  constraint portal_rate_limit_ip_hmac_len
    check (client_ip_hmac is null or octet_length(client_ip_hmac) = 32),
  constraint portal_rate_limit_prefix_len
    check (token_hash_prefix is null or octet_length(token_hash_prefix) = 8),
  constraint portal_rate_limit_window
    check (window_seconds between 1 and 86400),
  constraint portal_rate_limit_hits
    check (hits >= 1)
);

create unique index portal_rate_limit_ip_key
  on public.portal_rate_limit (client_ip_hmac, window_seconds, window_start)
  where client_ip_hmac is not null;
create unique index portal_rate_limit_prefix_key
  on public.portal_rate_limit (token_hash_prefix, window_seconds, window_start)
  where token_hash_prefix is not null;
create index portal_rate_limit_window_idx
  on public.portal_rate_limit (window_start);

alter table public.portal_rate_limit enable row level security;
-- No policies, on purpose: see NOT TENANT DATA above.

comment on table public.portal_rate_limit is
  'Fixed-window portal rate-limit counters (SDD 6.2, issue #37). One row per '
  '(client_ip_hmac | token_hash_prefix, window). No raw IP, no timestamps '
  'beyond the window, no surrogate id - so the two rows of one request cannot '
  'be joined into a per-bride IP log. Written only via portal_rate_limit_hit(); '
  'must be pruned on a schedule.';
comment on column public.portal_rate_limit.client_ip_hmac is
  'HMAC-SHA256 of the client IP under a server-side key that never enters the '
  'database. Equality bucketing only; not reversible from a dump.';
comment on column public.portal_rate_limit.token_hash_prefix is
  'First 8 bytes of sha256(portal token). A prefix of the HASH, never of the '
  'token: a token prefix is a partial credential.';


-- portal_rate_limit_hit — count one request against both buckets.
--
-- Returns the post-increment count for each bucket in the current window and
-- when the window ends (for Retry-After). It does not decide; the limits live
-- in lib/data/portal.ts so they can change without a migration. Pass NULL for
-- a bucket that does not apply (e.g. a request with no parseable token): its
-- count comes back NULL and nothing is written for it. Passing both NULL is an
-- error — a call that counts nothing is a bug in the caller.
--
-- The window is taken from now(), i.e. the transaction start, so every hit in
-- one transaction lands in the same window.
--
-- security invoker: the caller (service_role) needs insert/update/select on
-- the table, granted below. No elevation is needed for a table that is not
-- tenant data and that the caller already reaches.
create function public.portal_rate_limit_hit(
  p_client_ip_hmac    bytea,
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
  if p_client_ip_hmac is null and p_token_hash_prefix is null then
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

  if p_client_ip_hmac is not null then
    insert into portal_rate_limit (client_ip_hmac, window_seconds, window_start)
    values (p_client_ip_hmac, p_window_seconds, v_start)
    on conflict (client_ip_hmac, window_seconds, window_start) where client_ip_hmac is not null
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

comment on function public.portal_rate_limit_hit(bytea, bytea, integer) is
  'Increment the per-IP-HMAC and per-token-hash-prefix fixed-window counters '
  'and return both counts (SDD 6.2, issue #37). Atomic under concurrency via '
  'INSERT ... ON CONFLICT DO UPDATE. Decides nothing; limits live in '
  'lib/data/portal.ts.';


-- portal_rate_limit_prune — delete windows that have ended.
-- Returns the number of rows deleted. Must run on a schedule (see RETENTION).
create function public.portal_rate_limit_prune()
returns integer
language sql
security invoker
set search_path = public, pg_temp
as $fn$
  with gone as (
    delete from portal_rate_limit
    where window_start + make_interval(secs => window_seconds) <= now()
    returning 1
  )
  select count(*)::integer from gone;
$fn$;

comment on function public.portal_rate_limit_prune() is
  'Delete ended rate-limit windows (issue #37). Scheduling it is a '
  'precondition for the portal route going live.';


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

revoke execute on function public.portal_rate_limit_hit(bytea, bytea, integer)
  from public, anon, authenticated, service_role;
grant  execute on function public.portal_rate_limit_hit(bytea, bytea, integer) to service_role;

revoke execute on function public.portal_rate_limit_prune()
  from public, anon, authenticated, service_role;
grant  execute on function public.portal_rate_limit_prune() to service_role;
