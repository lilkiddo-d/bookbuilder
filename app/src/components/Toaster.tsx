"use client";

import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from "react";

export type ToastKind = "pending" | "success" | "error" | "info";

export interface Toast {
  id: number;
  kind: ToastKind;
  title: string;
  body?: string;
  href?: string;
}

interface ToastApi {
  push: (t: Omit<Toast, "id">) => number;
  update: (id: number, t: Partial<Omit<Toast, "id">>) => void;
  dismiss: (id: number) => void;
}

const Ctx = createContext<ToastApi | null>(null);
let nextId = 1;

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);

  const dismiss = useCallback((id: number) => setToasts((ts) => ts.filter((t) => t.id !== id)), []);

  const scheduleDismiss = useCallback(
    (id: number, kind: ToastKind) => {
      if (kind === "pending") return;
      setTimeout(() => dismiss(id), kind === "error" ? 12_000 : 7_000);
    },
    [dismiss],
  );

  const push = useCallback(
    (t: Omit<Toast, "id">) => {
      const id = nextId++;
      setToasts((ts) => [...ts.slice(-4), { ...t, id }]);
      scheduleDismiss(id, t.kind);
      return id;
    },
    [scheduleDismiss],
  );

  const update = useCallback(
    (id: number, patch: Partial<Omit<Toast, "id">>) => {
      setToasts((ts) => ts.map((t) => (t.id === id ? { ...t, ...patch } : t)));
      if (patch.kind) scheduleDismiss(id, patch.kind);
    },
    [scheduleDismiss],
  );

  const api = useMemo(() => ({ push, update, dismiss }), [push, update, dismiss]);

  return (
    <Ctx.Provider value={api}>
      {children}
      <div className="fixed bottom-4 right-4 z-50 flex w-[22rem] max-w-[calc(100vw-2rem)] flex-col gap-2" aria-live="polite">
        {toasts.map((t) => (
          <div
            key={t.id}
            className={`rounded-lg border bg-surface p-3 text-sm shadow-lg ${
              t.kind === "error"
                ? "border-red-500/50"
                : t.kind === "success"
                  ? "border-emerald-500/50"
                  : "border-line"
            }`}
          >
            <div className="flex items-start justify-between gap-2">
              <div className="flex items-center gap-2 font-medium">
                {t.kind === "pending" && <span className="spinner" aria-hidden />}
                {t.kind === "success" && <span className="text-emerald-500">✓</span>}
                {t.kind === "error" && <span className="text-red-500">!</span>}
                {t.title}
              </div>
              <button className="text-muted hover:text-fg" onClick={() => dismiss(t.id)} aria-label="Dismiss">
                ×
              </button>
            </div>
            {t.body && <p className="mt-1 break-words text-muted">{t.body}</p>}
            {t.href && (
              <a className="mt-1 inline-block text-accent underline" href={t.href} target="_blank" rel="noreferrer">
                View on explorer
              </a>
            )}
          </div>
        ))}
      </div>
    </Ctx.Provider>
  );
}

export function useToast(): ToastApi {
  const v = useContext(Ctx);
  if (!v) throw new Error("useToast must be used inside ToastProvider");
  return v;
}
