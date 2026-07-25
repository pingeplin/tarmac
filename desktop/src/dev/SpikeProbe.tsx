// Dev-only QA runner for the Milestone 0 sandbox spike (spec 2607.0004, S18).
// Mounts a fixed-position sandboxed iframe pointed at whatever HTML path
// VITE_SPIKE_PROBE names (typically desktop/qa/sandbox-probe.html), relays
// every shim console/escape message to the Rust side's `qa_log` command so
// it lands in `make run`'s stdout where the spike gate can be judged from a
// captured log. This component is not part of the shipped card UI — App.tsx
// mounts it only when VITE_SPIKE_PROBE is set.

import { useEffect, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { cardSrcUrl } from "../kit/docKind";
import { parseCardMessage } from "../kit/cardConsole";

export function SpikeProbe({ path }: { path: string }) {
  const iframeRef = useRef<HTMLIFrameElement>(null);

  useEffect(() => {
    const iframe = iframeRef.current;
    if (!iframe) return;

    const onMessage = (e: MessageEvent) => {
      if (e.source !== iframe.contentWindow) return;
      const msg = parseCardMessage(e.data);
      if (!msg) return;
      const line =
        msg.kind === "escape"
          ? "[spike] escape-relay received"
          : msg.kind === "console"
            ? `[spike] console.${msg.level} ${msg.args.map((a: unknown) => String(a)).join(" ")}`
            : `[spike] ready meta=${msg.meta ?? "null"}`;
      void invoke("qa_log", { line });
    };

    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, []);

  return (
    <iframe
      ref={iframeRef}
      sandbox="allow-scripts"
      allow=""
      src={cardSrcUrl(path, 0)}
      style={{
        position: "fixed",
        bottom: 0,
        right: 0,
        width: 420,
        height: 300,
        zIndex: 9999,
        background: "#111",
        border: "2px solid #f0f",
      }}
    />
  );
}
