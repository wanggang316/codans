import { useEffect, useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { motion, AnimatePresence } from "framer-motion";
import SectionHeader from "@/components/SectionHeader";

interface Cell {
  agent: string;
  task: string;
  branch: string;
  state: "running" | "passed" | "failed" | "waiting";
}

const AGENTS = ["claude", "codex", "cursor", "aider", "tester", "linter", "bench", "linker"];
const TASKS = [
  "patch sync race",
  "fix nil deref",
  "add migration",
  "refactor loop",
  "lint + format",
  "bump deps",
  "type-check",
  "build site",
  "rebase main",
  "regen schema",
];
const BRANCHES = [
  "feat/loop", "fix/oom", "wip/api", "test/race", "chore/deps",
  "doc/spec", "perf/io", "ui/nav", "ci/release", "main",
];

function makeCell(seed: number): Cell {
  return {
    agent: AGENTS[seed % AGENTS.length],
    task: TASKS[seed % TASKS.length],
    branch: BRANCHES[seed % BRANCHES.length],
    state: "waiting",
  };
}

const COUNT = 16;

const STATE_COLOR: Record<Cell["state"], string> = {
  waiting: "text-ink-dim",
  running: "text-leaf-300",
  passed: "text-leaf-100",
  failed: "text-red-400",
};

const STATE_DOT: Record<Cell["state"], string> = {
  waiting: "bg-ink-dim/40",
  running: "bg-leaf-300 shadow-[0_0_8px_rgba(167,198,92,0.7)] animate-breathe",
  passed: "bg-leaf-100",
  failed: "bg-red-400",
};

export default function AgentMatrix() {
  const { t } = useTranslation();
  const cells = useMemo(() => Array.from({ length: COUNT }, (_, i) => makeCell(i * 3 + 1)), []);
  const [states, setStates] = useState<Cell["state"][]>(cells.map(() => "waiting"));
  const [progresses, setProgresses] = useState<number[]>(cells.map(() => 0));
  const [hovered, setHovered] = useState<number | null>(null);

  useEffect(() => {
    // Stagger-kick: each cell starts at a different random time, runs, finishes, restarts
    const timers: number[] = [];
    cells.forEach((_, i) => {
      const start = 600 + i * 220 + Math.random() * 400;
      timers.push(
        window.setTimeout(() => beginCycle(i), start),
      );
    });

    function beginCycle(idx: number) {
      setStates((s) => {
        const next = [...s];
        next[idx] = "running";
        return next;
      });
      const total = 2200 + Math.random() * 2800;
      const startedAt = performance.now();
      const tick = () => {
        const now = performance.now();
        const p = Math.min(1, (now - startedAt) / total);
        setProgresses((arr) => {
          const next = [...arr];
          next[idx] = p;
          return next;
        });
        if (p < 1) {
          timers.push(window.requestAnimationFrame(tick) as unknown as number);
        } else {
          const passed = Math.random() > 0.12;
          setStates((s) => {
            const next = [...s];
            next[idx] = passed ? "passed" : "failed";
            return next;
          });
          timers.push(
            window.setTimeout(() => {
              setProgresses((arr) => {
                const next = [...arr];
                next[idx] = 0;
                return next;
              });
              setStates((s) => {
                const next = [...s];
                next[idx] = "waiting";
                return next;
              });
              beginCycle(idx);
            }, 1800 + Math.random() * 1500),
          );
        }
      };
      tick();
    }

    return () => {
      timers.forEach((id) => {
        window.clearTimeout(id);
        cancelAnimationFrame(id);
      });
    };
  }, [cells]);

  return (
    <section className="relative border-t border-line/60 py-28 sm:py-36">
      <div className="mx-auto max-w-[1180px] px-5 sm:px-8">
        <SectionHeader eyebrow={t("matrix.eyebrow")} title={t("matrix.title")} lead={t("matrix.lead")} />

        <div className="relative mt-14">
          <motion.div
            initial="hidden"
            whileInView="show"
            viewport={{ once: true, margin: "-100px" }}
            variants={{
              hidden: {},
              show: { transition: { staggerChildren: 0.04 } },
            }}
            className="grid grid-cols-2 gap-2.5 sm:grid-cols-4"
            onMouseLeave={() => setHovered(null)}
          >
            {cells.map((c, i) => {
              const state = states[i];
              const p = progresses[i];
              const isFocused = hovered === i;
              const isDimmed = hovered !== null && hovered !== i;
              return (
                <motion.div
                  key={i}
                  variants={{
                    hidden: { opacity: 0, y: 14 },
                    show: { opacity: 1, y: 0, transition: { duration: 0.5, ease: [0.22, 1, 0.36, 1] } },
                  }}
                  onMouseEnter={() => setHovered(i)}
                  animate={{
                    scale: isFocused ? 1.04 : isDimmed ? 0.98 : 1,
                    opacity: isDimmed ? 0.4 : 1,
                  }}
                  transition={{ type: "spring", stiffness: 240, damping: 24 }}
                  className={`relative overflow-hidden rounded-xl border bg-bg-card p-3 ${
                    isFocused ? "border-leaf-500/60 z-10 shadow-glow-soft" : "border-line"
                  }`}
                >
                  <div className="flex items-center gap-1.5 font-mono text-[10.5px]">
                    <span className={`h-1.5 w-1.5 rounded-full ${STATE_DOT[state]}`} />
                    <span className="text-ink">{c.agent}</span>
                    <span className="text-ink-dim">·</span>
                    <span className="truncate text-ink-muted">{c.branch}</span>
                  </div>
                  <div className="mt-2 h-[44px] font-mono text-[11px] leading-snug text-ink/85">
                    <span className="text-leaf-300">$ </span>
                    {c.task}
                  </div>
                  <div className="mt-2 flex items-center gap-2">
                    <div className="h-[3px] flex-1 overflow-hidden rounded-full bg-line">
                      <div
                        className={`h-full transition-[width] duration-75 ${
                          state === "failed"
                            ? "bg-red-400"
                            : state === "passed"
                              ? "bg-leaf-100"
                              : "bg-leaf-300"
                        }`}
                        style={{ width: `${p * 100}%` }}
                      />
                    </div>
                    <span className={`font-mono text-[10px] tabular-nums ${STATE_COLOR[state]}`}>
                      {state === "running"
                        ? `${Math.round(p * 100)}%`
                        : state === "passed"
                          ? "ok"
                          : state === "failed"
                            ? "err"
                            : "···"}
                    </span>
                  </div>
                  <AnimatePresence>
                    {state === "passed" && (
                      <motion.div
                        initial={{ opacity: 0 }}
                        animate={{ opacity: 1 }}
                        exit={{ opacity: 0 }}
                        className="pointer-events-none absolute inset-0"
                      >
                        <div className="scanline absolute inset-0" />
                      </motion.div>
                    )}
                  </AnimatePresence>
                </motion.div>
              );
            })}
          </motion.div>
          <div className="mt-6 text-center font-mono text-[11px] text-ink-dim">
            {t("matrix.hint")}
          </div>
        </div>
      </div>
    </section>
  );
}
