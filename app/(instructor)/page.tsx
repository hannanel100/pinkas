import { redirect } from "next/navigation";

/**
 * The instructor app has no separate home. PRD §8: Today *is* the product —
 * "if she does not open it every morning, the product has failed."
 */
export default function Index() {
  redirect("/today");
}
