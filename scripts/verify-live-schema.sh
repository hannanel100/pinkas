#!/usr/bin/env bash
# Verifies, by diff rather than by eye, that:
#   1. supabase/migrations/0001_init.sql is byte-identical to docs/schema.sql;
#   2. every local migration is applied on the linked Supabase project;
#   3. the linked project's schema matches the local migrations exactly,
#      apart from a short, documented allowlist of platform-owned objects
#      (requires Docker for the CLI's shadow database);
#   4. the containment of migration 0008 / ADR-0010 holds on the live
#      project: service_role holds nothing in `public`, portal_reader holds
#      EXECUTE on the three portal_* functions and nothing else anywhere,
#      portal_owner holds only what those functions read, no default
#      privilege re-grants any of them, the portal surface is still seven
#      columns — and, logged in AS portal_reader, `select phone from bride`
#      fails with 42501 (requires LIVE_DB_URL and LIVE_PORTAL_DB_URL).
#
# Run after every `supabase db push`, against whichever project is currently
# linked. Exit 0 = verified. Exit 1 = mismatch. Exit 2 = only partially
# verified (no Docker, or no database URLs for step 4) — do NOT tick the
# acceptance box on exit 2.
#
# Needs: pnpm install done; `pnpm exec supabase link --project-ref <ref>` run;
# psql on PATH; for step 4, two connection strings exported for this shell
# only, from the operator's keychain — never a file, never CI:
#   LIVE_DB_URL         the migration role (`postgres`) on the linked project.
#                       Step 4 runs read-only (default_transaction_read_only).
#   LIVE_PORTAL_DB_URL  the portal_reader login (#56). Step 4 makes one failed
#                       lookup with it, which by design writes nothing.
# Both must point at the SAME project as the link: step 4 checks that each
# URL names the linked project ref, and — where pg_control_system() is
# readable by both roles — that both connections report the same database
# system identifier. The URLs never reach psql's argv with their password:
# it is split off into PGPASSWORD for that one invocation (see pq below).
# docs/runbooks/migrations.md
#
# Self-test of the step-3 filter, no project or Docker needed:
#   bash scripts/verify-live-schema.sh --filter-diff < some-diff.sql
# prints what the allowlist absorbed and what remains; exits 1 if anything
# remains (genuine drift) or if the input held no statement at all.
set -euo pipefail
cd "$(dirname "$0")/.."

# --------------------------------------------------------------------------
# Platform-object allowlist (#31; tightened after the PR #51 review).
#
# A hosted Supabase project injects objects into `public` that no migration
# creates and the CLI's shadow database does not have. They are owned by the
# platform's own role, so migrations neither can nor should manage them; the
# diff must ignore them without going blind to everything else.
#
# The diff is split into complete SQL statements (dollar-quoted bodies kept
# inside their statement). A statement is absorbed only if the WHOLE
# statement has an expected, exact shape — never because it merely mentions
# a platform object. Two kinds of entry:
#
#   PLATFORM_EXACT  — case-insensitive extended regexes that must match the
#                     whole statement, which must be a single line.
#   PLATFORM_PINNED — SHA-256 of a whole multi-line statement (leading blank
#                     lines dropped, trailing whitespace stripped per line).
#                     Used where the statement carries a body: any change to
#                     the body, signature, return type or options changes it.
#
# Entries, all for public.rls_auto_enable() — Supabase's auto-RLS
# event-trigger function, owned by supabase_admin, seen on pinkas-staging (#27):
#   1. Its CREATE OR REPLACE FUNCTION, pinned by hash. The list starts EMPTY
#      on purpose: nobody has captured the live statement yet. On the first
#      run step 3 fails and prints the statement with its hash, labelled an
#      unpinned candidate; a human compares it with Supabase's published
#      definition and, if it matches, pins the hash here in a reviewed
#      commit. Any later change to it is drift until re-pinned.
#   2. GRANT/REVOKE EXECUTE on exactly `"public"."rls_auto_enable"()` to/from
#      exactly one platform role — the platform's own default ACL on its own
#      function. It is an event-trigger function: not callable.
#   3. `set check_function_bodies = off;` — the session setting migra prints
#      before any function definition. Not a schema object.
#
# Not absorbed, deliberately: ALTER (including OWNER TO), DROP or COMMENT on
# it; any other overload; any other function; any grant on our objects —
# 0005 states every one of those explicitly, so a difference is drift.
# Adding an entry is a reviewed change (docs/runbooks/migrations.md).
# --------------------------------------------------------------------------
PLATFORM_EXACT=(
  '(grant|revoke) execute on function "public"\."rls_auto_enable"\(\) (to|from) "(anon|authenticated|service_role|postgres)";'
  'set check_function_bodies = off;'
)
PLATFORM_PINNED=(
  # sha256 of the live `CREATE OR REPLACE FUNCTION public.rls_auto_enable()`
  # statement, pinned after the first reviewed capture (see entry 1).
)
# Recognises a statement that is ABOUT the platform function, only to label
# an unpinned one helpfully. It never absorbs anything.
PLATFORM_CANDIDATE='^create or replace function public\.rls_auto_enable\(\)$'

# Splits SQL on stdin into statements (records separated by NUL), treating
# `;` inside a dollar-quoted body as part of the body. Line-based: migra ends
# every statement with `;` at end of line.
split_statements() {
  awk '
    BEGIN { inq = 0; tag = ""; buf = "" }
    {
      line = $0
      rest = line
      while (match(rest, /\$[A-Za-z_]*\$/)) {
        t = substr(rest, RSTART, RLENGTH)
        if (!inq) { inq = 1; tag = t }
        else if (t == tag) { inq = 0; tag = "" }
        rest = substr(rest, RSTART + RLENGTH)
      }
      buf = (buf == "" ? line : buf "\n" line)
      if (!inq && line ~ /;[[:space:]]*$/) { printf "%s%c", buf, 0; buf = "" }
    }
    END { if (buf ~ /[^[:space:]]/) printf "%s%c", buf, 0 }
  '
}

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1; fi
}

# Reads a diff on stdin. Prints absorbed and remaining statements. Returns 0
# only if every statement was absorbed AND there was at least one: an empty
# diff is judged by the CLI's own "no schema changes" marker, not here.
filter_diff() {
  local stmt norm header hash pattern pin matched drift=0 absorbed=0
  while IFS= read -r -d '' stmt; do
    [[ "$stmt" =~ [^[:space:]] ]] || continue
    norm=$(printf '%s\n' "$stmt" | sed -E 's/[[:space:]]+$//' | sed '/./,$!d')
    header=$(printf '%s\n' "$norm" | head -n 1)
    hash=$(printf '%s\n' "$norm" | sha256_stdin)
    matched=0
    if [[ "$norm" != *$'\n'* ]]; then
      for pattern in "${PLATFORM_EXACT[@]}"; do
        if printf '%s\n' "$norm" | grep -Eqix -- "$pattern"; then matched=1; break; fi
      done
    fi
    for pin in "${PLATFORM_PINNED[@]+"${PLATFORM_PINNED[@]}"}"; do
      if [[ "$hash" == "$pin" ]]; then matched=1; fi
    done
    if (( matched )); then
      absorbed=$((absorbed + 1))
      echo "allowlisted (platform-owned): $header"
    else
      drift=$((drift + 1))
      if printf '%s\n' "$header" | grep -Eqi -- "$PLATFORM_CANDIDATE"; then
        echo "DRIFT (unpinned platform candidate, sha256 $hash - verify against Supabase's definition before pinning):"
      else
        echo "DRIFT:"
      fi
      printf '%s\n' "$norm"
    fi
  done < <(split_statements)
  echo "$absorbed statement(s) allowlisted, $drift statement(s) of drift"
  (( drift == 0 && absorbed > 0 ))
}

if [[ "${1:-}" == "--filter-diff" ]]; then
  filter_diff
  exit $?
fi

# --------------------------------------------------------------------------
# What docs/schema.sql means (#31): the FROZEN INITIAL STATE.
#
# docs/schema.sql is the authoritative Phase 1 schema document and is, byte
# for byte, migration 0001. It is not edited to follow later migrations —
# 0002 onward are expand/contract deltas (docs/runbooks/migrations.md), and
# applied migrations are immutable, so a "current state" copy would be a
# second hand-maintained description that can drift from the first. The
# current schema is 0001 + every later migration in order, which is exactly
# what scripts/test-schema.sh builds and what steps 2 and 3 compare live.
# --------------------------------------------------------------------------
echo "== 1/4 docs/schema.sql vs 0001_init.sql (frozen initial state, byte diff) =="
if diff -u docs/schema.sql supabase/migrations/0001_init.sql; then
  echo "OK: 0001_init.sql is docs/schema.sql, unchanged"
  later=$(find supabase/migrations -maxdepth 1 -name '[0-9][0-9][0-9][0-9]_*.sql' ! -name '0001_*' | wc -l | tr -d ' ')
  echo "    $later later migration(s) are deltas on top of it; steps 2-3 verify them"
else
  echo "FAIL: 0001_init.sql has drifted from docs/schema.sql" >&2
  exit 1
fi

echo
echo "== 2/4 migrations applied on the linked project =="
pnpm exec supabase migration list --linked

echo
echo "== 3/4 live schema vs local migrations (supabase db diff, platform allowlist) =="
partial=0
if ! docker info >/dev/null 2>&1; then
  echo "PARTIAL: Docker is not available, so 'supabase db diff --linked'" >&2
  echo "cannot run its shadow database. The applied schema was NOT verified" >&2
  echo "by diff. Re-run this script where Docker is available." >&2
  partial=1
else

# stdout carries the SQL diff; the CLI's progress lines go to stderr and are
# kept out of the statements being judged.
errlog=$(mktemp)
trap 'rm -f "$errlog"' EXIT
if ! diff_sql=$(pnpm exec supabase db diff --linked --schema public 2>"$errlog"); then
  cat "$errlog" >&2
  echo "FAIL: supabase db diff errored" >&2
  exit 1
fi

# Clean means the CLI SAID so. Empty stdout alone is not evidence: a CLI
# change, a redirected stream or a silent failure would produce it too.
if [[ ! "$diff_sql" =~ [^[:space:]] ]]; then
  if grep -qi "no schema changes found" "$errlog" || printf '%s\n' "$diff_sql" | grep -qi "no schema changes found"; then
    echo "OK: linked project matches local migrations (CLI: no schema changes found)"
  else
    cat "$errlog" >&2
    echo "FAIL: supabase db diff printed no SQL and no 'No schema changes found'" >&2
    echo "      marker; a clean diff cannot be told from a broken one." >&2
    exit 1
  fi
elif printf '%s\n' "$diff_sql" | filter_diff; then
  echo "OK: linked project matches local migrations, apart from allowlisted platform objects"
else
  echo "FAIL: the linked project's schema differs from the local migrations" >&2
  exit 1
fi
fi  # docker available

echo
echo "== 4/4 containment on the live project (0008, ADR-0010) =="
if [[ -z "${LIVE_DB_URL:-}" || -z "${LIVE_PORTAL_DB_URL:-}" ]]; then
  echo "PARTIAL: LIVE_DB_URL and LIVE_PORTAL_DB_URL must both be exported for" >&2
  echo "step 4. Containment was NOT verified on the live project." >&2
  exit 2
fi
if ! command -v psql >/dev/null 2>&1; then
  echo "PARTIAL: psql is not on PATH; containment was NOT verified." >&2
  exit 2
fi

# Runs psql against a connection URL without putting its password on the
# command line (argv is world-readable through /proc and `ps`): the password
# is percent-decoded into PGPASSWORD, set for this one invocation only, and
# the URL psql sees carries user, host and options but no secret.
pq() {
  local url=$1 bare pw=""
  shift
  bare=$url
  if [[ "$url" =~ ^(postgres(ql)?://)([^:/@?#]*):([^@/?#]*)@(.*)$ ]]; then
    bare="${BASH_REMATCH[1]}${BASH_REMATCH[3]}@${BASH_REMATCH[5]}"
    pw="${BASH_REMATCH[4]}"
    pw=$(printf '%b' "${pw//%/\\x}")
  fi
  PGPASSWORD="${pw:-${PGPASSWORD:-}}" psql "$bare" "$@"
}

# 4a. Catalogue, as the migration role, read-only. Every violation is
# collected and printed; any violation fails the step. Objects owned by a
# platform role (e.g. supabase_admin's public.rls_auto_enable(), see the
# allowlist above) are reported as NOTE lines, never silently skipped.
if ! PGOPTIONS='-c default_transaction_read_only=on' pq "$LIVE_DB_URL" \
     -X -q -v ON_ERROR_STOP=1 -At <<'SQL'
do $$
declare
  bad  text[] := '{}';
  r    record;
  role text;
  me   regrole := current_user::regrole;
  portal_fns regprocedure[] := array[
    'public.portal_resolve_token(bytea,uuid)'::regprocedure,
    'public.portal_sessions(bytea,uuid)'::regprocedure,
    'public.portal_rate_limit_hit(bytea,bytea,integer)'::regprocedure];
  ok_cols text[] := array[
    'bride.id','bride.tenant_id','bride.first_name','bride.portal_token_hash',
    'bride.portal_expires_at','bride.deleted_at',
    'session.id','session.course_id','session.order_index','session.scheduled_at',
    'session.duration_minutes','session.location','session.status','session.deleted_at',
    'course.id','course.bride_id','course.deleted_at'];
begin
  -- the roles
  for r in select * from pg_roles where rolname in ('portal_owner','portal_reader') loop
    if r.rolsuper or r.rolbypassrls or r.rolcreaterole or r.rolcreatedb or r.rolreplication then
      bad := bad || format('%s has an elevated attribute', r.rolname);
    end if;
    if r.rolname = 'portal_owner' and r.rolcanlogin then bad := bad || 'portal_owner can log in'::text; end if;
    if r.rolname = 'portal_reader' and r.rolinherit then bad := bad || 'portal_reader is INHERIT'::text; end if;
    if exists (select 1 from pg_auth_members m where m.member = r.oid) then
      bad := bad || format('%s is a member of another role', r.rolname);
    end if;
  end loop;
  if (select count(*) from pg_roles where rolname in ('portal_owner','portal_reader')) <> 2 then
    bad := bad || 'portal_owner / portal_reader missing (is 0008 applied?)'::text;
  end if;

  -- service_role and portal_reader: no relation privilege in public; and
  -- portal_reader none in ANY schema outside the system catalogs
  foreach role in array array['service_role','portal_reader','portal_owner'] loop
    for r in
      select c.oid::regclass as obj, c.relname, c.relkind, n.nspname,
             c.relowner::regrole::text as owner
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where c.relkind in ('r','p','v','m','f','S')
        and n.nspname not in ('pg_catalog','information_schema')
        and n.nspname not like 'pg_toast%' and n.nspname not like 'pg_temp%'
        and (n.nspname = 'public' or role <> 'service_role')
    loop
      if r.relkind = 'S' then
        if has_sequence_privilege(role, r.obj, 'USAGE,SELECT,UPDATE') then
          bad := bad || format('%s holds a privilege on sequence %s (owner %s)', role, r.obj, r.owner);
        end if;
        continue;
      end if;
      if role = 'portal_owner' and r.nspname = 'public' then
        -- exactly the portal's needs (0008)
        if r.relname in ('portal_bride_view','portal_session_view') then
          if has_table_privilege(role, r.obj, 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') then
            bad := bad || format('portal_owner holds more than SELECT on %s', r.obj);
          end if;
          continue;
        elsif r.relname = 'access_log' then
          if has_table_privilege(role, r.obj, 'SELECT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') then
            bad := bad || 'portal_owner holds more than INSERT on access_log'::text;
          end if;
          continue;
        elsif r.relname = 'portal_rate_limit' then
          if has_table_privilege(role, r.obj, 'DELETE,TRUNCATE,REFERENCES,TRIGGER') then
            bad := bad || 'portal_owner holds more than SELECT/INSERT/UPDATE on portal_rate_limit'::text;
          end if;
          continue;
        elsif r.relname in ('bride','session','course') then
          if has_table_privilege(role, r.obj, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') then
            bad := bad || format('portal_owner holds a table-level privilege on %s', r.obj);
          end if;
          continue;  -- columns checked below
        end if;
      end if;
      if has_table_privilege(role, r.obj, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
         or has_any_column_privilege(role, r.obj, 'SELECT,INSERT,UPDATE,REFERENCES') then
        bad := bad || format('%s holds a privilege on %s (owner %s)', role, r.obj, r.owner);
      end if;
    end loop;
  end loop;

  for r in
    select c.relname || '.' || a.attname as col
    from pg_attribute a join pg_class c on c.oid = a.attrelid
    where c.oid in ('public.bride'::regclass,'public.session'::regclass,'public.course'::regclass)
      and a.attnum > 0 and not a.attisdropped
      and has_column_privilege('portal_owner', a.attrelid, a.attnum, 'SELECT')
  loop
    if not (r.col = any (ok_cols)) then
      bad := bad || format('portal_owner can SELECT %s', r.col);
    end if;
  end loop;

  -- functions in public
  for r in
    select p.oid::regprocedure as fn, p.proowner::regrole::text as owner
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.prokind in ('f','p')
      and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass
                      and d.objid = p.oid and d.deptype = 'e')
  loop
    if has_function_privilege('portal_reader', r.fn, 'EXECUTE') <> (r.fn = any (portal_fns)) then
      bad := bad || format('portal_reader EXECUTE on %s is %s', r.fn,
                           has_function_privilege('portal_reader', r.fn, 'EXECUTE'));
    end if;
    if has_function_privilege('service_role', r.fn, 'EXECUTE') then
      if r.owner = me::text or r.owner in ('portal_owner','session_record_reader') then
        bad := bad || format('service_role can execute %s', r.fn);
      else
        raise notice 'NOTE: service_role can execute platform-owned % (owner %) - not ours to revoke', r.fn, r.owner;
      end if;
    end if;
  end loop;
  for r in
    select p.oid::regprocedure as fn, p.proowner::regrole::text as owner
    from pg_proc p
    where p.oid = any (portal_fns)
  loop
    if r.owner <> 'portal_owner' then
      bad := bad || format('%s is owned by %s, expected portal_owner', r.fn, r.owner);
    end if;
  end loop;

  -- default privileges of the migration role in public
  for r in
    select d.defaclobjtype, a.grantee::regrole::text as grantee, d.defaclrole::regrole::text as definer
    from pg_default_acl d, aclexplode(d.defaclacl) a
    where d.defaclnamespace = 'public'::regnamespace
      and a.grantee in ('service_role'::regrole, 'portal_reader'::regrole,
                        'portal_owner'::regrole, 'anon'::regrole)
  loop
    if r.definer = me::text then
      bad := bad || format('default privileges of %s in public grant %s on objtype %s',
                           r.definer, r.grantee, r.defaclobjtype);
    else
      raise notice 'NOTE: platform role % default-grants % on objtype % in public', r.definer, r.grantee, r.defaclobjtype;
    end if;
  end loop;

  -- membership: nobody but the migration role (or a superuser) may act as a
  -- portal role, directly or through another role (security review of #61)
  for r in
    select g.rolname, t.portal
    from pg_roles g, (values ('portal_owner'), ('portal_reader')) t(portal)
    where pg_has_role(g.oid, t.portal::regrole, 'MEMBER')
      and g.rolname <> t.portal and g.oid <> me and not g.rolsuper
  loop
    bad := bad || format('%s is a member of %s', r.rolname, r.portal);
  end loop;

  -- every other schema: what the portal roles can reach outside public.
  -- A grant made TO the role is a failure; one inherited from PUBLIC is a
  -- platform/Postgres default and is reported, not judged.
  foreach role in array array['portal_reader','portal_owner'] loop
    for r in
      select n.oid, n.nspname, n.nspacl
      from pg_namespace n
      where n.nspname not in ('pg_catalog','information_schema','public')
        and n.nspname not like 'pg_toast%' and n.nspname not like 'pg_temp%'
    loop
      if exists (select 1 from aclexplode(coalesce(r.nspacl, acldefault('n', 0))) a
                 where a.grantee = role::regrole) then
        bad := bad || format('%s holds a direct grant on schema %s', role, r.nspname);
      end if;
      if has_schema_privilege(role, r.oid, 'CREATE') then
        raise notice 'NOTE: % can CREATE in schema % (via PUBLIC)', role, r.nspname;
      end if;
      if has_schema_privilege(role, r.oid, 'USAGE') then
        raise notice 'NOTE: % has USAGE on schema % (via PUBLIC); % function(s) there are executable by it',
          role, r.nspname,
          (select count(*) from pg_proc p
           where p.pronamespace = r.oid and has_function_privilege(role, p.oid, 'EXECUTE'));
      end if;
      if exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                 where p.pronamespace = r.oid and a.grantee = role::regrole) then
        bad := bad || format('%s holds a direct EXECUTE grant on a function in schema %s', role, r.nspname);
      end if;
    end loop;

    -- the database itself: TEMP comes through PUBLIC on every Postgres
    -- database; the portal functions are immune to it (search_path pinned,
    -- names qualified), so it is reported, not failed. A direct grant fails.
    if exists (select 1 from pg_database d, aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a
               where d.datname = current_database() and a.grantee = role::regrole) then
      bad := bad || format('%s holds a direct grant on the database', role);
    end if;
    if has_database_privilege(role, current_database(), 'TEMP') then
      raise notice 'NOTE: % holds TEMP on the database (via PUBLIC; neutralised by the functions'' search_path)', role;
    end if;
  end loop;

  -- global default privileges (not per schema): the migration role must
  -- keep 0005's removal of PUBLIC's EXECUTE on new functions, and must not
  -- default-grant anything to the contained roles anywhere.
  if not exists (select 1 from pg_default_acl d
                 where d.defaclrole = me and d.defaclnamespace = 0 and d.defaclobjtype = 'f')
     or exists (select 1 from pg_default_acl d, aclexplode(d.defaclacl) a
                where d.defaclrole = me and d.defaclnamespace = 0 and d.defaclobjtype = 'f'
                  and a.grantee = 0) then
    bad := bad || 'global default privileges of the migration role give PUBLIC EXECUTE on new functions (0005 removed it)'::text;
  end if;
  for r in
    select d.defaclobjtype, d.defaclrole::regrole::text as definer,
           case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end as grantee
    from pg_default_acl d, aclexplode(d.defaclacl) a
    where d.defaclnamespace = 0
      and a.grantee in (0, 'service_role'::regrole, 'portal_reader'::regrole,
                        'portal_owner'::regrole, 'anon'::regrole, 'authenticated'::regrole)
      and a.grantee <> d.defaclrole
  loop
    if r.definer = me::text and r.grantee <> 'PUBLIC' then
      bad := bad || format('global default privileges of %s grant %s on objtype %s',
                           r.definer, r.grantee, r.defaclobjtype);
    elsif r.definer <> me::text then
      raise notice 'NOTE: platform role % globally default-grants % on objtype %', r.definer, r.grantee, r.defaclobjtype;
    end if;
  end loop;

  -- the portal surface is still exactly seven columns
  if (select string_agg(column_name, ',' order by ordinal_position)
      from information_schema.columns
      where table_schema = 'public' and table_name = 'portal_session_view')
     is distinct from 'id,bride_id,order_index,scheduled_at,duration_minutes,location,status' then
    bad := bad || 'portal_session_view is not the seven-column surface'::text;
  end if;

  if cardinality(bad) > 0 then
    raise exception E'containment violated:\n  %', array_to_string(bad, E'\n  ');
  end if;
  raise notice 'OK: catalogue containment holds';
end $$;
SQL
then
  echo "FAIL: containment does not hold on the live project (catalogue)" >&2
  exit 1
fi

# 4b. Behaviour, logged in as portal_reader. Both URLs must name the linked
# project: the CLI records its ref in supabase/.temp/project-ref, and every
# Supabase connection string carries it (db.<ref>.supabase.co, or the pooler
# user <role>.<ref>).
ref_file=supabase/.temp/project-ref
if [[ ! -s "$ref_file" ]]; then
  echo "FAIL: $ref_file is missing; cannot tell which project step 4 must check" >&2
  exit 1
fi
linked_ref=$(tr -d '[:space:]' < "$ref_file")
for var in LIVE_DB_URL LIVE_PORTAL_DB_URL; do
  if [[ "${!var}" != *"$linked_ref"* ]]; then
    echo "FAIL: $var does not point at the linked project ($linked_ref)" >&2
    exit 1
  fi
done
who=$(pq "$LIVE_PORTAL_DB_URL" -X -q -At -c "select current_user" 2>&1 || true)
if [[ "$who" != "portal_reader" ]]; then
  echo "FAIL: LIVE_PORTAL_DB_URL did not log in as portal_reader: $who" >&2
  exit 1
fi
sysid_sql="select system_identifier from pg_control_system()"
sysid_admin=$(pq "$LIVE_DB_URL" -X -q -At -c "$sysid_sql" 2>/dev/null || true)
sysid_portal=$(pq "$LIVE_PORTAL_DB_URL" -X -q -At -c "$sysid_sql" 2>/dev/null || true)
if [[ -n "$sysid_admin" && -n "$sysid_portal" ]]; then
  if [[ "$sysid_admin" != "$sysid_portal" ]]; then
    echo "FAIL: LIVE_DB_URL and LIVE_PORTAL_DB_URL reach different database systems" >&2
    exit 1
  fi
  echo "OK: both connections reach database system $sysid_admin"
else
  echo "NOTE: pg_control_system() is not readable by both roles; same-project check rests on the project ref"
fi

expect_42501() {
  local label=$1 sql=$2 out
  out=$(pq "$LIVE_PORTAL_DB_URL" -X -q -At -v VERBOSITY=sqlstate -c "$sql" 2>&1 || true)
  if [[ "$out" == *"42501"* ]]; then
    echo "OK: as portal_reader, $label -> 42501"
  else
    echo "FAIL: as portal_reader, $label was not refused with 42501: $out" >&2
    exit 1
  fi
}
expect_42501 "select phone from bride"            "select phone from public.bride limit 1"
expect_42501 "select from portal_session_view"    "select 1 from public.portal_session_view limit 1"
expect_42501 "select from session_record"         "select session_id from public.session_record limit 1"
expect_42501 "select from access_log"             "select 1 from public.access_log limit 1"

# A lookup of a hash no bride can hold: zero rows, and — by design — no
# access_log row, so this is safe on production.
n=$(pq "$LIVE_PORTAL_DB_URL" -X -q -At -v ON_ERROR_STOP=1 \
      -c "select count(*) from public.portal_resolve_token(sha256('verify-live-schema: not a token'), gen_random_uuid())" 2>&1) || {
  echo "FAIL: as portal_reader, portal_resolve_token could not be called: $n" >&2
  exit 1
}
if [[ "$n" != "0" ]]; then
  echo "FAIL: a hash no bride holds resolved to $n row(s)" >&2
  exit 1
fi
echo "OK: as portal_reader, portal_resolve_token is callable and resolves nothing for an unknown hash"

if (( partial )); then
  echo "PARTIAL: steps 1, 2 and 4 verified; step 3 (schema diff) did not run" >&2
  exit 2
fi
echo "OK: all four steps verified"
