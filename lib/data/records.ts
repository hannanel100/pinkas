import "server-only";

import { defineMutation, defineRead, notOk, ok, type Result } from "./context";
import { fail } from "./internal/errors";
import { parseUuid, type Uuid } from "./internal/ids";
import { readRecords, type SessionRecord } from "./internal/records";
import { asRow, embeddedOne, stringField, uuidField } from "./internal/values";

/**
 * `session_record` — covered topics, `private_note`, `needs_review_note`.
 * The private half of a session (SDD §5, ADR-0003), readable only through the
 * audited reader of migration 0006 (ADR-0009).
 *
 * SECURITY REVIEW TRIGGER: this module touches `session_record`.
 */

export type { SessionRecord } from "./internal/records";

/** Longest note accepted. A guard against abuse, not a product limit. */
const MAX_NOTE = 20_000;
const MAX_TOPICS = 200;

/**
 * Records for the given sessions — the caller's own, RLS-scoped in the
 * database; ids she cannot see are silently absent.
 *
 * Logged in-database: `read_session_records` writes one `access_log` row per
 * bride disclosed in the same statement as the read, so this function writes
 * none of its own (`subjects: "database"` — its context has no client to
 * issue any other query with).
 */
export const readSessionRecords = defineRead(
  { resource: "session_record", subjects: "database" },
  async (ctx, sessionIds: readonly string[]): Promise<SessionRecord[]> => {
    const ids = sessionIds.map(parseUuid).filter((id): id is Uuid => id !== null);
    return readRecords(ctx, [...new Set(ids)]);
  },
);

export type SessionRecordInput = {
  readonly sessionId: string;
  readonly coveredTopicIds: readonly string[];
  readonly privateNote: string | null;
  readonly needsReviewNote: string | null;
};

/**
 * Full replace of the session's three private fields, via
 * `upsert_session_record` (never `.upsert()`, which fails since 0006). The
 * session is addressed by id and must be the caller's own; the record's key
 * is that session id, so no new id is ever taken from input.
 *
 * Logged as an `update` of `session_record` for the session's bride — an
 * additional row the RPC does not write itself. The log carries ids only; the
 * note never reaches it.
 */
export const upsertSessionRecord = defineMutation(
  { resource: "session_record", action: "update", subjects: "per-bride" },
  async (
    ctx,
    input: SessionRecordInput,
  ): Promise<Result<{ sessionId: Uuid; updatedAt: string }>> => {
    const sessionId = parseUuid(input.sessionId);
    if (!sessionId) return notOk;
    const topics = input.coveredTopicIds.map(parseUuid);
    if (topics.some((t) => t === null) || topics.length > MAX_TOPICS) return notOk;
    for (const note of [input.privateNote, input.needsReviewNote]) {
      if (note !== null && (typeof note !== "string" || note.length > MAX_NOTE)) {
        return notOk;
      }
    }

    // Whose bride is this? Tenant-scoped here as well as by RLS.
    const OP = "session.select_for_record";
    const { data: owner, error: ownerError } = await ctx.db
      .from("session")
      .select("id, course!inner(bride_id)")
      .eq("id", sessionId)
      .eq("tenant_id", ctx.tenantId)
      .is("deleted_at", null)
      .maybeSingle();
    if (ownerError) fail(OP, ownerError);
    if (!owner) return notOk;
    const brideId = uuidField(OP, embeddedOne(OP, asRow(OP, owner), "course"), "bride_id");

    const { data, error } = await ctx.db
      .rpc("upsert_session_record", {
        p_session_id: sessionId,
        p_covered_topic_ids: [...new Set(topics as Uuid[])],
        p_private_note: input.privateNote,
        p_needs_review_note: input.needsReviewNote,
      })
      .single();
    if (error) {
      if (error.code === "P0002") return notOk;
      fail("rpc.upsert_session_record", error);
    }
    const row = asRow("rpc.upsert_session_record", data);
    ctx.subject(brideId);
    return ok({
      sessionId: uuidField("rpc.upsert_session_record", row, "session_id"),
      updatedAt: stringField("rpc.upsert_session_record", row, "updated_at"),
    });
  },
);
