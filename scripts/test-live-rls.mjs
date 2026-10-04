#!/usr/bin/env node
/**
 * Live RLS verification: the docs/schema.test.sql assertions, driven by real
 * authenticated JWTs against a real Supabase project through PostgREST.
 *
 * CI proves the isolation design against schema.bootstrap.sql, which emulates
 * auth.uid() and the Supabase roles. This script is the other half: the same
 * assertions carried by a JWT that Supabase Auth actually issued and verified.
 *
 * Modes (PINKAS_LIVE_TEST):
 *   staging         Full suite. Creates two throwaway auth users, seeds the
 *                   docs/schema.test.sql fixtures through each tenant's own
 *                   JWT, runs the assertions with real JWTs, then deletes
 *                   everything it created except its access_log rows. The
 *                   service key is used for auth.admin (createUser /
 *                   deleteUser) ONLY: since migration 0008 (#53, ADR-0010)
 *                   it holds no privilege in `public`, which this mode also
 *                   asserts. Writes data: staging only, never production.
 *   prod-anon-only  Read-only. Asserts the anon key without a JWT reads zero
 *                   rows from every table and view. Needs no service key and
 *                   is safe against production.
 *
 * Environment (exported in the operator's shell for one run, never a file —
 * see docs/runbooks/provisioning.md):
 *   LIVE_SUPABASE_URL
 *   LIVE_SUPABASE_ANON_KEY
 *   LIVE_SUPABASE_SERVICE_ROLE_KEY   staging mode only, auth.admin only — the
 *                                    staging key; no deployed environment
 *                                    holds any service key (ADR-0010 §3)
 *
 * Two schema.test.sql assertions cannot be expressed through PostgREST and
 * remain covered only by the CI bootstrap run — called out here rather than
 * quietly dropped:
 *   1. The information_schema check that the private fields (private_note,
 *      needs_review_note, covered_topic_ids) exist in exactly one relation.
 *      Since 0008 the portal views are not readable through PostgREST at all;
 *      portal_session_view's seven-column surface, and the portal_reader
 *      login's containment, are asserted live by scripts/verify-live-schema.sh
 *      step 4 over a direct database connection instead.
 *   2. Distinguishing SQLSTATE insufficient_privilege from an RLS WITH CHECK
 *      violation: PostgREST surfaces both as error code 42501.
 */
import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";

const MODE = process.env.PINKAS_LIVE_TEST;
const url = required("LIVE_SUPABASE_URL");
const anonKey = required("LIVE_SUPABASE_ANON_KEY");

const failures = [];
let passes = 0;

function required(name) {
  const v = process.env[name];
  if (!v) {
    console.error(`Missing environment variable: ${name}`);
    process.exit(1);
  }
  return v;
}

function check(ok, label, detail = "") {
  if (ok) {
    passes += 1;
    console.log(`PASS  ${label}`);
  } else {
    failures.push(label);
    console.error(`FAIL  ${label}${detail ? ` — ${detail}` : ""}`);
  }
}

function note(msg) {
  console.log(`NOTE  ${msg}`);
}

function anonClient() {
  return createClient(url, anonKey, { auth: { persistSession: false } });
}

const RELATIONS = [
  "instructor",
  "curriculum",
  "curriculum_topic",
  "bride",
  "course",
  "session",
  "session_record",
  "material",
  "payment",
  "message_template",
  "message_log",
  "blackout_date",
  "access_log",
  "portal_session_view",
  "v_course_risk",
];

const DAY_MS = 86_400_000;
const dateFromToday = (n) => new Date(Date.now() + n * DAY_MS).toISOString().slice(0, 10);
const tsFromNow = (n) => new Date(Date.now() + n * DAY_MS).toISOString();

async function anonReadsNothing() {
  console.log("== anon key, no JWT: every relation must yield nothing ==");
  for (const rel of RELATIONS) {
    const { data, error } = await anonClient().from(rel).select("*").limit(1);
    if (error) {
      check(true, `anon ${rel}: denied (${error.code ?? error.message})`);
    } else if ((data ?? []).length === 0) {
      check(true, `anon ${rel}: zero rows`);
      // A live project's default privileges can grant anon table access that
      // schema.sql never granted explicitly; RLS still returns zero rows.
      note(`anon holds a grant on ${rel} — revoking from anon is a database-agent call`);
    } else {
      check(false, `anon ${rel}`, `returned ${data.length} row(s) without a JWT`);
    }
  }
}

async function createUser(admin, email, password) {
  const { data, error } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  if (error) {
    const detail = [error.status && `status=${error.status}`, error.code && `code=${error.code}`]
      .filter(Boolean)
      .join(" ");
    throw new Error(`createUser ${email}: ${detail} ${error.message || JSON.stringify(error)}`);
  }
  return data.user;
}

async function seed(client, table, rows) {
  const { error } = await client.from(table).insert(rows);
  if (error) throw new Error(`seed ${table}: ${error.code ?? ""} ${error.message}`);
}

async function signIn(email, password) {
  const client = anonClient();
  const { error } = await client.auth.signInWithPassword({ email, password });
  if (error) throw new Error(`sign-in ${email} failed: ${error.message}`);
  return client;
}

// A PostgREST call refused by privilege. Since 0008 (#53) the service key
// holds nothing in `public`, and the portal objects are reachable by the
// portal_reader database login only — never through PostgREST.
function refused(res) {
  return !!res.error && (res.data ?? null) === null;
}

async function fullSuite() {
  const serviceKey = required("LIVE_SUPABASE_SERVICE_ROLE_KEY");
  // auth.admin ONLY (createUser / deleteUser). Since migration 0008 the
  // service key holds no privilege in `public`, so it cannot seed; each
  // tenant seeds its own rows through its own JWT, under the same grants and
  // policies the product uses.
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

  const runTag = Date.now();
  // One request id for every access_log row this run writes on purpose, so
  // the rows it leaves behind (see cleanup) can be told apart.
  const runRequestId = randomUUID();
  const emailA = `pinkas-rls-a-${runTag}@example.com`;
  const emailB = `pinkas-rls-b-${runTag}@example.com`;
  // bcrypt truncates at 72 bytes and GoTrue 500s beyond it — keep under the limit
  const password = `${randomUUID()}.${randomUUID()}`.slice(0, 64);

  console.log("\n== creating throwaway auth users (real auth.uid values) ==");
  const A = (await createUser(admin, emailA, password)).id;
  const B = (await createUser(admin, emailB, password)).id;
  const signedIn = {};

  const ids = {
    brideA: randomUUID(),
    brideB: randomUUID(),
    courseA: randomUUID(),
    courseB: randomUUID(),
    sessionA: randomUUID(),
    sessionB: randomUUID(),
    brideCrit: randomUUID(),
    brideHigh: randomUUID(),
    brideMed: randomUUID(),
    brideInfo: randomUUID(),
    brideNone: randomUUID(),
    courseCrit: randomUUID(),
    courseHigh: randomUUID(),
    courseMed: randomUUID(),
    courseInfo: randomUUID(),
    courseNone: randomUUID(),
  };

  try {
    console.log("== signing in as tenants A and B (real verified JWTs) ==");
    const a = await signIn(emailA, password);
    signedIn[A] = a;
    const b = await signIn(emailB, password);
    signedIn[B] = b;
    const { data: userData, error: userErr } = await a.auth.getUser();
    check(!userErr && userData?.user?.id === A, "JWT sub resolves to the created auth user (auth.uid source)");

    console.log("== seeding the schema.test.sql fixtures, each tenant through its own JWT ==");
    await seed(a, "instructor", [{ id: A, full_name: "Michal (tenant A)", phone: "050-0000001" }]);
    await seed(b, "instructor", [{ id: B, full_name: "Sara  (tenant B)", phone: "050-0000002" }]);
    await seed(a, "bride", [
      { id: ids.brideA, tenant_id: A, first_name: "Noa", wedding_date: dateFromToday(34), status: "active" },
      { id: ids.brideCrit, tenant_id: A, first_name: "Crit", wedding_date: dateFromToday(28), status: "active" },
      { id: ids.brideHigh, tenant_id: A, first_name: "High", wedding_date: dateFromToday(214), status: "active" },
      { id: ids.brideMed, tenant_id: A, first_name: "Med", wedding_date: dateFromToday(214), status: "active" },
      { id: ids.brideInfo, tenant_id: A, first_name: "Info", wedding_date: dateFromToday(20), status: "active" },
      { id: ids.brideNone, tenant_id: A, first_name: "None", wedding_date: dateFromToday(214), status: "active" },
    ]);
    await seed(b, "bride", [
      { id: ids.brideB, tenant_id: B, first_name: "Rivka", wedding_date: dateFromToday(60), status: "active" },
    ]);
    await seed(a, "course", [
      { id: ids.courseA, tenant_id: A, bride_id: ids.brideA, curriculum_snapshot: { topics: [] }, target_end_date: dateFromToday(20), status: "active" },
      { id: ids.courseCrit, tenant_id: A, bride_id: ids.brideCrit, curriculum_snapshot: {}, target_end_date: dateFromToday(14), status: "active" },
      { id: ids.courseHigh, tenant_id: A, bride_id: ids.brideHigh, curriculum_snapshot: {}, target_end_date: dateFromToday(200), status: "active" },
      { id: ids.courseMed, tenant_id: A, bride_id: ids.brideMed, curriculum_snapshot: {}, target_end_date: dateFromToday(200), status: "active" },
      { id: ids.courseInfo, tenant_id: A, bride_id: ids.brideInfo, curriculum_snapshot: {}, target_end_date: dateFromToday(6), status: "active" },
      { id: ids.courseNone, tenant_id: A, bride_id: ids.brideNone, curriculum_snapshot: {}, target_end_date: dateFromToday(200), status: "active" },
    ]);
    await seed(b, "course", [
      { id: ids.courseB, tenant_id: B, bride_id: ids.brideB, curriculum_snapshot: { topics: [] }, target_end_date: dateFromToday(46), status: "active" },
    ]);
    // Every row needs an explicit id: PostgREST unifies columns across a bulk
    // insert, so rows missing a key get an explicit null instead of the default.
    const sessionsA = [
      { id: ids.sessionA, tenant_id: A, course_id: ids.courseA, order_index: 1, scheduled_at: tsFromNow(1), location: "Herzl 14", status: "planned" },
    ];
    for (let g = 1; g <= 5; g += 1) {
      sessionsA.push({ id: randomUUID(), tenant_id: A, course_id: ids.courseCrit, order_index: g, scheduled_at: tsFromNow(g), location: null, status: "planned" });
    }
    sessionsA.push(
      { id: randomUUID(), tenant_id: A, course_id: ids.courseHigh, order_index: 1, scheduled_at: tsFromNow(-10), location: null, status: "cancelled" },
      { id: randomUUID(), tenant_id: A, course_id: ids.courseHigh, order_index: 2, scheduled_at: tsFromNow(3), location: null, status: "planned" },
      { id: randomUUID(), tenant_id: A, course_id: ids.courseMed, order_index: 1, scheduled_at: tsFromNow(-30), location: null, status: "done" },
      { id: randomUUID(), tenant_id: A, course_id: ids.courseMed, order_index: 2, scheduled_at: tsFromNow(3), location: null, status: "planned" },
      { id: randomUUID(), tenant_id: A, course_id: ids.courseInfo, order_index: 1, scheduled_at: tsFromNow(-2), location: null, status: "done" },
      { id: randomUUID(), tenant_id: A, course_id: ids.courseNone, order_index: 1, scheduled_at: tsFromNow(-2), location: null, status: "done" },
      { id: randomUUID(), tenant_id: A, course_id: ids.courseNone, order_index: 2, scheduled_at: tsFromNow(3), location: null, status: "planned" },
    );
    await seed(a, "session", sessionsA);
    await seed(b, "session", [
      { id: ids.sessionB, tenant_id: B, course_id: ids.courseB, order_index: 1, scheduled_at: tsFromNow(2), location: "Weizmann 3", status: "planned" },
    ]);
    // session_record's write path is the upsert function (0006), not the table.
    for (const [client, sessionId, who] of [[a, ids.sessionA, "A"], [b, ids.sessionB, "B"]]) {
      const { error } = await client.rpc("upsert_session_record", {
        p_session_id: sessionId,
        p_covered_topic_ids: [],
        p_private_note: `${who} private note`,
        p_needs_review_note: `${who} review note`,
      });
      if (error) throw new Error(`seed session_record ${who}: ${error.code ?? ""} ${error.message}`);
    }

    console.log("\n== the service key holds nothing in public (0008, ADR-0010) ==");
    for (const rel of ["bride", "course", "session", "session_record", "payment", "access_log", "portal_session_view", "instructor"]) {
      const res = await admin.from(rel).select("*").limit(1);
      check(
        refused(res) && res.error.code === "42501",
        `service key: ${rel} refused (42501)`,
        res.error ? `${res.error.code} ${res.error.message}` : `read ${res.data?.length} row(s)`,
      );
    }
    {
      const res = await admin.from("bride").insert({ tenant_id: A, first_name: "ServiceKeyWrite" }).select("id");
      check(refused(res), "service key: insert into bride refused", res.error ? "" : `inserted ${res.data?.length}`);
    }
    for (const [who, client] of [["service key", admin], ["instructor JWT", a]]) {
      const res = await client.rpc("portal_resolve_token", {
        p_token_hash: "\\x" + "00".repeat(32),
        p_request_id: randomUUID(),
      });
      check(refused(res), `${who}: portal_resolve_token not callable through PostgREST`, res.error ? "" : "call succeeded");
    }

    console.log("\n== tenant isolation, view invocation, write-side checks ==");
    {
      const { data, error } = await a.from("bride").select("id");
      check(!error && data?.length === 6, "tenant A sees exactly its own 6 brides", error?.message ?? `got ${data?.length}`);
    }
    {
      const { data, error } = await a.from("bride").select("id").eq("id", ids.brideB);
      check(!error && data?.length === 0, "tenant B bride invisible even addressed by primary key");
    }
    {
      // #34: the private columns are not readable through PostgREST at all;
      // the only read path is the audited reader, which must still be
      // tenant-scoped (a reader that leaked would be a hole with a log).
      const direct = await a.from("session_record").select("session_id, private_note");
      check(
        !!direct.error && direct.error.code === "42501",
        "session_record.private_note is not directly readable (column revoked)",
        direct.error ? `${direct.error.code} ${direct.error.message}` : `read ${direct.data?.length} row(s)`,
      );
      const rec = await a.from("session_record").select("session_id");
      check(!rec.error && rec.data?.length === 1, "session_record non-private columns: tenant A sees exactly one row", rec.error?.message ?? `got ${rec.data?.length}`);
      const both = await a.rpc("read_session_records", {
        p_session_ids: [ids.sessionA, ids.sessionB],
        p_request_id: runRequestId,
      });
      const leaked = (both.data ?? []).some((r) => (r.private_note ?? "").startsWith("B "));
      check(!both.error && both.data?.length === 1 && !leaked, "audited reader: tenant A gets its own note, no tenant B note", both.error?.message ?? `got ${both.data?.length}`);
      const onlyB = await a.rpc("read_session_records", {
        p_session_ids: [ids.sessionB],
        p_request_id: runRequestId,
      });
      check(!onlyB.error && onlyB.data?.length === 0, "audited reader: tenant B's record by primary key is zero rows", onlyB.error?.message ?? `got ${onlyB.data?.length}`);
    }
    {
      const { data, error } = await a.from("v_course_risk").select("course_id");
      check(!error && data?.length === 6, "v_course_risk respects caller RLS (security_invoker)", error?.message ?? `got ${data?.length}`);
    }
    {
      // 0008: the portal views have no direct reader but portal_owner.
      const res = await a.from("portal_session_view").select("id").eq("bride_id", ids.brideB);
      check(refused(res) && res.error.code === "42501", "portal_session_view is refused to an instructor JWT (0008)", res.error ? `${res.error.code}` : `read ${res.data?.length} row(s)`);
    }
    {
      const { error } = await a.from("bride").insert({ tenant_id: B, first_name: "Injected" });
      check(!!error, "insert under a foreign tenant_id is rejected", "insert unexpectedly succeeded");
    }
    {
      const { data, error } = await a.from("bride").update({ first_name: "Hacked" }).eq("id", ids.brideB).select("id");
      check(!error && data?.length === 0, "update of a tenant B row affects zero rows", error?.message ?? `updated ${data?.length}`);
    }
    {
      const { error } = await a.from("access_log").insert({
        tenant_id: A,
        actor_kind: "instructor",
        actor_id: A,
        bride_id: ids.brideA,
        action: "read",
        resource: "bride",
        request_id: runRequestId,
      });
      check(!error, "access_log accepts the tenant's own insert", error?.message);
      const del = await a.from("access_log").delete().eq("tenant_id", A).select("id");
      if (del.error) {
        check(true, `access_log delete denied (${del.error.code ?? del.error.message})`);
      } else if ((del.data ?? []).length === 0) {
        check(true, "access_log delete affected zero rows");
        note("expected a privilege denial, got a policy filter — flag to the database agent");
      } else {
        check(false, "access_log is append-only", `deleted ${del.data.length} row(s)`);
      }
    }

    console.log("\n== Prefer: tx=rollback must not apply (db-tx-end, ADR-0010 §5) ==");
    {
      // If PostgREST honoured tx=rollback, a caller would receive the rows of
      // read_session_records while its access_log row rolled back. Supabase is
      // expected to run PostgREST's default db-tx-end = commit, which ignores
      // the preference (lenient) or rejects it (handling=strict, PGRST122).
      const { data: sess } = await a.auth.getSession();
      const token = sess?.session?.access_token;
      const call = async (prefer, requestId) =>
        fetch(`${url}/rest/v1/rpc/read_session_records`, {
          method: "POST",
          headers: {
            apikey: anonKey,
            Authorization: `Bearer ${token}`,
            "Content-Type": "application/json",
            Prefer: prefer,
          },
          body: JSON.stringify({ p_session_ids: [ids.sessionA], p_request_id: requestId }),
        });
      const countLog = async (requestId) => {
        const { data, error } = await a.from("access_log").select("id").eq("request_id", requestId);
        return error ? `error ${error.message}` : data.length;
      };

      const strictId = randomUUID();
      const strict = await call("tx=rollback, handling=strict", strictId);
      const strictBody = await strict.text();
      const strictApplied = (strict.headers.get("preference-applied") ?? "").includes("tx=rollback");
      const strictLog = await countLog(strictId);
      check(
        !strictApplied && (strict.status === 400 ? strictLog === 0 : strictLog === 1),
        "strict: tx=rollback is refused or not applied, and the log matches what was returned",
        `status ${strict.status}, applied=${strictApplied}, log rows ${strictLog}, body ${strictBody.slice(0, 120)}`,
      );

      const lenientId = randomUUID();
      const lenient = await call("tx=rollback", lenientId);
      const lenientRows = lenient.ok ? (await lenient.json()).length : -1;
      const lenientApplied = (lenient.headers.get("preference-applied") ?? "").includes("tx=rollback");
      const lenientLog = await countLog(lenientId);
      check(
        lenient.ok && lenientRows === 1 && !lenientApplied && lenientLog === 1,
        "lenient: rows returned under tx=rollback are still logged (exactly one access_log row)",
        `status ${lenient.status}, rows ${lenientRows}, applied=${lenientApplied}, log rows ${lenientLog}`,
      );
    }

    console.log("\n== risk tiers ==");
    const want = new Map([
      [ids.courseCrit, ["critical", "wont_finish_in_time"]],
      [ids.courseHigh, ["high", "cancelled_not_rescheduled"]],
      [ids.courseMed, ["medium", "no_recent_session"]],
      [ids.courseInfo, ["info", "wedding_approaching"]],
      [ids.courseNone, ["none", null]],
    ]);
    const { data: riskRows, error: riskErr } = await a
      .from("v_course_risk")
      .select("course_id, risk_level, risk_reason_code")
      .in("course_id", [...want.keys()]);
    check(!riskErr && riskRows?.length === want.size, "risk view returns all five fixture courses", riskErr?.message ?? `got ${riskRows?.length}`);
    for (const row of riskRows ?? []) {
      const [level, reason] = want.get(row.course_id) ?? [];
      const got = `${row.risk_level}/${row.risk_reason_code ?? "-"}`;
      const wanted = `${level}/${reason ?? "-"}`;
      check(got === wanted, `risk tier ${wanted}`, `got ${got}`);
    }
  } finally {
    console.log("\n== cleanup ==");
    await cleanup(admin, signedIn, [A, B], runRequestId);
  }
}

async function cleanup(admin, signedIn, tenantIds, runRequestId) {
  // Each tenant deletes her own instructor row through her own JWT; that
  // cascades through every tenant-scoped FK (cascades run as the table owner,
  // not under the caller's privileges). access_log has no FK and is
  // deliberately LEFT BEHIND: nobody — instructor, service key or portal —
  // can delete from it, and the log is designed to outlive the data it
  // describes. Staging holds fake data only; the rows are identifiable by the
  // tenant ids and the run's request id printed here.
  for (const id of tenantIds) {
    const client = signedIn[id];
    if (!client) {
      console.error(`cleanup: tenant ${id} never signed in — remove its rows manually (dashboard, as postgres)`);
      continue;
    }
    const { error } = await client.from("instructor").delete().eq("id", id);
    if (error) {
      console.error(`cleanup instructor ${id}: ${error.message} — remove its rows manually (dashboard, as postgres)`);
    }
  }
  console.log(
    `access_log rows from this run are kept: tenant_id in (${tenantIds.join(", ")}), ` +
      `harness-written rows carry request_id ${runRequestId}`,
  );
  for (const id of tenantIds) {
    const { error } = await admin.auth.admin.deleteUser(id);
    if (error) console.error(`cleanup auth user ${id}: ${error.message} — delete manually in the dashboard`);
  }
}

async function main() {
  if (MODE === "prod-anon-only") {
    await anonReadsNothing();
  } else if (MODE === "staging") {
    await anonReadsNothing();
    await fullSuite();
  } else {
    console.error("Refusing to run: set PINKAS_LIVE_TEST=staging (full suite, seeds data — staging only)");
    console.error("or PINKAS_LIVE_TEST=prod-anon-only (read-only anon check, safe on production).");
    process.exit(1);
  }

  console.log(`\n${passes} passed, ${failures.length} failed`);
  console.log("Not expressible through PostgREST (covered by the CI bootstrap run):");
  console.log("  - information_schema: private fields exist in exactly one relation");
  console.log("  - SQLSTATE insufficient_privilege vs RLS WITH CHECK violation (both 42501 here)");
  if (failures.length > 0) process.exit(1);
}

main().catch((err) => {
  console.error(`ABORT ${err.message}`);
  process.exit(1);
});
