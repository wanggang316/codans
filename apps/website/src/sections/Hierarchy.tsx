import { useState } from "react";
import { useTranslation } from "react-i18next";
import { motion } from "framer-motion";
import SectionHeader from "@/components/SectionHeader";

const LEVELS = [
  { key: "project", label: "Project", count: 1, color: "#C5E075" },
  { key: "worktree", label: "Worktree", count: 4, color: "#A7C65C" },
  { key: "tab", label: "Tab", count: 8, color: "#83AD40" },
  { key: "pane", label: "Pane", count: 16, color: "#547B32" },
];

export default function Hierarchy() {
  const { t } = useTranslation();
  const [active, setActive] = useState<number>(3);

  return (
    <section className="relative border-t border-line/60 bg-bg py-28 sm:py-36">
      <div className="mx-auto max-w-[1180px] px-5 sm:px-8">
        <div className="grid items-center gap-16 lg:grid-cols-[1fr_1.1fr]">
          <SectionHeader
            eyebrow={t("hierarchy.eyebrow")}
            title={t("hierarchy.title")}
            lead={t("hierarchy.lead")}
            trailing={
              <div className="mt-8 flex flex-wrap gap-2">
                {LEVELS.map((l, i) => (
                  <button
                    key={l.key}
                    onMouseEnter={() => setActive(i)}
                    className={`rounded-full border px-3 py-1.5 font-mono text-[12px] transition-colors ${
                      active === i
                        ? "border-leaf-500/60 bg-leaf-700/20 text-leaf-50"
                        : "border-line text-ink-muted hover:text-ink"
                    }`}
                  >
                    {l.label}
                  </button>
                ))}
              </div>
            }
          />

          {/* Animated tree */}
          <motion.div
            initial={{ opacity: 0, scale: 0.96 }}
            whileInView={{ opacity: 1, scale: 1 }}
            viewport={{ once: true, margin: "-80px" }}
            transition={{ duration: 0.9, ease: [0.22, 1, 0.36, 1] }}
            className="relative aspect-[5/4] w-full"
          >
            <HierarchyTree activeLevel={active} />
          </motion.div>
        </div>
      </div>
    </section>
  );
}

function HierarchyTree({ activeLevel }: { activeLevel: number }) {
  // Layout: 4 horizontal rows of nodes; lines connect parents to children.
  const W = 600;
  const H = 480;
  const rowY = [70, 190, 310, 430];

  const nodes: { row: number; idx: number; x: number; parent?: number }[] = [];

  LEVELS.forEach((lvl, row) => {
    const n = lvl.count;
    const spread = Math.min(560, n * 60);
    const startX = W / 2 - spread / 2 + spread / (n * 2);
    for (let i = 0; i < n; i++) {
      const x = startX + (i * spread) / n;
      let parent: number | undefined;
      if (row > 0) {
        const prevCount = LEVELS[row - 1].count;
        parent = Math.floor((i / n) * prevCount);
      }
      nodes.push({ row, idx: i, x, parent });
    }
  });

  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="absolute inset-0 h-full w-full">
      {/* Connections */}
      {nodes
        .filter((n) => n.parent !== undefined)
        .map((n, i) => {
          const parents = nodes.filter((p) => p.row === n.row - 1);
          const p = parents[n.parent!];
          const isHighlight = activeLevel === n.row || activeLevel === n.row - 1;
          return (
            <motion.path
              key={i}
              d={`M${p.x},${rowY[p.row]} C${p.x},${(rowY[p.row] + rowY[n.row]) / 2} ${n.x},${(rowY[p.row] + rowY[n.row]) / 2} ${n.x},${rowY[n.row]}`}
              stroke={isHighlight ? "#A7C65C" : "#2A2A2F"}
              strokeWidth={isHighlight ? 1.2 : 0.8}
              strokeOpacity={isHighlight ? 0.65 : 0.5}
              fill="none"
              initial={{ pathLength: 0 }}
              whileInView={{ pathLength: 1 }}
              viewport={{ once: true }}
              transition={{ duration: 1.2, delay: 0.1 + n.row * 0.15, ease: "easeOut" }}
            />
          );
        })}

      {/* Nodes */}
      {nodes.map((n, i) => {
        const lvl = LEVELS[n.row];
        const isActive = activeLevel === n.row;
        const r = n.row === 0 ? 14 : n.row === 1 ? 10 : n.row === 2 ? 7 : 5;
        return (
          <motion.g
            key={i}
            initial={{ opacity: 0, scale: 0.4 }}
            whileInView={{ opacity: 1, scale: 1 }}
            viewport={{ once: true }}
            transition={{ duration: 0.5, delay: 0.2 + n.row * 0.2 + n.idx * 0.025 }}
          >
            <circle cx={n.x} cy={rowY[n.row]} r={r + (isActive ? 3 : 0)} fill={lvl.color} fillOpacity={isActive ? 0.18 : 0.0} />
            <circle
              cx={n.x}
              cy={rowY[n.row]}
              r={r}
              fill={isActive ? lvl.color : "#0a0a0c"}
              stroke={lvl.color}
              strokeWidth={isActive ? 1.6 : 1}
              strokeOpacity={isActive ? 1 : 0.55}
            />
            {isActive && (
              <motion.circle
                cx={n.x}
                cy={rowY[n.row]}
                r={r}
                fill="none"
                stroke={lvl.color}
                strokeWidth={1}
                animate={{ r: [r, r + 10], opacity: [0.6, 0] }}
                transition={{ duration: 1.6, repeat: Infinity, delay: n.idx * 0.05 }}
              />
            )}
          </motion.g>
        );
      })}

      {/* Row labels */}
      {LEVELS.map((l, row) => (
        <text
          key={l.key}
          x={20}
          y={rowY[row] + 4}
          fill={activeLevel === row ? "#E8E8EA" : "#5A5A62"}
          fontFamily="JetBrains Mono"
          fontSize="11"
          textAnchor="start"
        >
          {l.label.toUpperCase()}
          <tspan fill="#5A5A62" dx="6">×{l.count}</tspan>
        </text>
      ))}
    </svg>
  );
}
