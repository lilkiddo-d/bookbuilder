import type { Metadata } from "next";
import { RiskAck } from "@/components/RiskAck";

export const metadata: Metadata = { title: "Risk disclosure" };

const sections: { id: string; title: string; body: string[] }[] = [
  {
    id: "nature",
    title: "1. What you are buying",
    body: [
      "Offerings on Bookbuilder sell tokens that represent, or are intended to represent, interests in real-world assets (RWAs) such as real estate, credit, funds or other securities. These tokens may be securities under the laws of your jurisdiction and may carry the same risks as the underlying asset, plus the additional risks of being held on a blockchain.",
      "The value of the underlying asset can fall, become illiquid, or be lost entirely. Past performance and projections in offering documents are not guarantees. Tokens may have no secondary market and may be subject to transfer restrictions imposed by the issuer's token contract.",
    ],
  },
  {
    id: "issuer",
    title: "2. Issuer risk, non-delivery and escrow refunds",
    body: [
      "Issuers are approved by protocol governance, but approval is not an endorsement, audit, or guarantee of the issuer, the asset, or the accuracy of any document. You rely on the issuer to hold the underlying asset and to honour the rights the token represents.",
      "Your payment is held in a per-offering escrow smart contract. It is released to the issuer only when the issuer delivers the full amount of sale tokens into escrow. If the offering misses its soft cap, is cancelled, or the issuer fails to deliver before the delivery deadline, the escrow switches to a Failed state and every investor can claim a full refund of their deposit (minus any non-reveal penalty in batch auctions).",
      "Refunds are not automatic: you (or anyone on your behalf) must call settle. After the delivery deadline passes without delivery, anyone may mark the delivery as failed to unlock refunds.",
      "Once tokens are delivered and payment is released, the escrow can no longer protect you. Any later failure of the issuer or the asset is outside the protocol's control.",
    ],
  },
  {
    id: "deadline",
    title: "3. Delivery deadline",
    body: [
      "Each offering specifies a delivery window (between 1 and 180 days) that starts when the offering is finalized. During this window your funds are locked in escrow: you cannot withdraw them while the issuer still has time to deliver. Plan for your funds being unavailable for up to the full delivery window.",
    ],
  },
  {
    id: "vesting",
    title: "4. Vesting and lockups",
    body: [
      "Some offerings deliver tokens through a vesting schedule with a cliff and a linear release. Locked tokens cannot be transferred or sold until they vest, and their value may change materially during the lockup.",
    ],
  },
  {
    id: "commit-reveal",
    title: "5. Sealed-bid auctions: salt loss and non-reveal penalty",
    body: [
      "Batch auctions use commit-reveal. When you bid, your browser generates a random secret (salt) and stores it locally; you should also download the bid backup file. To have your bid counted you must reveal it during the reveal window using that exact secret.",
      "If you lose the secret (cleared browser storage, different device, lost backup) or miss the reveal window, your bid cannot be revealed. Unrevealed bids receive no allocation and lose a penalty (up to 20%, set per offering) of the deposit, which is sent to the protocol fee collector. The remaining deposit is refundable.",
      "Commit deadlines may be extended by anti-sniping rules up to a hard maximum shown on the offering page. All successful bidders pay the same clearing price; bids at the clearing price may be filled only partially.",
    ],
  },
  {
    id: "smart-contract",
    title: "6. Smart contract and blockchain risk",
    body: [
      "The protocol is software. Despite testing and review, smart contracts may contain bugs or be exploited, which could result in total loss of funds. Governance changes are subject to a public timelock, and a guardian may pause new activity during incidents, which could delay your transactions.",
      "Blockchain networks can be congested, halted, reorganized or subject to outages. Transactions may fail or be delayed, and you pay network fees whether or not a transaction succeeds. You are solely responsible for the security of your wallet and keys; transactions cannot be reversed.",
    ],
  },
  {
    id: "oracle",
    title: "7. Prices and oracle data are display-only",
    body: [
      "Any USD values shown are estimates from on-chain oracles or governance-set reference prices and are provided for convenience only. They may be stale or wrong and never affect settlement. The price you pay is always the on-chain offering price in the payment token.",
    ],
  },
  {
    id: "compliance",
    title: "8. Compliance and eligibility",
    body: [
      "Offerings are restricted to eligible investors. By default every offering requires an on-chain eligibility attestation (KYC tier, and where required accredited or professional investor status) issued by an approved compliance provider to your wallet. Attestations expire and can be frozen or revoked, for example after a sanctions screening hit.",
      "To become eligible, complete verification with an approved compliance provider for your jurisdiction; once the attestation is recorded on-chain for your wallet, eligible offerings will unlock automatically. Using another person's wallet or attestation is prohibited.",
      "Eligibility checks are performed by smart contracts and do not replace your own obligation to comply with the laws that apply to you.",
    ],
  },
  {
    id: "jurisdiction",
    title: "9. Jurisdiction restrictions",
    body: [
      "Offerings are not available in every jurisdiction. Access to this interface may be blocked from certain countries, and specific offerings may exclude residents of certain countries. It is your responsibility to ensure participation is lawful where you live. Do not use VPNs or other means to circumvent restrictions.",
    ],
  },
  {
    id: "advice",
    title: "10. No investment advice; no affiliation",
    body: [
      "Nothing on this interface is investment, legal, tax or accounting advice, or a recommendation to buy any asset. Consult your own advisers. Read each offering's documents in full before participating.",
      "Bookbuilder is an independent protocol interface. It is not affiliated with, endorsed by, or operated by any brokerage, exchange, bank, or the operator of any blockchain network it runs on. Offerings are made by their issuers, not by the protocol.",
    ],
  },
];

export default function RiskPage() {
  return (
    <article className="mx-auto max-w-3xl space-y-6">
      <header>
        <h1 className="text-2xl font-semibold tracking-tight">Risk disclosure</h1>
        <p className="mt-2 text-sm text-muted">
          Please read this page carefully. Participating in offerings involves significant risk, including the possible loss of your entire investment.
        </p>
      </header>
      <nav className="card text-sm">
        <ul className="grid gap-1 sm:grid-cols-2">
          {sections.map((s) => (
            <li key={s.id}>
              <a href={`#${s.id}`} className="text-accent hover:underline">
                {s.title}
              </a>
            </li>
          ))}
        </ul>
      </nav>
      {sections.map((s) => (
        <section key={s.id} id={s.id} className="scroll-mt-24 space-y-2">
          <h2 className="text-lg font-semibold">{s.title}</h2>
          {s.body.map((p, i) => (
            <p key={i} className="text-sm leading-relaxed">
              {p}
            </p>
          ))}
        </section>
      ))}
      <div className="card space-y-2">
        <p className="text-sm font-medium">Acknowledgment</p>
        <p className="text-sm text-muted">Participation buttons stay disabled until you acknowledge this disclosure. Your choice is stored in this browser only.</p>
        <RiskAck />
      </div>
    </article>
  );
}
