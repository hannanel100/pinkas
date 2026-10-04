import "server-only";

import { defineMutation, ok, type FormResult } from "./context";
import { fail } from "./internal/errors";
import type { Uuid } from "./internal/ids";
import { normalisePhoneE164 } from "./internal/phone";
import { asRows, boolField, uuidField } from "./internal/values";

/**
 * The tenant — signup provisioning. SDD §6.1, §14.2; migration 0002.
 *
 * `bootstrapInstructor` is the first-sign-in transaction: the `instructor` row
 * (`id = auth.uid()`, which is what makes invariant 1 mean anything) and the
 * system message templates, in one call to `bootstrap_instructor`, so a
 * failure leaves no half-provisioned tenant. Idempotent: a retry after an
 * interrupted sign-in seeds only what is missing.
 *
 * The template bodies are product copy and come from the caller (the
 * translation layer), not from this module — the migration header explains
 * why. The signup screen and Server Action that call this are #10.
 *
 * `subjects: "none"` — no bride exists at signup and none is read, so no
 * `access_log` row is written. Migration 0002 records the same decision.
 */

export type BootstrapInput = {
  readonly fullName: string;
  readonly phone: string;
  readonly email?: string | null;
  /** System templates to seed — required and non-empty (D1 works from day one). */
  readonly templates: readonly { readonly name: string; readonly body: string }[];
  /** Optional starter curriculum template. */
  readonly curriculum?: {
    readonly name: string;
    readonly description?: string | null;
    readonly defaultSessionCount?: number;
    readonly topics: readonly {
      readonly title: string;
      readonly description?: string | null;
      readonly estimatedMinutes?: number | null;
    }[];
  } | null;
};

export type BootstrapField = "fullName" | "phone" | "email" | "templates" | "curriculum";

const OP = "rpc.bootstrap_instructor";

export const bootstrapInstructor = defineMutation(
  { resource: "instructor", action: "create", subjects: "none" },
  async (
    ctx,
    input: BootstrapInput,
  ): Promise<FormResult<{ instructorId: Uuid; wasCreated: boolean }, BootstrapField>> => {
    const invalid: BootstrapField[] = [];
    const fullName = input.fullName?.trim() ?? "";
    if (fullName === "" || fullName.length > 200) invalid.push("fullName");
    const phone = normalisePhoneE164(input.phone ?? "");
    if (!phone) invalid.push("phone");
    const email = input.email?.trim() || null;
    if (email !== null && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) invalid.push("email");
    const templates = Array.isArray(input.templates) ? input.templates : [];
    if (
      templates.length === 0 ||
      templates.some((t) => !t?.name?.trim() || !t?.body?.trim())
    ) {
      invalid.push("templates");
    }
    const cur = input.curriculum ?? null;
    if (cur !== null && (!cur.name?.trim() || !Array.isArray(cur.topics) ||
        cur.topics.some((t) => !t?.title?.trim()))) {
      invalid.push("curriculum");
    }
    if (invalid.length > 0) return { ok: false, invalid };

    // Built field by field; the tenant is auth.uid() inside the function and
    // is not a parameter.
    const { data, error } = await ctx.db.rpc("bootstrap_instructor", {
      p_full_name: fullName,
      p_phone: phone,
      p_templates: templates.map((t) => ({ name: t.name.trim(), body: t.body })),
      p_email: email,
      p_curriculum:
        cur === null
          ? null
          : {
              name: cur.name.trim(),
              description: cur.description ?? null,
              ...(cur.defaultSessionCount === undefined
                ? {}
                : { default_session_count: cur.defaultSessionCount }),
              topics: cur.topics.map((t) => ({
                title: t.title.trim(),
                description: t.description ?? null,
                estimated_minutes: t.estimatedMinutes ?? null,
              })),
            },
    });
    if (error) fail(OP, error);
    const row = asRows(OP, data)[0];
    if (!row) fail(OP, { code: "shape" });
    const instructorId = uuidField(OP, row, "instructor_id");
    if (instructorId !== ctx.tenantId) fail(OP, { code: "tenant" });
    return ok({ instructorId, wasCreated: boolField(OP, row, "was_created") });
  },
);
