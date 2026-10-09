"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useAccount } from "wagmi";
import { tokenFeaturesConfigured } from "@/lib/env";
import { supportedChains } from "@/lib/chains";
import { useProtocol } from "@/hooks/useProtocol";

const links = [
  { href: "/", label: "Offerings" },
  { href: "/portfolio", label: "Portfolio" },
  { href: "/issuer", label: "Issuers" },
  ...(tokenFeaturesConfigured ? [{ href: "/stake", label: "Stake" }] : []),
  { href: "/risk", label: "Risk" },
];

function Logo() {
  return (
    <Link href="/" className="flex items-center gap-2 font-semibold tracking-tight">
      <svg width="26" height="26" viewBox="0 0 32 32" aria-hidden>
        <rect x="2" y="2" width="28" height="28" rx="7" fill="var(--accent)" />
        <rect x="8" y="9" width="16" height="3" rx="1.5" fill="var(--accent-fg)" />
        <rect x="8" y="14.5" width="11" height="3" rx="1.5" fill="var(--accent-fg)" />
        <rect x="8" y="20" width="6" height="3" rx="1.5" fill="var(--accent-fg)" />
      </svg>
      <span>Bookbuilder</span>
    </Link>
  );
}

function ReadNetworkSelect() {
  const { isConnected } = useAccount();
  const { chainId, setReadChainId } = useProtocol();
  if (isConnected || supportedChains.length < 2) return null;
  return (
    <select
      className="input w-auto py-1.5 text-xs"
      value={chainId}
      onChange={(e) => setReadChainId(Number(e.target.value))}
      aria-label="Network"
    >
      {supportedChains.map((c) => (
        <option key={c.id} value={c.id}>
          {c.name}
        </option>
      ))}
    </select>
  );
}

export function Header() {
  const pathname = usePathname();
  return (
    <header className="sticky top-0 z-40 border-b border-line bg-surface/90 backdrop-blur">
      <div className="mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-3 px-4 py-3">
        <div className="flex items-center gap-6">
          <Logo />
          <nav className="flex flex-wrap gap-1 text-sm">
            {links.map((l) => {
              const active = l.href === "/" ? pathname === "/" || pathname.startsWith("/offering") : pathname.startsWith(l.href);
              return (
                <Link
                  key={l.href}
                  href={l.href}
                  className={`rounded-md px-2.5 py-1.5 ${active ? "bg-surface-2 font-medium" : "text-muted hover:text-fg"}`}
                >
                  {l.label}
                </Link>
              );
            })}
          </nav>
        </div>
        <div className="flex items-center gap-2">
          <ReadNetworkSelect />
          <ConnectButton chainStatus="name" showBalance={false} accountStatus="address" />
        </div>
      </div>
    </header>
  );
}
