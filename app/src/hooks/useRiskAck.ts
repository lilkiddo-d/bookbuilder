"use client";

import { useCallback, useSyncExternalStore } from "react";

const KEY = "bookbuilder:riskAck:v1";
const EVENT = "bookbuilder:riskAck";

function subscribe(cb: () => void) {
  window.addEventListener("storage", cb);
  window.addEventListener(EVENT, cb);
  return () => {
    window.removeEventListener("storage", cb);
    window.removeEventListener(EVENT, cb);
  };
}

function read(): boolean {
  try {
    return localStorage.getItem(KEY) === "true";
  } catch {
    return false;
  }
}

/** Persistent "I have read the risk disclosure" acknowledgment. Required before any participation tx. */
export function useRiskAck(): [boolean, (v: boolean) => void] {
  const acked = useSyncExternalStore(subscribe, read, () => false);
  const set = useCallback((v: boolean) => {
    try {
      if (v) localStorage.setItem(KEY, "true");
      else localStorage.removeItem(KEY);
    } catch {
      /* ignore */
    }
    window.dispatchEvent(new Event(EVENT));
  }, []);
  return [acked, set];
}
