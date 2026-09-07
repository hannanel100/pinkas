-- =============================================================
-- 0005 — bootstrap_instructor: make the signup transaction atomic
-- Issue #36. Relates to SDD §6.1 (instructor auth), §14.2 (templates),
-- §4 (RLS), ADR-0002, ADR-0004.
--
-- Expand-only (docs/runbooks/migrations.md): this migration adds one function
-- and its grants. Nothing is dropped, renamed or repurposed and no existing
-- code path changes behaviour, so it is safe to apply ahead of #7/#10
-- (lib/data/signup.ts and the signup route), which do not exist yet.
-- =============================================================
--
-- WHY A FUNCTION AT ALL
--
-- A1 promises that signup seeds a working account. PostgREST cannot express a
-- multi-statement transaction: three separate REST calls can fail after the
-- first, leaving an instructor whose account looks set up and is not, thirty
-- seconds after she opened the product for the first time. One RPC is one
-- transaction, so the seed either lands whole or not at all.
--
-- Deliberately a FUNCTION and not a PROCEDURE. A procedure may COMMIT
-- mid-body, which is exactly the partial state this exists to prevent; a
-- function cannot. For the same reason there is no `exception when others`
-- handler anywhere below: catching and continuing would let the call return
-- success with half the seed missing. Every failure must reach the caller.
--
-- WHY security invoker
--
-- SECURITY DEFINER here would be a tenant-forgery primitive: a function that
-- writes instructor-scoped rows while bypassing RLS is one parameter away from
-- writing them under someone else's tenant_id. This function runs as the
-- caller, takes no instructor-id parameter, and derives the tenant from
-- auth.uid() alone — so invariant 1 (isolation is RLS, not a predicate someone
-- must remember) still holds for every row it writes. If it ever appears to
-- need elevating, that is a design decision and an ADR, not a one-word edit.
--
-- ACCESS LOG: a signup writes NO access_log row. Decided, not overlooked.
--   PRD §10.1 requires a log of every *viewing of bride data*. At signup no
--   bride exists, nothing is read, and the only rows written belong to the
--   caller herself. The log's worth is that every row in it is an access to
--   someone's intimate data; mixing account-lifecycle events in would make
--   "who looked at Noa's notes" a query with a filter somebody must remember,
--   which is the failure mode invariant 1 exists to avoid. Account creation is
--   already evidenced by auth.users and instructor.created_at. Support access
--   to instructor data (SDD §16.2) stays logged; that is unchanged.
--
-- CURRICULUM SNAPSHOT: this seeds a curriculum *template* only. It creates no
-- course and no snapshot. Invariant 6 / ADR-0004 are untouched — a course
-- snapshots its curriculum at course-creation time, and nothing here does.
--
-- SEED CONTENT COMES FROM THE CALLER, ON PURPOSE. The Hebrew bodies of the
-- system templates are product copy (invariant 8: strings live in the
-- translation layer). A migration file is immutable once applied, so copy
-- frozen here could never be corrected for tenants already seeded, and every
-- wording change would cost a migration. p_templates is therefore required and
-- must be non-empty: it is impossible to bootstrap an instructor without the
-- templates D1 needs, which is the half of A1's promise that matters.
-- =============================================================

create function public.bootstrap_instructor(
  p_full_name  text,
  p_phone      text,
  p_templates  jsonb,                -- [{name, body}, ...] — required, non-empty
  p_email      text  default null,
  p_curriculum jsonb default null     -- {name, description?, default_session_count?, topics:[{title, description?, estimated_minutes?}]}
)
returns table (
  instructor_id         uuid,
  was_created           boolean,
  seeded_curriculum_id  uuid,
  seeded_template_count integer
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $fn$
declare
  v_instructor_id  uuid := auth.uid();
  v_created        boolean := false;
  v_curriculum_id  uuid;
  v_template_count integer := 0;
  v_topic_count    integer := 0;
  v_session_count  smallint;
  v_rows           integer;
begin
  if v_instructor_id is null then
    raise exception 'bootstrap_instructor: requires an authenticated caller'
      using errcode = '28000';
  end if;

  -- p_phone is expected already normalised to E.164 (SDD §14.1). Normalisation
  -- is the caller's job in lib/, not a second implementation down here.
  if coalesce(btrim(p_full_name), '') = '' then
    raise exception 'bootstrap_instructor: p_full_name is required'
      using errcode = '22023';
  end if;
  if coalesce(btrim(p_phone), '') = '' then
    raise exception 'bootstrap_instructor: p_phone is required'
      using errcode = '22023';
  end if;

  -- Structure is validated here; value ranges are not. The column CHECKs own
  -- those, and duplicating them would create two places that can disagree.
  if p_templates is null
     or jsonb_typeof(p_templates) <> 'array'
     or jsonb_array_length(p_templates) = 0 then
    raise exception
      'bootstrap_instructor: p_templates must be a non-empty JSON array of {name, body}'
      using errcode = '22023';
  end if;

  perform 1
  from jsonb_array_elements(p_templates) as t
  where jsonb_typeof(t) <> 'object'
     or coalesce(btrim(t ->> 'name'), '') = ''
     or coalesce(btrim(t ->> 'body'), '') = '';
  if found then
    raise exception
      'bootstrap_instructor: every p_templates entry needs a non-empty name and body'
      using errcode = '22023';
  end if;

  if p_curriculum is not null then
    if jsonb_typeof(p_curriculum) <> 'object'
       or coalesce(btrim(p_curriculum ->> 'name'), '') = '' then
      raise exception 'bootstrap_instructor: p_curriculum needs a non-empty name'
        using errcode = '22023';
    end if;
    if p_curriculum ? 'topics'
       and jsonb_typeof(p_curriculum -> 'topics') <> 'array' then
      raise exception 'bootstrap_instructor: p_curriculum.topics must be an array'
        using errcode = '22023';
    end if;
    perform 1
    from jsonb_array_elements(coalesce(p_curriculum -> 'topics', '[]'::jsonb)) as t
    where jsonb_typeof(t) <> 'object'
       or coalesce(btrim(t ->> 'title'), '') = '';
    if found then
      raise exception 'bootstrap_instructor: every topic needs a non-empty title'
        using errcode = '22023';
    end if;
  end if;

  -- Signup gets retried, by humans and by flaky networks, and a retry of a
  -- call that actually committed must not double-seed. The advisory lock
  -- serialises two concurrent bootstraps of the same account; the `not exists`
  -- guards below make a later call a repair rather than a duplication.
  perform pg_advisory_xact_lock(hashtextextended(v_instructor_id::text, 0));

  -- The ON CONFLICT arbiter is the primary key. (The deferrable unique on
  -- curriculum_topic (curriculum_id, order_index) could never be one — which
  -- is why there is no upsert on topics anywhere below.)
  insert into instructor (id, full_name, phone, email)
  values (v_instructor_id, btrim(p_full_name), btrim(p_phone),
          nullif(btrim(coalesce(p_email, '')), ''))
  on conflict (id) do nothing;
  get diagnostics v_rows = row_count;
  v_created := v_rows = 1;

  -- Seeded only when the tenant has none. Soft-deleted rows count as
  -- existing: a template she deleted on purpose must stay deleted, not be
  -- resurrected by a second sign-in.
  if not exists (select 1 from message_template where tenant_id = v_instructor_id) then
    insert into message_template (tenant_id, name, body, is_system)
    select v_instructor_id, btrim(t ->> 'name'), t ->> 'body', true
    from jsonb_array_elements(p_templates) as t;
    get diagnostics v_template_count = row_count;
  end if;

  if p_curriculum is not null
     and not exists (select 1 from curriculum where tenant_id = v_instructor_id) then
    v_topic_count := jsonb_array_length(coalesce(p_curriculum -> 'topics', '[]'::jsonb));
    v_session_count := coalesce(
      nullif(p_curriculum ->> 'default_session_count', '')::smallint,
      case when v_topic_count between 1 and 40 then v_topic_count::smallint end,
      8::smallint);

    insert into curriculum (tenant_id, name, description, default_session_count)
    values (v_instructor_id,
            btrim(p_curriculum ->> 'name'),
            nullif(btrim(coalesce(p_curriculum ->> 'description', '')), ''),
            v_session_count)
    returning id into v_curriculum_id;

    insert into curriculum_topic (
      tenant_id, curriculum_id, order_index, title, description, estimated_minutes)
    select v_instructor_id,
           v_curriculum_id,
           t.ord::integer,
           btrim(t.value ->> 'title'),
           nullif(btrim(coalesce(t.value ->> 'description', '')), ''),
           nullif(t.value ->> 'estimated_minutes', '')::smallint
    from jsonb_array_elements(coalesce(p_curriculum -> 'topics', '[]'::jsonb))
         with ordinality as t(value, ord);
  end if;

  return query select v_instructor_id, v_created, v_curriculum_id, v_template_count;
end
$fn$;

comment on function public.bootstrap_instructor(text, text, jsonb, text, jsonb) is
  'Atomic signup seed (SDD 6.1, issue #36): instructor row + system message '
  'templates + optional starter curriculum template, in one transaction. '
  'security invoker; the tenant is auth.uid() and is not a parameter. '
  'Idempotent - a retry seeds only what is missing. Writes no access_log row: '
  'the reasoning is in the migration header.';

-- Execute is granted to the signed-in instructor and to nobody else.
-- Notably NOT to service_role: invariant 5 confines the service-role key to
-- the bride portal read path, which has no business creating instructors.
revoke execute on function public.bootstrap_instructor(text, text, jsonb, text, jsonb) from public;
grant  execute on function public.bootstrap_instructor(text, text, jsonb, text, jsonb) to authenticated;
