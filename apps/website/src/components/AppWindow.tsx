import { useEffect, useRef, useState } from "react";
import { motion } from "framer-motion";
import TerminalWindow from "./TerminalWindow";
import Pane, { PaneScript } from "./Pane";

const SCRIPTS: PaneScript[] = [
  {
    prompt: "❯",
    agent: "claude",
    branch: "feat/agent-loop",
    hue: "leaf",
    lines: [
      "$ claude",
      "✦ Analyzing 12 files…",
      "✦ Read src/runtime/Loop.swift",
      "✦ Found 3 references to Tab.send",
      "↳ Drafting fix",
    ],
  },
  {
    prompt: "❯",
    agent: "codex",
    branch: "fix/race-cond",
    hue: "cyan",
    lines: [
      "$ codex --task 'patch sync'",
      "› reading repo (47 files)",
      "› proposing 2 edits",
      "› running tests",
      "✓ 124 passed",
    ],
  },
  {
    prompt: "❯",
    agent: "pytest",
    branch: "test/parallel",
    hue: "amber",
    lines: [
      "$ pytest -q --maxfail=1",
      "....................",
      "...............",
      "47 passed in 1.82s",
    ],
  },
  {
    prompt: "❯",
    agent: "vite",
    branch: "ui/landing",
    hue: "violet",
    lines: [
      "$ pnpm dev",
      "  ➜  Local:   http://127.0.0.1:5173/",
      "  ➜  Network: use --host to expose",
      "HMR update /src/Hero.tsx",
      "HMR update /src/lib/util.ts",
    ],
  },
];

const SIDEBAR_TREE = [
  { kind: "project", label: "touch-code", open: true },
  { kind: "worktree", label: "main", branch: "main", active: false },
  { kind: "worktree", label: "feat/agent-loop", branch: "feat/agent-loop", active: true },
  { kind: "worktree", label: "fix/race-cond", branch: "fix/race-cond", active: false },
  { kind: "worktree", label: "test/parallel", branch: "test/parallel", active: false },
  { kind: "worktree", label: "ui/landing", branch: "ui/landing", active: false },
];

export default function AppWindow() {
  const [hovered, setHovered] = useState<number | null>(null);
  const [broadcast, setBroadcast] = useState(0);
  const [cmdText, setCmdText] = useState("");
  const ref = useRef<HTMLDivElement>(null);

  // Broadcast cycle: type a `tc broadcast` command, fire pulse, clear.
  useEffect(() => {
    let alive = true;
    const cmd = `tc broadcast --all "git pull --rebase"`;
    const cycle = async () => {
      while (alive) {
        await wait(3800);
        if (!alive) return;
        for (let i = 1; i <= cmd.length; i++) {
          if (!alive) return;
          setCmdText(cmd.slice(0, i));
          await wait(24);
        }
        await wait(380);
        setBroadcast((n) => n + 1);
        await wait(1600);
        setCmdText("");
      }
    };
    void cycle();
    return () => {
      alive = false;
    };
  }, []);

  return (
    <div className="relative" ref={ref}>
      <TerminalWindow title="touch-code" subtitle="5 worktrees · 4 panes">
        <div className="grid grid-cols-[180px_1fr] sm:grid-cols-[210px_1fr]">
          {/* Sidebar */}
          <aside className="border-r border-line/70 bg-[#0b0b0d]/80 p-2.5">
            <div className="px-1 pb-2 text-[10px] font-mono uppercase tracking-wider text-ink-dim">
              Hierarchy
            </div>
            <ul className="space-y-0.5 text-[11.5px] font-mono">
              {SIDEBAR_TREE.map((item, i) => (
                <li key={i}>
                  {item.kind === "project" ? (
                    <div className="flex items-center gap-1.5 rounded px-1.5 py-1 text-ink">
                      <span className="text-leaf-300">▾</span>
                      <span className="text-ink">{item.label}</span>
                    </div>
                  ) : (
                    <div
                      className={`ml-3 flex items-center gap-1.5 rounded px-1.5 py-1 ${
                        item.active
                          ? "bg-leaf-700/20 text-leaf-50"
                          : "text-ink-muted hover:text-ink"
                      }`}
                    >
                      <span className={item.active ? "text-leaf-300" : "text-ink-dim"}>
                        {item.active ? "●" : "○"}
                      </span>
                      <span className="truncate">{item.label}</span>
                    </div>
                  )}
                </li>
              ))}
            </ul>
          </aside>

          {/* Main: 2x2 panes */}
          <div className="relative p-2.5">
            <div className="grid grid-cols-2 gap-2.5">
              {SCRIPTS.map((s, i) => (
                <Pane
                  key={i}
                  script={s}
                  startDelay={i * 600}
                  broadcastTick={broadcast}
                  isFocused={hovered === i}
                  isDimmed={hovered !== null && hovered !== i}
                  onHover={() => setHovered(i)}
                  onLeave={() => setHovered(null)}
                />
              ))}
            </div>

            {/* SVG broadcast rays overlay */}
            <BroadcastRays trigger={broadcast} />
          </div>
        </div>

        {/* Bottom command bar */}
        <div className="flex h-9 items-center gap-2 border-t border-line/70 bg-[#0a0a0c] px-3 font-mono text-[11.5px]">
          <span className="text-ink-dim">~/touch-code</span>
          <span className="text-ink-dim">›</span>
          <span className="text-leaf-300">$</span>
          <span className="text-ink/90">{cmdText}</span>
          {cmdText && (
            <span className="inline-block h-[11px] w-[6px] bg-leaf-300 align-middle animate-blink" />
          )}
          <span className="ml-auto flex items-center gap-1.5 text-ink-dim">
            <motion.span
              animate={{ opacity: [0.4, 1, 0.4] }}
              transition={{ duration: 2.4, repeat: Infinity }}
              className="h-1.5 w-1.5 rounded-full bg-leaf-300"
            />
            <span className="text-[10px]">connected · /tmp/touch-code.sock</span>
          </span>
        </div>
      </TerminalWindow>
    </div>
  );
}

function BroadcastRays({ trigger }: { trigger: number }) {
  // Anchor at center-left of the pane grid; rays radiate to each pane center.
  const [visible, setVisible] = useState(false);
  useEffect(() => {
    if (trigger === 0) return;
    setVisible(true);
    const t = window.setTimeout(() => setVisible(false), 1000);
    return () => window.clearTimeout(t);
  }, [trigger]);

  if (!visible) return null;
  return (
    <svg
      key={trigger}
      className="pointer-events-none absolute inset-0 h-full w-full"
      viewBox="0 0 100 100"
      preserveAspectRatio="none"
    >
      {[
        { x: 25, y: 25 },
        { x: 75, y: 25 },
        { x: 25, y: 75 },
        { x: 75, y: 75 },
      ].map((p, i) => (
        <motion.line
          key={i}
          x1={0}
          y1={50}
          x2={p.x}
          y2={p.y}
          stroke="#A7C65C"
          strokeWidth={0.4}
          strokeOpacity={0.7}
          initial={{ pathLength: 0, opacity: 0 }}
          animate={{ pathLength: 1, opacity: [0, 0.9, 0] }}
          transition={{ duration: 0.8, delay: i * 0.04, ease: "easeOut" }}
        />
      ))}
    </svg>
  );
}

function wait(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}
