/**
 * The curriculum snapshot (ADR-0004, invariant 6). Pure — no I/O.
 *
 * A course carries a frozen copy of its curriculum, so editing a template
 * never rewrites the history of courses taught from it. ADR-0004 asks for a
 * versioned schema validated on write and on read; there is no Zod here, so it
 * is written out and keyed by `snapshot_version`.
 */

import { DataAccessError } from "./errors";
import type { Uuid } from "./ids";
import { asRow, asRows, intField, optionalStringField, stringField, uuidField } from "./values";

export const SNAPSHOT_VERSION = 1;

export type SnapshotTopic = {
  /** The template topic's id, frozen here; `covered_topic_ids` points at it. */
  readonly id: Uuid;
  readonly orderIndex: number;
  readonly title: string;
  readonly description: string | null;
  readonly estimatedMinutes: number | null;
};

export type CurriculumSnapshotV1 = {
  readonly curriculum: {
    readonly id: Uuid;
    readonly name: string;
    readonly description: string | null;
    readonly defaultSessionCount: number;
  };
  readonly topics: readonly SnapshotTopic[];
};

/**
 * Validates a stored snapshot on read, keyed by `snapshot_version` (ADR-0004
 * asks for a versioned schema; there is no Zod here, so it is written out).
 */
export function parseCurriculumSnapshot(version: number, value: unknown): CurriculumSnapshotV1 {
  const OP = "course.snapshot";
  if (version !== SNAPSHOT_VERSION) throw new DataAccessError(OP, "version");
  const root = asRow(OP, value);
  const cur = asRow(OP, root.curriculum);
  const count = cur.defaultSessionCount;
  if (typeof count !== "number" || !Number.isInteger(count) || count < 1) {
    throw new DataAccessError(OP, "shape");
  }
  return {
    curriculum: {
      id: uuidField(OP, cur, "id"),
      name: stringField(OP, cur, "name"),
      description: optionalStringField(OP, cur, "description"),
      defaultSessionCount: count,
    },
    topics: asRows(OP, root.topics).map((t) => {
      const minutes = t.estimatedMinutes;
      return {
        id: uuidField(OP, t, "id"),
        orderIndex: intField(OP, t, "orderIndex"),
        title: stringField(OP, t, "title"),
        description: optionalStringField(OP, t, "description"),
        estimatedMinutes: typeof minutes === "number" ? minutes : null,
      };
    }),
  };
}
