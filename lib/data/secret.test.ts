import { inspect } from "node:util";

import { describe, expect, it } from "vitest";

import { Secret, secret } from "./secret";

const TOKEN = "c2VjcmV0LXRva2VuLXZhbHVlLTMyLWJ5dGVz";

describe("Secret<T>", () => {
  const s = secret(TOKEN);

  it("reveals the value only through reveal()", () => {
    expect(s.reveal()).toBe(TOKEN);
  });

  it.each([
    ["String()", () => String(s)],
    ["template literal", () => `${s}`],
    ["concatenation", () => "x" + s],
    ["JSON.stringify", () => JSON.stringify({ s })],
    ["util.inspect", () => inspect({ s }, { depth: 5, showHidden: true })],
    ["Error message", () => new Error(`bad token ${s}`).message],
    ["Object.keys / entries", () => JSON.stringify(Object.entries(s))],
  ])("does not leak through %s", (_label, render) => {
    expect(render()).not.toContain(TOKEN);
  });

  it("is frozen and a class instance", () => {
    expect(Object.isFrozen(s)).toBe(true);
    expect(s).toBeInstanceOf(Secret);
  });
});
