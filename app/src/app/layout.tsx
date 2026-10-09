import type { Metadata } from "next";
import "./globals.css";
import { Providers } from "./providers";
import { Header } from "@/components/Header";
import { Footer } from "@/components/Footer";
import { WrongNetworkBanner } from "@/components/NetworkGate";

export const metadata: Metadata = {
  title: { default: "Bookbuilder", template: "%s · Bookbuilder" },
  description: "On-chain bookbuilding and offerings for real-world-asset issuers, with escrowed settlement.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className="min-h-screen antialiased">
        <Providers>
          <Header />
          <WrongNetworkBanner />
          <main className="mx-auto max-w-6xl px-4 py-8">{children}</main>
          <Footer />
        </Providers>
      </body>
    </html>
  );
}
