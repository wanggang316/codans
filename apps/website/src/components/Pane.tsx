import { useEffect, useState } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { useTypewriter } from "@/lib/useTypewriter";

export interface PaneScript {
  prompt: string;
  agent: string;
  branch: string;
  lines: string[];
  /** color of the agent badge dot */
  hue?: "leaf" | "amber" | "cyan" | "violet";
}

interface Props {
  script: PaneScript;
  startDelay?: number;
  broadcastTick: number;
  isFocused: boolean;
  isDimmed: boolean;
  onHover: () => void;
  onLeave: () => void;
}

const HUE_CLASS: Record<NonNullable<PaneScript["hue"]>, string> = {
  leaf: "bg-leaf-300 shadow-[0_0_10px_2px_rgba(167,198,92,0.55)]",
  amber: "bg-amber-300 shadow-[0_0_10px_2px_rgba(252,211,77,0.45)]",
  cyan: "bg-cyan-300 shadow-[0_0_10px_2px_rgba(103,232,249,0.45)]",
  violet: "bg-violet-300 shadow-[0_0_10px_2px_rgba(196,181,253,0.45)]",
};

export default function Pane({
  script,
  startDelay = 0,
  broadcastTick,
  isFocused,
  isDimmed,
  onHover,
  onLeave,
}: Props) {
  const rendered = useTypewriter(script.lines, { startDelay, speed: 22, pauseEnd: 5200 });
  const [progress, setProgress] = useState(0);
  const [pulse, setPulse] = useState(false);

  // Broadcast → progress fill + green flash overlay
  useEffect(() => {
    if (broadcastTick === 0) return;
    setPulse(true);
    setProgress(0);
    const start = performance.now();
    const total = 1400;
    let raf = 0;
    const tick = (now: number) => {
      const p = Math.min(1, (now - start) / total);
      setProgress(p);
      if (p < 1) raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    const off = window.setTimeout(() => setPulse(false), 900);
    return () => {
      cancelAnimationFrame(raf);
      window.clearTimeout(off);
    };
  }, [broadcastTick]);

  return (
    <motion.div
      onMouseEnter={onHover}
      onMouseLeave={onLeave}
      animate={{
        scale: isFocused ? 1.025 : isDimmed ? 0.985 : 1,
        opacity: isDimmed ? 0.55 : 1,
        filter: isDimmed ? "blur(0.6px)" : "blur(0px)",
      }}
      transition={{ type: "spring", stiffness: 220, damping: 26 }}
      className={`group relative overflow-hidden rounded-lg border bg-[#0c0c0e] ${
        isFocused ? "border-leaf-500/70 z-10" : "border-line"
      }`}
    >
      {/* Tab header */}
      <div className="flex h-7 items-center gap-2 border-b border-line/70 bg-[#0a0a0c] px-2.5 text-[10.5px] font-mono">
        <span className={`h-1.5 w-1.5 rounded-full ${HUE_CLASS[script.hue ?? "leaf"]}`} />
        <span className="text-ink">{script.agent}</span>
        <span className="text-ink-dim">·</span>
        <span className="truncate text-ink-muted">{script.branch}</span>
        {/* OSC 9;4 style progress sliver */}
        <div className="ml-auto h-[3px] w-12 overflow-hidden rounded-full bg-line">
          <div
            className="h-full bg-leaf-300 transition-[width] duration-75"
            style={{ width: `${progress * 100}%` }}
          />
        </div>
      </div>

      {/* Body */}
      <div className="relative h-[170px] overflow-hidden px-3 py-2 font-mono text-[11.5px] leading-[1.55]">
        <div className="text-ink/90">
          {rendered.map((line, i) => {
            const isLast = i === rendered.length - 1;
            const isPrompt = line.startsWith("$");
            return (
              <div key={i} className={isPrompt ? "text-ink" : "text-ink/80"}>
                {isPrompt ? (
                  <>
                    <span className="text-leaf-300">{script.prompt} </span>
                    <span>{line.slice(2)}</span>
                  </>
                ) : (
                  <span>{line}</span>
                )}
                {isLast && <span className="ml-0.5 inline-block h-[12px] w-[6px] -mb-[1px] bg-leaf-300 align-middle animate-blink" />}
              </div>
            );
          })}
        </div>

        {/* Broadcast green flash */}
        <AnimatePresence>
          {pulse && (
            <motion.div
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              transition={{ duration: 0.25 }}
              className="pointer-events-none absolute inset-0 bg-leaf-300/10"
            >
              <motion.div
                initial={{ x: "-100%" }}
                animate={{ x: "100%" }}
                transition={{ duration: 0.9, ease: "easeOut" }}
                className="absolute inset-y-0 w-2/3 bg-gradient-to-r from-transparent via-leaf-300/30 to-transparent"
              />
            </motion.div>
          )}
        </AnimatePresence>
      </div>
    </motion.div>
  );
}
