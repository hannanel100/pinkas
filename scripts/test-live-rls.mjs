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
 *                   docs/schema.test.sql fixtures via the service key, runs
 *                   the assertions with real JWTs, then deletes everything it
 *                   created. Writes data: staging only, never production.
 *   prod-anon-only  Read-only. Asserts the anon key without a JWT reads zero
 *                   rows from every table and view. Needs no service key and
 *                   is safe against production.
 *
 * Environment (exported in the operator's shell for one run, never a file —
 * see docs/runbooks/provisioning.md):
 *   LIVE_SUPABASE_URL
 *   LIVE_SUPABASE_ANON_KEY
 *   LIVE_SUPABASE_SERVICE_ROLE_KEY   staging mode only
 *
 * Two schema.test.sql assertions cannot be expressed through PostgREST and
 * remain covered only by the CI bootstrap run — called out here rather than
 * quietly dropped:
 *   1. The information_schema check that the private fields (private_note,
 *      needs_review_note, covered_topic_ids) exist in exactly one relation.
 *      Approximated below by asserting the portal_session_view response shape
 *      is exactly the seven public columns — a weaker, surface-level check.
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
  if (error) throw new Error(`createUser ${email}: ${error.message}`);
  return data.user;
}

async function seed(admin, table, rows) {
  const { error } = await admin.from(table).insert(rows);
  if (error) throw new Error(`seed ${table}: ${error.message}`);
}

async function fullSuite() {
  const serviceKey = required("LIVE_SUPABASE_SERVICE_ROLE_KEY");
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

  const runTag = Date.now();
  const emailA = `pinkas-rls-a-${runTag}@example.com`;
  const emailB = `pinkas-rls-b-${runTag}@example.com`;
  const password = `${randomUUID()}.${randomUUID()}`;

  console.log("\n== creating throwaway auth users (real auth.uid values) ==");
  const A = (await createUser(admin, emailA, password)).id;
  const B = (await createUser(admin, emailB, password)).id;

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
    console.log("== seeding the schema.test.sql fixtures via the service key ==");
    await seed(admin, "instructor", [
      { id: A, full_name: "Michal (tenant A)", phone: "050-0000001" },
      { id: B, full_name: "Sara  (tenant B)", phone: "050-0000002" },
    ]);
    await seed(admin, "bride", [
      { id: ids.brideA, tenant_id: A, first_name: "Noa", wedding_date: dateFromToday(34), status: "active" },
      { id: ids.brideB, tenant_id: B, first_name: "Rivka", wedding_date: dateFromToday(60), status: "active" },
      { id: ids.brideCrit, tenant_id: A, first_name: "Crit", wedding_date: dateFromToday(28), status: "active" },
      { id: ids.brideHigh, tenant_id: A, first_name: "High", wedding_date: dateFromToday(214), status: "active" },
      { id: ids.brideMed, tenant_id: A, first_name: "Med", wedding_date: dateFromToday(214), status: "active" },
      { id: ids.brideInfo, tenant_id: A, first_name: "Info", wedding_date: dateFromToday(20), status: "active" },
      { id: ids.brideNone, tenant_id: A, first_name: "None", wedding_date: dateFromToday(214), status: "active" },
    ]);
    await seed(admin, "course", [
      { id: ids.courseA, tenant_id: A, bride_id: ids.brideA, curriculum_snapshot: { topics: [] }, target_end_date: dateFromToday(20), status: "active" },
      { id: ids.courseB, tenant_id: B, bride_id: ids.brideB, curriculum_snapshot: { topics: [] }, target_end_date: dateFromToday(46), status: "active" },
      { id: ids.courseCrit, tenant_id: A, bride_id: ids.brideCrit, curriculum_snapshot: {}, target_end_date: dateFromToday(14), status: "active" },
      { id: ids.courseHigh, tenant_id: A, bride_id: ids.brideHigh, curriculum_snapshot: {}, target_end_date: dateFromToday(200), status: "active" },
      { id: ids.courseMed, tenant_id: A, bride_id: ids.brideMed, curriculum_snapshot: {}, target_end_date: dateFromToday(200), status: "active" },
      { id: ids.courseInfo, tenant_id: A, bride_id: ids.brideInfo, curriculum_snapshot: {}, target_end_date: dateFromToday(6), status: "active" },
      { id: ids.courseNone, tenant_id: A, bride_id: ids.brideNone, curriculum_snapshot: {}, target_end_date: dateFromToday(200), status: "active" },
    ]);
    const sessions = [
      { id: ids.sessionA, tenant_id: A, course_id: ids.courseA, order_index: 1, scheduled_at: tsFromNow(1), location: "Herzl 14", status: "planned" },
      { id: ids.sessionB, tenant_id: B, course_id: ids.courseB, order_index: 1, scheduled_at: tsFromNow(2), location: "Weizmann 3", status: "planned" },
    ];
    for (let g = 1; g <= 5; g += 1) {
      sessions.push({ tenant_id: A, course_id: ids.courseCrit, order_index: g, scheduled_at: tsFromNow(g), status: "planned" });
    }
    sessions.push(
      { tenant_id: A, course_id: ids.courseHigh, order_index: 1, scheduled_at: tsFromNow(-10), status: "cancelled" },
      { tenant_id: A, course_id: ids.courseHigh, order_index: 2, scheduled_at: tsFromNow(3), status: "planned" },
      { tenant_id: A, course_id: ids.courseMed, order_index: 1, scheduled_at: tsFromNow(-30), status: "done" },
      { tenant_id: A, course_id: ids.courseMed, order_index: 2, scheduled_at: tsFromNow(3), status: "planned" },
      { tenant_id: A, course_id: ids.courseInfo, order_index: 1, scheduled_at: tsFromNow(-2), status: "done" },
      { tenant_id: A, course_id: ids.courseNone, order_index: 1, scheduled_at: tsFromNow(-2), status: "done" },
      { tenant_id: A, course_id: ids.courseNone, order_index: 2, scheduled_at: tsFromNow(3), status: "planned" },
    );
    await seed(admin, "session", sessions);
    await seed(admin, "session_record", [
      { session_id: ids.sessionA, tenant_id: A, private_note: "A private note", needs_review_note: "A review note" },
      { session_id: ids.sessionB, tenant_id: B, private_note: "B private note", needs_review_note: "B review note" },
    ]);

    console.log("== signing in as tenant A (real verified JWT) ==");
    const a = anonClient();
    const { error: signInErr } = await a.auth.signInWithPassword({ email: emailA, password });
    if (signInErr) throw new Error(`sign-in failed: ${signInErr.message}`);
    const { data: userData, error: userErr } = await a.auth.getUser();
    check(!userErr && userData?.user?.id === A, "JWT sub resolves to the created auth user (auth.uid source)");

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
      const { data, error } = await a.from("session_record").select("session_id, private_note");
      const leaked = (data ?? []).some((r) => (r.private_note ?? "").startsWith("B "));
      check(!error && data?.length === 1 && !leaked, "session_record isolated: one row, no tenant B note", error?.message ?? `got ${data?.length}`);
    }
    {
      const { data, error } = await a.from("v_course_risk").select("course_id");
      check(!error && data?.length === 6, "v_course_risk respects caller RLS (security_invoker)", error?.message ?? `got ${data?.length}`);
    }
    {
      const { data, error } = await a.from("portal_session_view").select("id").eq("bride_id", ids.brideB);
      check(!error && data?.length === 0, "portal_session_view leaks no tenant B rows");
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

    console.log("\n== portal surface (response-shape approximation) ==");
    {
      const { data, error } = await a.from("portal_session_view").select("*").eq("bride_id", ids.brideA);
      const expected = ["bride_id", "duration_minutes", "id", "location", "order_index", "scheduled_at", "status"];
      const got = data?.length ? Object.keys(data[0]).sort() : [];
      check(
        !error && data?.length === 1 && JSON.stringify(got) === JSON.stringify(expected),
        "portal_session_view exposes exactly the seven public columns",
        error?.message ?? `got [${got.join(", ")}]`,
      );
    }
  } finally {
    console.log("\n== cleanup ==");
    await cleanup(admin, [A, B]);
  }
}

async function cleanup(admin, tenantIds) {
  const del = async (table, column) => {
    const { error } = await admin.from(table).delete().in(column, tenantIds);
    if (error) {
      console.error(`cleanup ${table}: ${error.message} — remove rows for tenants ${tenantIds.join(", ")} manually`);
    }
  };
  await del("access_log", "tenant_id");
  // Deleting instructors cascades through every tenant-scoped FK; access_log
  // has no FK to instructor, hence the separate delete above.
  await del("instructor", "id");
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
