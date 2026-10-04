/**
 * The one way this layer reads `session_record`'s private columns: the audited
 * reader of migration 0006 (ADR-0009). Shared by `records.ts` and
 * `brides.ts#getBrideCard`, so both reach note bodies the same way.
 *
 * `read_session_records` writes its own `access_log` rows — one per bride
 * disclosed, `resource = 'session_record'` — in the same statement as the
 * read. Callers therefore must NOT also `subject()` brides for this read on
 * its account (they may for their own, separately-logged resource).
 *
 * Never `.from("session_record").select("private_note")` and never
 * `.upsert()`: both fail with 42501 since 0006, by design.
 */

import type { BaseContextLike } from "./types";
import { DataAccessError } from "./errors";
import { parseUuid, type Uuid } from "./ids";
import {
  asRows,
  intField,
  optionalStringField,
  stringField,
  uuidField,
} from "./values";

export type SessionRecord = {
  readonly sessionId: Uuid;
  readonly courseId: Uuid;
  readonly brideId: Uuid;
  readonly orderIndex: number;
  /** Topic ids inside the course's `curriculum_snapshot` (ADR-0004). */
  readonly coveredTopicIds: readonly Uuid[];
  readonly privateNote: string | null;
  readonly needsReviewNote: string | null;
  readonly updatedAt: string;
};

const OP = "rpc.read_session_records";

export async function readRecords(
  ctx: BaseContextLike,
  sessionIds: readonly Uuid[],
): Promise<SessionRecord[]> {
  if (sessionIds.length === 0) return [];
  const data = await ctx.loggedRpc("read_session_records", {
    p_session_ids: sessionIds,
  });
  return asRows(OP, data).map((row) => {
    const topics = row.covered_topic_ids;
    if (!Array.isArray(topics)) throw new DataAccessError(OP, "shape");
    return {
      sessionId: uuidField(OP, row, "session_id"),
      courseId: uuidField(OP, row, "course_id"),
      brideId: uuidField(OP, row, "bride_id"),
      orderIndex: intField(OP, row, "order_index"),
      coveredTopicIds: topics.map((t) => {
        const id = parseUuid(t);
        if (!id) throw new DataAccessError(OP, "shape");
        return id;
      }),
      privateNote: optionalStringField(OP, row, "private_note"),
      needsReviewNote: optionalStringField(OP, row, "needs_review_note"),
      updatedAt: stringField(OP, row, "updated_at"),
    };
  });
}
