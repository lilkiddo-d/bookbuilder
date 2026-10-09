"use client";

import { useEffect, useState } from "react";

/** Current unix time in seconds, ticking every `intervalMs`. Returns 0 before mount (avoids hydration mismatch). */
export function useNow(intervalMs = 1000): number {
  const [now, setNow] = useState(0);
  useEffect(() => {
    setNow(Math.floor(Date.now() / 1000));
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);
  return now;
}
