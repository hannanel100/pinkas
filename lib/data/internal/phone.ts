/**
 * Phone numbers normalise to E.164 on write (SDD §14.1). Pure — no I/O.
 *
 * The `wa.me` deep link needs digits in international form, and a tenant's
 * brides arrive typed every way an Israeli phone number can be typed:
 * `050-123-4567`, `0501234567`, `+972 50 123 4567`, `972501234567`,
 * `00972501234567`, `+972-050-1234567`. All of those are `+972501234567`.
 *
 * Numbers in another country's international form are accepted as long as
 * they are plausibly E.164 (8–15 digits after `+`). Anything else is `null`
 * — the caller reports it rather than storing something WhatsApp cannot dial.
 */

const ISRAEL = "972";

export function normalisePhoneE164(raw: string): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  if (trimmed === "") return null;

  // Visual separators only. Letters or anything else make it not a number.
  const compact = trimmed.replace(/[\s\-().‎‏]/g, "");
  if (!/^\+?\d+$/.test(compact)) return null;

  let international: string;
  if (compact.startsWith("+")) {
    international = compact.slice(1);
  } else if (compact.startsWith("00")) {
    international = compact.slice(2);
  } else if (compact.startsWith(ISRAEL) && compact.length >= 11) {
    international = compact;
  } else if (compact.startsWith("0")) {
    // Israeli national format: trunk 0, then 8 (landline) or 9 (mobile) digits.
    const national = compact.slice(1);
    if (national.length < 8 || national.length > 9) return null;
    international = ISRAEL + national;
  } else {
    return null;
  }

  // +972 0XX… — the trunk zero typed after the country code.
  if (international.startsWith(`${ISRAEL}0`)) {
    international = ISRAEL + international.slice(ISRAEL.length + 1);
  }

  if (international.startsWith(ISRAEL)) {
    const national = international.slice(ISRAEL.length);
    if (national.length < 8 || national.length > 9) return null;
  }

  if (international.length < 8 || international.length > 15) return null;
  if (international.startsWith("0")) return null;
  return `+${international}`;
}
