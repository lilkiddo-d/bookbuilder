import type { Address } from "viem";

export const OfferingKind = { FixedPrice: 0, BatchAuction: 1, DutchAuction: 2 } as const;
export type OfferingKind = (typeof OfferingKind)[keyof typeof OfferingKind];

export const Stage = { Active: 0, Succeeded: 1, Delivered: 2, Failed: 3 } as const;
export type Stage = (typeof Stage)[keyof typeof Stage];

export const kindLabel: Record<number, string> = {
  0: "Fixed price",
  1: "Batch auction",
  2: "Dutch auction",
};

export const stageLabel: Record<number, string> = {
  0: "Active",
  1: "Succeeded",
  2: "Delivered",
  3: "Failed",
};

export const batchPhaseLabel: Record<number, string> = {
  0: "Not started",
  1: "Commit",
  2: "Reveal",
  3: "Awaiting finalize",
  4: "Finalized",
};

export const issuerStatusLabel: Record<number, string> = {
  0: "Not registered",
  1: "Approved",
  2: "Suspended",
  3: "Revoked",
};

export interface ComplianceRules {
  enabled: boolean;
  minTier: number;
  requireAccredited: boolean;
}

export interface CommonParams {
  saleToken: Address;
  paymentToken: Address;
  supply: bigint;
  softCap: bigint;
  perWalletMax: bigint;
  startTime: bigint;
  endTime: bigint;
  deliveryWindow: number;
  vestingCliff: bigint;
  vestingDuration: bigint;
  priorityTier: number;
  priorityWindow: number;
  compliance: ComplianceRules;
  docsCID: string;
}

export interface Deployment {
  chainId: number;
  network: string;
  blockNumber?: number;
  contracts: {
    Timelock?: Address;
    IssuerRegistry: Address;
    ComplianceRegistry: Address;
    OfferingFactory: Address;
    DeliveryVesting: Address;
    FeeCollector?: Address;
    ProjectTokenHooks?: Address;
    OracleAdapter?: Address;
    OfferingEscrowImpl?: Address;
    FixedPriceOfferingImpl?: Address;
    BatchAuctionImpl?: Address;
    DutchAuctionImpl?: Address;
  };
  paymentTokens: Record<string, Address>;
  guardian?: Address;
  treasury?: Address;
  timelockDelay?: number;
}
