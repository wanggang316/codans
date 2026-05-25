import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { motion } from "framer-motion";
import SectionHeader from "@/components/SectionHeader";

const BRANCHES = [
  { name: "main", color: "#E8E8EA", commits: 6 },
  { name: "feat/agent-loop", color: "#A7C65C", commits: 5, forkAt: 2 },
  { name: "fix/race-cond", color: "#67e8f9", commits: 4, forkAt: 3 },
  { name: "test/parallel", color: "#fcd34d", commits: 3, forkAt: 4 },
  { name: "ui/landing", color: "#c4b5fd", commits: 4, forkAt: 2 },
];

const W = 720;
const H = 360;
const ROW_H = 56;
const COL_W = 70;
const X0 = 140;

export default function Worktree() {
  const { t } = useTranslation();
  const [tick, setTick] = useState(0);

  useEffect(() => {
    const id = window.setInterval(() => setTick((n) => n + 1), 4200);
    return () => window.clearInterval(id);
  }, []);

  return (
    <section className="relative border-t border-line/60 bg-bg py-28 sm:py-36">
      <div className="mx-auto max-w-[1180px] px-5 sm:px-8">
        <div className="grid items-center gap-16 lg:grid-cols-[1.1fr_1fr]">
          <motion.div
            initial={{ opacity: 0, scale: 0.95 }}
            whileInView={{ opacity: 1, scale: 1 }}
            viewport={{ once: true, margin: "-80px" }}
            transition={{ duration: 0.9, ease: [0.22, 1, 0.36, 1] }}
            className="order-2 lg:order-1"
          >
            <div className="relative overflow-hidden rounded-2xl border border-line bg-bg-elev p-6 shadow-window">
              <GitGraph tick={tick} />
            </div>
          </motion.div>
          <div className="order-1 lg:order-2">
            <SectionHeader
              eyebrow={t("worktree.eyebrow")}
              title={t("worktree.title")}
              lead={t("worktree.lead")}
            />
          </div>
        </div>
      </div>
    </section>
  );
}

function GitGraph({ tick }: { tick: number }) {
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="w-full">
      {/* Branch labels */}
      {BRANCHES.map((b, row) => (
        <text
          key={b.name}
          x={12}
          y={row * ROW_H + 36}
          fill={b.color}
          fillOpacity={0.95}
          fontFamily="JetBrains Mono"
          fontSize="11"
        >
          {b.name}
        </text>
      ))}

      {/* Main backbone */}
      {Array.from({ length: BRANCHES[0].commits }).map((_, i) => {
        const cx = X0 + i * COL_W;
        const cy = 30;
        return (
          <g key={`m${i}`}>
            {i > 0 && (
              <motion.line
                x1={X0 + (i - 1) * COL_W}
                y1={cy}
                x2={cx}
                y2={cy}
                stroke={BRANCHES[0].color}
                strokeOpacity={0.6}
                strokeWidth={1.4}
                initial={{ pathLength: 0 }}
                whileInView={{ pathLength: 1 }}
                viewport={{ once: true }}
                transition={{ duration: 0.5, delay: i * 0.1 }}
              />
            )}
            <motion.circle
              cx={cx}
              cy={cy}
              r={5}
              fill="#0a0a0c"
              stroke={BRANCHES[0].color}
              strokeWidth={1.6}
              initial={{ scale: 0 }}
              whileInView={{ scale: 1 }}
              viewport={{ once: true }}
              transition={{ duration: 0.4, delay: 0.2 + i * 0.1 }}
            />
          </g>
        );
      })}

      {/* Worktree branches */}
      {BRANCHES.slice(1).map((b, idx) => {
        const row = idx + 1;
        const y = row * ROW_H + 30;
        const forkX = X0 + (b.forkAt ?? 1) * COL_W;
        return (
          <g key={b.name}>
            {/* Fork curve from main → branch row */}
            <motion.path
              d={`M${forkX},30 C${forkX + 20},30 ${forkX},${y} ${forkX + 30},${y}`}
              stroke={b.color}
              strokeWidth={1.3}
              strokeOpacity={0.6}
              fill="none"
              initial={{ pathLength: 0 }}
              whileInView={{ pathLength: 1 }}
              viewport={{ once: true }}
              transition={{ duration: 0.7, delay: 0.4 + idx * 0.12 }}
            />
            {/* Commits on this branch */}
            {Array.from({ length: b.commits }).map((_, i) => {
              const cx = forkX + 30 + i * COL_W;
              return (
                <g key={i}>
                  {i > 0 && (
                    <motion.line
                      x1={cx - COL_W}
                      y1={y}
                      x2={cx}
                      y2={y}
                      stroke={b.color}
                      strokeOpacity={0.55}
                      strokeWidth={1.3}
                      initial={{ pathLength: 0 }}
                      whileInView={{ pathLength: 1 }}
                      viewport={{ once: true }}
                      transition={{ duration: 0.4, delay: 0.6 + idx * 0.12 + i * 0.08 }}
                    />
                  )}
                  <motion.circle
                    cx={cx}
                    cy={y}
                    r={4.5}
                    fill="#0a0a0c"
                    stroke={b.color}
                    strokeWidth={1.4}
                    initial={{ scale: 0 }}
                    whileInView={{ scale: 1 }}
                    viewport={{ once: true }}
                    transition={{ duration: 0.4, delay: 0.7 + idx * 0.12 + i * 0.08 }}
                  />
                </g>
              );
            })}
            {/* Pulsing tip on the latest commit */}
            <motion.circle
              key={tick + b.name}
              cx={forkX + 30 + (b.commits - 1) * COL_W}
              cy={y}
              r={4}
              fill="none"
              stroke={b.color}
              animate={{ r: [4, 16], opacity: [0.9, 0] }}
              transition={{ duration: 1.8, repeat: Infinity, delay: idx * 0.2 }}
            />
          </g>
        );
      })}
    </svg>
  );
}
