/**
 * The slice of a request context internal helpers need. Structural, so the
 * helpers depend on no module that holds a client.
 */
export type BaseContextLike = {
  loggedRpc(
    name: "read_session_records",
    args: { readonly p_session_ids: readonly string[] },
  ): Promise<unknown>;
};
