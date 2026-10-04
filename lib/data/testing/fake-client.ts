/**
 * Test double for the user-JWT client, substituted at the factory seam
 * (`vi.mock("@/lib/supabase/user")`). Records every query and RPC so tests can
 * assert what was asked of the database — tenant filters, payloads, and above
 * all every `access_log` insert. Test-only; imported by `*.test.ts` alone.
 */

export type Op = readonly [method: string, args: readonly unknown[]];

export type QueryCall = { readonly table: string; readonly ops: Op[] };
export type RpcCall = { readonly name: string; readonly args: Record<string, unknown> };
export type Response = { data?: unknown; error?: { code?: string; message?: string } | null };

type Responder = Response | ((call: QueryCall) => Response);

export const TENANT = "11111111-1111-4111-8111-111111111111";
export const ENGINEER = "99999999-9999-4999-8999-999999999999";
export const GRANT = "88888888-8888-4888-8888-888888888888";

export class FakeClient {
  readonly queries: QueryCall[] = [];
  readonly rpcs: RpcCall[] = [];
  claims: Record<string, unknown> | null = {
    sub: TENANT,
    role: "authenticated",
  };
  private readonly tableQueue = new Map<string, Responder[]>();
  private readonly rpcQueue = new Map<string, Response[]>();

  /** Queue a response for the next query on `table`. */
  respond(table: string, response: Responder): this {
    const q = this.tableQueue.get(table) ?? [];
    q.push(response);
    this.tableQueue.set(table, q);
    return this;
  }

  respondRpc(name: string, response: Response): this {
    const q = this.rpcQueue.get(name) ?? [];
    q.push(response);
    this.rpcQueue.set(name, q);
    return this;
  }

  /** Rows inserted into access_log, flattened. */
  get accessLogRows(): Record<string, unknown>[] {
    return this.queries
      .filter((q) => q.table === "access_log")
      .flatMap((q) => q.ops.filter(([m]) => m === "insert").flatMap(([, a]) => a[0] as Record<string, unknown>[]));
  }

  /** Queries on tables other than access_log. */
  get dataQueries(): QueryCall[] {
    return this.queries.filter((q) => q.table !== "access_log");
  }

  readonly authCalls: [string, unknown][] = [];
  authError: { message: string } | null = null;

  readonly auth = {
    getClaims: async () =>
      this.claims
        ? { data: { claims: this.claims }, error: null }
        : { data: null, error: { message: "no session" } },
    signInWithOtp: async (args: unknown) => {
      this.authCalls.push(["signInWithOtp", args]);
      return { data: {}, error: this.authError };
    },
    verifyOtp: async (args: unknown) => {
      this.authCalls.push(["verifyOtp", args]);
      return { data: { session: this.authError ? null : {} }, error: this.authError };
    },
    signOut: async (args: unknown) => {
      this.authCalls.push(["signOut", args]);
      return { error: null };
    },
  };

  from(table: string): unknown {
    const call: QueryCall = { table, ops: [] };
    this.queries.push(call);
    const resolveResponse = (): Response => {
      const q = this.tableQueue.get(table);
      const next = q?.shift();
      if (next === undefined) {
        return table === "access_log" ? { data: null, error: null } : { data: [], error: null };
      }
      return typeof next === "function" ? next(call) : next;
    };
    const proxy: unknown = new Proxy(
      {},
      {
        get(_target, prop) {
          if (prop === "then") {
            return (ok: (v: unknown) => unknown, err: (e: unknown) => unknown) => {
              const r = resolveResponse();
              return Promise.resolve({ data: r.data ?? null, error: r.error ?? null }).then(ok, err);
            };
          }
          return (...args: unknown[]) => {
            call.ops.push([String(prop), args]);
            return proxy;
          };
        },
      },
    );
    return proxy;
  }

  rpc(name: string, args: Record<string, unknown>): unknown {
    this.rpcs.push({ name, args });
    const next = this.rpcQueue.get(name)?.shift() ?? { data: null, error: null };
    const result = { data: next.data ?? null, error: next.error ?? null };
    const promise = Promise.resolve(result);
    return Object.assign(promise, {
      single: () => Promise.resolve({ ...result, data: Array.isArray(result.data) ? result.data[0] ?? null : result.data }),
    });
  }
}

/** All ops of a given method across a call. */
export function opsOf(call: QueryCall, method: string): readonly unknown[][] {
  return call.ops.filter(([m]) => m === method).map(([, a]) => [...a]);
}

export function hasOp(call: QueryCall, method: string, ...args: unknown[]): boolean {
  return opsOf(call, method).some(
    (a) => JSON.stringify(a.slice(0, args.length)) === JSON.stringify(args),
  );
}

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
