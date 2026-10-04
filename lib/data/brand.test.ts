import { readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { describe, expect, it, vi } from "vitest";

import { auditDescriptorOf } from "./context";

/**
 * The brand test (#7 design challenge). Fails CI on an unaudited export by
 * its mere existence — before anyone calls it.
 *
 * Every module directly under `lib/data/` is imported, and every function it
 * exports must carry the brand `defineRead` / `defineMutation` attach. The
 * three infrastructure modules are the only exceptions, and their exported
 * functions are pinned BY NAME below, so adding an unaudited function to one of
 * them fails here too.
 *
 * What this does not catch, stated so it is not read as coverage: a
 * `per-bride` function that subjects three of the five brides it returns. The
 * wrapper catches "subjected nobody"; the per-module tests catch the rest.
 *
 * `lib/data/internal/` and `lib/data/testing/` are not scanned: they hold pure
 * helpers and test doubles, and nothing in them can obtain a client — only a
 * `defineRead`/`defineMutation` body is handed one.
 */

vi.mock("@/lib/supabase/user", () => ({
  createUserClient: async () => {
    throw new Error("brand test: no module may touch the client at import time");
  },
}));

const DIR = fileURLToPath(new URL(".", import.meta.url));

/** Infrastructure, and the exact functions each may export unbranded. */
const INFRASTRUCTURE: Readonly<Record<string, readonly string[]>> = {
  "context.ts": [
    "defineRead",
    "defineMutation",
    "auditDescriptorOf",
    "ok",
    "requestPhoneOtp",
    "verifyPhoneOtp",
    "signOut",
    // error classes, re-exported for callers to catch
    "AuditViolationError",
    "DataAccessError",
    "ImpersonationRefusedError",
    "NotAuthenticatedError",
  ],
  "audit.ts": ["logAccess"],
  "secret.ts": ["Secret", "secret"],
};

/**
 * Every audited function, with what it declares. A change here is a change to
 * what the access log records — review it as one.
 */
const EXPECTED: Readonly<Record<string, string>> = {
  "brides.listBrides": "read bride per-bride",
  "brides.getBrideCard": "read bride_card per-bride",
  "brides.createBride": "mutation bride per-bride",
  "courses.createCourse": "mutation course per-bride",
  "courses.recomputeSchedule": "read schedule per-bride",
  "courses.confirmSchedule": "mutation schedule per-bride",
  "sessions.markDone": "mutation session per-bride",
  "sessions.cancel": "mutation session per-bride",
  "sessions.reschedule": "mutation session per-bride",
  "records.readSessionRecords": "read session_record database",
  "records.upsertSessionRecord": "mutation session_record per-bride",
  "today.getTodayScreen": "read today_screen database",
  "instructor.bootstrapInstructor": "mutation instructor none",
};

const modules = readdirSync(DIR)
  .filter((f) => f.endsWith(".ts") && !f.endsWith(".test.ts"))
  .sort();

describe("every exported function in lib/data/ is audited", () => {
  it("finds the modules", () => {
    expect(modules).toEqual(
      expect.arrayContaining(["brides.ts", "courses.ts", "records.ts", "sessions.ts", "today.ts"]),
    );
    expect(modules).not.toContain("portal.ts"); // arrives with #53/#54, with its own rules
  });

  it.each(modules)("%s", async (file) => {
    const mod = (await import(/* @vite-ignore */ `./${file}`)) as Record<string, unknown>;
    const fns = Object.entries(mod).filter(([, v]) => typeof v === "function");
    const allowed = INFRASTRUCTURE[file];

    if (allowed) {
      expect(fns.map(([name]) => name).sort()).toEqual([...allowed].sort());
      return;
    }

    const stem = file.replace(/\.ts$/, "");
    for (const [name, fn] of fns) {
      const d = auditDescriptorOf(fn);
      expect(d, `${file}: export "${name}" is not a defineRead/defineMutation`).not.toBeNull();
      expect(`${d!.kind} ${d!.resource} ${d!.subjects}`, `${stem}.${name}`).toBe(
        EXPECTED[`${stem}.${name}`],
      );
      expect(d!.audience).toBe("instructor");
    }
  });

  it("every expected function exists", async () => {
    for (const key of Object.keys(EXPECTED)) {
      const [stem, name] = key.split(".") as [string, string];
      const mod = (await import(/* @vite-ignore */ `./${stem}.ts`)) as Record<string, unknown>;
      expect(auditDescriptorOf(mod[name]), key).not.toBeNull();
    }
  });
});
