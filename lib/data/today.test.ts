import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { assessRisk } from "@/lib/domain/risk";

import { getTodayScreen } from "./today";
import { FakeClient, UUID_RE } from "./testing/fake-client";

const state = vi.hoisted(() => ({ client: undefined as unknown }));
vi.mock("@/lib/supabase/user", () => ({ createUserClient: async () => state.client }));

const B1 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1";
const B2 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2";
const B3 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3";
const C1 = "cccccccc-cccc-4ccc-8ccc-ccccccccccc1";
const C2 = "cccccccc-cccc-4ccc-8ccc-ccccccccccc2";
const C3 = "cccccccc-cccc-4ccc-8ccc-ccccccccccc3";
const S1 = "dddddddd-dddd-4ddd-8ddd-ddddddddddd1";

function course(over: Record<string, unknown>) {
  return {
    course_id: C1,
    bride_id: B1,
    bride_first_name: "נועה",
    bride_last_name: "כהן",
    sessions_remaining: 0,
    sessions_done: 0,
    last_done_at: null,
    last_done_on: null,
    stale_cancellations: 0,
    target_end_date: "2027-06-01",
    wedding_date: "2027-06-15",
    ...over,
  };
}

const DOC = {
  today: "2026-10-05",
  timezone: "Asia/Jerusalem",
  courses: [
    // medium: last session 30 days ago
    course({ course_id: C1, bride_id: B1, sessions_remaining: 2, sessions_done: 3,
      last_done_at: "2026-09-04T15:00:00Z", last_done_on: "2026-09-04" }),
    // critical: 5 sessions, 14 days to deadline
    course({ course_id: C2, bride_id: B2, bride_first_name: "רחל", sessions_remaining: 5,
      target_end_date: "2026-10-19", wedding_date: "2026-11-02" }),
    // none
    course({ course_id: C3, bride_id: B3, bride_first_name: "שרה" }),
  ],
  sessions_today: [
    { session_id: S1, course_id: C1, bride_id: B1, bride_first_name: "נועה", bride_last_name: null,
      bride_phone: "+972501234567", order_index: 4, scheduled_at: "2026-10-05T14:00:00+00:00",
      duration_minutes: 60, location: null, status: "planned" },
  ],
  payments: {
    currency: "ILS",
    outstanding_total: "3400.00",
    open_course_count: 2,
    open_bride_count: 2,
    other_currency_payment_count: 0,
  },
};

let fake: FakeClient;
beforeEach(() => {
  fake = new FakeClient();
  state.client = fake;
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-10-04T22:30:00Z")); // 01:30 on the 5th in Israel
});
afterEach(() => vi.useRealTimers());

describe("getTodayScreen", () => {
  it("is ONE round trip: one RPC, no table query, no application log row (invariant 10)", async () => {
    fake.respondRpc("today_screen", { data: DOC });
    await getTodayScreen();
    expect(fake.rpcs).toHaveLength(1);
    expect(fake.queries).toHaveLength(0);
    const { name, args } = fake.rpcs[0]!;
    expect(name).toBe("today_screen");
    expect(Object.keys(args).sort()).toEqual(["p_request_id", "p_today"]);
    expect(args.p_today).toBe("2026-10-05"); // the Israeli civil date, injected
    expect(args.p_request_id).toMatch(UUID_RE); // 0004 refuses anything else
  });

  it("computes the verdict with assessRisk() from the aggregate — never a selected risk_level", async () => {
    fake.respondRpc("today_screen", { data: DOC });
    const screen = await getTodayScreen();

    expect(screen.risk.map((r) => [r.courseId, r.assessment.level])).toEqual([
      [C2, "critical"],
      [C1, "medium"],
    ]);
    expect(screen.onTrackCount).toBe(1);

    const medium = screen.risk[1]!;
    expect(Object.keys(medium).sort()).toEqual(
      ["assessment", "brideFirstName", "brideId", "courseId", "input"].sort(),
    );
    // last_done_on mapped straight through — no timezone arithmetic here
    expect(medium.input.lastDoneOn).toBe("2026-09-04");
    expect(medium.input.today).toBe("2026-10-05");
    expect(medium.assessment).toEqual(assessRisk(medium.input));
    expect(medium.assessment).toMatchObject({
      reasonCode: "no_recent_session",
      operands: { daysSinceLastSession: 31 },
    });
  });

  it("orders by severity, then nearest deadline", async () => {
    fake.respondRpc("today_screen", {
      data: {
        ...DOC,
        courses: [
          course({ course_id: C1, bride_id: B1, sessions_remaining: 9, target_end_date: "2026-12-01" }),
          course({ course_id: C2, bride_id: B2, sessions_remaining: 9, target_end_date: "2026-11-01" }),
          course({ course_id: C3, bride_id: B3, stale_cancellations: 1 }),
        ],
      },
    });
    const screen = await getTodayScreen();
    expect(screen.risk.map((r) => r.courseId)).toEqual([C2, C1, C3]);
  });

  it("carries money as a decimal string with its currency", async () => {
    fake.respondRpc("today_screen", { data: DOC });
    const screen = await getTodayScreen();
    expect(screen.payments.outstanding).toEqual({ amount: "3400.00", currency: "ILS" });
    expect(screen.sessionsToday[0]).toMatchObject({ sessionId: S1, bridePhone: "+972501234567" });
  });

  it("fails loudly on a document for another day, or a malformed one", async () => {
    fake.respondRpc("today_screen", { data: { ...DOC, today: "2026-10-04" } });
    await expect(getTodayScreen()).rejects.toMatchObject({ name: "DataAccessError" });
    fake.respondRpc("today_screen", { data: { ...DOC, payments: { ...DOC.payments, outstanding_total: 3400 } } });
    await expect(getTodayScreen()).rejects.toMatchObject({ name: "DataAccessError" });
  });
});
