import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = { title: "Not available in your region" };

export default function BlockedPage() {
  return (
    <div className="mx-auto max-w-xl card space-y-3 text-center">
      <h1 className="text-xl font-semibold">Not available in your region</h1>
      <p className="text-sm text-muted">
        Access to this interface is not available from your location due to regulatory restrictions. Offerings are restricted to eligible
        investors in permitted jurisdictions.
      </p>
      <p className="text-sm">
        <Link href="/risk#jurisdiction" className="text-accent underline">
          Read the risk disclosure
        </Link>
      </p>
    </div>
  );
}
