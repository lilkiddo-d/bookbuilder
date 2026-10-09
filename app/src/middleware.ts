import { NextResponse, type NextRequest } from "next/server";

const BLOCKED = (process.env.NEXT_PUBLIC_GEOBLOCK_COUNTRIES ?? "")
  .split(",")
  .map((c) => c.trim().toUpperCase())
  .filter((c) => c.length === 2);

/** Paths that stay reachable from blocked regions. */
const ALLOW_PREFIXES = ["/blocked", "/risk", "/deployments/", "/_next/", "/favicon", "/robots.txt", "/icon"];

export function middleware(request: NextRequest) {
  if (BLOCKED.length === 0) return NextResponse.next();
  const { pathname } = request.nextUrl;
  if (ALLOW_PREFIXES.some((p) => pathname.startsWith(p))) return NextResponse.next();
  // static assets (anything with a file extension)
  if (/\.[a-zA-Z0-9]+$/.test(pathname)) return NextResponse.next();

  const country = (request.headers.get("x-vercel-ip-country") ?? request.headers.get("cf-ipcountry") ?? "").toUpperCase();
  if (country && BLOCKED.includes(country)) {
    const url = request.nextUrl.clone();
    url.pathname = "/blocked";
    url.search = "";
    return NextResponse.redirect(url);
  }
  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|deployments/).*)"],
};
