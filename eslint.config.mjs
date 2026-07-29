import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

/**
 * CLAUDE.md: "Each one is enforced by a test or a lint rule, not by review
 * discipline — so breaking one should show up as a failure. Do not work around
 * the failure; the constraint is the point."
 *
 * This file is that enforcement. Each rule names the invariant it implements.
 * If one fires, the fix is almost never an eslint-disable.
 *
 * ── A structural warning, because it has already bitten once ──────────────
 *
 * ESLint flat config *replaces* a rule when a later block redefines it; the
 * entries are not merged. Two blocks that both match `components/**` and both
 * set `no-restricted-syntax` means the second silently wins and the first
 * stops enforcing anything.
 *
 * So the rules are composed from the shared arrays below and each scope
 * defines each rule exactly once. Before adding a block, check that no other
 * block matching the same files sets the same rule — and verify by writing a
 * violation and watching it fail. A rule that passes on clean code proves
 * nothing.
 *
 * These are lexical checks, not type-aware ones, and deliberately blunt: a rule
 * that occasionally needs a justified disable is worth more than one nobody can
 * read. typescript-eslint's type-aware rules are unavailable while the
 * toolchain runs TypeScript 7 (see README); none of the boundaries below need
 * them.
 */

/* ── Shared matchers ─────────────────────────────────────────────────────── */

const HEX_COLOUR = /#[0-9a-fA-F]{3}/;

// Tailwind physical-direction utilities. RTL is the only direction Phase 1
// ships, so these are always a bug — a logical equivalent exists for each.
const PHYSICAL_UTILITY =
  /(?:^|[\s"'`])(?:-?m[lr]|-?p[lr]|left|right|text-left|text-right|border-[lr]|rounded-[lr]|float-left|float-right|inset-[lr])-/;

const PHYSICAL_PROPERTY =
  /^(?:marginLeft|marginRight|paddingLeft|paddingRight|left|right|borderLeft|borderRight|borderLeftWidth|borderRightWidth|borderLeftColor|borderRightColor)$/;

const RISK_TOKEN = /(?:^|[\s"'`-])risk-[123]\b/;

/* ── no-restricted-syntax fragments ──────────────────────────────────────── */

/** Invariant 8 — RTL is the only direction. SDD §10.3, §11. */
const rtlSyntax = [
  {
    selector: `Literal[value=${PHYSICAL_UTILITY.toString()}]`,
    message:
      "Physical direction utility. RTL is the only direction (invariant 8, SDD §11) — use the logical equivalent: ms-/me-, ps-/pe-, start-/end-, text-start/text-end, border-s/border-e.",
  },
  {
    selector: `TemplateElement[value.raw=${PHYSICAL_UTILITY.toString()}]`,
    message:
      "Physical direction utility. RTL is the only direction (invariant 8, SDD §11).",
  },
  {
    selector: `Property[key.name=${PHYSICAL_PROPERTY.toString()}]`,
    message:
      "Physical CSS property. Use the logical property — marginInlineStart, paddingInlineEnd, insetInlineStart. Invariant 8, SDD §11.",
  },
];

/** Invariant 7 — colour carries exactly one meaning: risk. SDD §10.2. */
const colourSyntax = [
  {
    selector: `Literal[value=${HEX_COLOUR.toString()}]`,
    message:
      "Raw hex colour. The token set is closed (invariant 7, SDD §10.2) — app/globals.css is the only place colour is defined.",
  },
  {
    selector: `TemplateElement[value.raw=${HEX_COLOUR.toString()}]`,
    message: "Raw hex colour. The token set is closed (invariant 7, SDD §10.2).",
  },
  {
    selector: "CallExpression[callee.name=/^(?:rgb|rgba|hsl|hsla|oklch)$/]",
    message:
      "Computed colour. The token set is closed (invariant 7), and only components/risk/ emits colour at all.",
  },
];

/** The other half of invariant 7: only components/risk/ names the risk tokens. */
const riskTokenSyntax = [
  {
    selector: `Literal[value=${RISK_TOKEN.toString()}]`,
    message:
      "risk-* tokens may only be referenced inside components/risk/ (invariant 7, SDD §10.2). Render risk through a component from there.",
  },
  {
    selector: `TemplateElement[value.raw=${RISK_TOKEN.toString()}]`,
    message:
      "risk-* tokens may only be referenced inside components/risk/ (invariant 7, SDD §10.2).",
  },
];

/** Invariant 4 — `today` is injected, never read from the clock. SDD §2.4. */
const noClockSyntax = [
  {
    selector: "NewExpression[callee.name='Date'][arguments.length=0]",
    message:
      "The engines never read the clock — `today` is injected (invariant 4, SDD §2.4). An engine that reads the clock cannot be tested against a fixture table.",
  },
  {
    selector:
      "CallExpression[callee.object.name='Date'][callee.property.name='now']",
    message:
      "The engines never read the clock — `today` is injected (invariant 4, SDD §2.4).",
  },
];

/* ── no-restricted-imports fragments ─────────────────────────────────────── */

/** Invariant 3 — lib/data/ is the only door to the database. SDD §13. */
const supabaseClientPaths = [
  {
    name: "@supabase/supabase-js",
    message:
      "Construct clients only in lib/supabase/ (invariant 3, SDD §13). Postgres has no AFTER SELECT, so the access log PRD §10.1 requires is complete only if reads happen in one place.",
  },
  {
    name: "@supabase/ssr",
    message: "Construct clients only in lib/supabase/ (invariant 3, SDD §13).",
  },
];

/** Invariant 5 — the service-role key lives behind lib/data/portal.ts only. */
const serviceRolePattern = {
  group: ["@/lib/supabase/service", "**/supabase/service"],
  message:
    "The service-role client is reachable from lib/data/portal.ts only (invariant 5, SDD §2.3). It must never sit in a path that accepts arbitrary user input.",
};

/** Invariant 4 — lib/domain/ imports nothing that does I/O. SDD §2.4. */
const domainPurityPattern = {
  group: [
    "@/lib/data",
    "@/lib/data/**",
    "@/lib/supabase",
    "@/lib/supabase/**",
    "**/lib/data/**",
    "**/lib/supabase/**",
    "@supabase/**",
    "server-only",
    "next",
    "next/**",
    "react",
    "react-dom",
    "node:*",
  ],
  message:
    "lib/domain/ does no I/O and imports nothing from the data or framework layers (invariant 4, SDD §2.4). This is what makes the fixture tests in §17.2 possible.",
};

const portalCannotReachInstructorData = {
  group: [
    "@/lib/data/brides",
    "@/lib/data/courses",
    "@/lib/data/sessions",
    "@/lib/data/records",
    "@/lib/data/today",
    "@/lib/supabase/user",
  ],
  message:
    "The bride portal is Path 2 (untrusted). It reaches portal_session_view via lib/data/portal.ts and nothing else (invariant 5, SDD §2.3).",
};

const instructorCannotReachPortalData = {
  group: ["@/lib/data/portal", "**/data/portal"],
  message:
    "Instructor screens must not import the portal's service-role module (invariant 5, SDD §13).",
};

/* ── Config ──────────────────────────────────────────────────────────────── */

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,

  globalIgnores([
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
    "supabase/migrations/**",
  ]),

  {
    // Baseline for every file. More specific scopes below REDEFINE
    // no-restricted-imports and must therefore repeat these fragments.
    name: "pinkas/baseline-imports",
    files: ["**/*.{ts,tsx,mts}"],
    ignores: ["lib/supabase/**", "lib/data/portal.ts"],
    rules: {
      "no-restricted-imports": [
        "error",
        { paths: supabaseClientPaths, patterns: [serviceRolePattern] },
      ],
    },
  },

  {
    name: "pinkas/ui-surfaces",
    files: ["app/**/*.{ts,tsx}", "components/**/*.{ts,tsx}"],
    ignores: ["components/risk/**"],
    rules: {
      "no-restricted-syntax": [
        "error",
        ...rtlSyntax,
        ...colourSyntax,
        ...riskTokenSyntax,
      ],
    },
  },
  {
    // components/risk/ is the one place the risk tokens are legal. Everything
    // else about it — RTL, no raw hex — still applies.
    name: "pinkas/risk-components",
    files: ["components/risk/**/*.{ts,tsx}"],
    rules: {
      "no-restricted-syntax": ["error", ...rtlSyntax, ...colourSyntax],
    },
  },

  {
    name: "pinkas/domain-is-pure",
    files: ["lib/domain/**/*.ts"],
    rules: {
      "no-restricted-syntax": ["error", ...noClockSyntax],
      "no-restricted-imports": [
        "error",
        {
          paths: supabaseClientPaths,
          patterns: [serviceRolePattern, domainPurityPattern],
        },
      ],
    },
  },

  {
    name: "pinkas/portal-boundary",
    files: ["app/(portal)/**/*.{ts,tsx}"],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          paths: supabaseClientPaths,
          patterns: [serviceRolePattern, portalCannotReachInstructorData],
        },
      ],
    },
  },
  {
    name: "pinkas/instructor-boundary",
    files: ["app/(instructor)/**/*.{ts,tsx}"],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          paths: supabaseClientPaths,
          patterns: [serviceRolePattern, instructorCannotReachPortalData],
        },
      ],
    },
  },
]);

export default eslintConfig;
