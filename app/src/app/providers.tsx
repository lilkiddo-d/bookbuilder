"use client";

import "@rainbow-me/rainbowkit/styles.css";
import { useState, type ReactNode } from "react";
import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { RainbowKitProvider, darkTheme, lightTheme } from "@rainbow-me/rainbowkit";
import { wagmiConfig } from "@/lib/wagmi";
import { defaultChainId } from "@/lib/chains";
import { ProtocolProvider } from "@/hooks/useProtocol";
import { ToastProvider } from "@/components/Toaster";

export function Providers({ children }: { children: ReactNode }) {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: { queries: { staleTime: 5_000, refetchOnWindowFocus: false, retry: 1 } },
      }),
  );
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider
          appInfo={{ appName: "Bookbuilder", learnMoreUrl: "/risk" }}
          initialChain={defaultChainId}
          theme={{
            lightMode: lightTheme({ accentColor: "#1d4ed8", borderRadius: "medium" }),
            darkMode: darkTheme({ accentColor: "#6d9bff", accentColorForeground: "#0b0f17", borderRadius: "medium" }),
          }}
        >
          <ToastProvider>
            <ProtocolProvider>{children}</ProtocolProvider>
          </ToastProvider>
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
