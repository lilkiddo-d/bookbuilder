import Link from "next/link";

export function Footer() {
  return (
    <footer className="mt-16 border-t border-line">
      <div className="mx-auto flex max-w-6xl flex-col gap-2 px-4 py-6 text-xs text-muted sm:flex-row sm:items-center sm:justify-between">
        <p>
          Not investment advice. Offerings are restricted to eligible investors.{" "}
          <Link href="/risk" className="text-accent underline">
            Risk disclosure
          </Link>
        </p>
        <p>Bookbuilder · Runs on Robinhood Chain · Independent protocol, not affiliated with any brokerage.</p>
      </div>
    </footer>
  );
}
