import { env } from "./env";

/** Turn a CID / ipfs:// URI / URL into a gateway link. Returns undefined for empty input. */
export function ipfsUrl(cid: string | undefined): string | undefined {
  const v = (cid ?? "").trim();
  if (!v) return undefined;
  if (/^https?:\/\//i.test(v)) return v;
  const stripped = v.replace(/^ipfs:\/\//i, "").replace(/^\/?ipfs\//i, "");
  return `${env.ipfsGateway}${stripped}`;
}
