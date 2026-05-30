import { useState } from "react";
import { useTranslation } from "react-i18next";
import { motion } from "framer-motion";

/**
 * §4 — Worktree concept. Manifesto-style layout (centred, single column)
 * with a custom worktree glyph as the visual anchor. The glyph reads as
 * "one repository, four checkouts" — a central .git hub with four
 * branches splaying out to their own working directories.
 */
export default function WorktreeSection() {
  const { t } = useTranslation();
  return (
    <section className="relative overflow-hidden border-t border-line/60 bg-bg py-28 sm:py-36">
      {/* faint underglow */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-x-0 top-0 h-[420px]"
        style={{
          background:
            "radial-gradient(640px 320px at 50% 0%, rgba(7,193,96,0.12), transparent 70%)",
        }}
      />

      <div className="relative mx-auto max-w-[820px] px-5 text-center sm:px-8">
        <WorktreeGlyph />

        <motion.h2
          initial={{ opacity: 0, y: 18 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.7, delay: 0.1 }}
          className="mt-12 font-mono text-display-2 font-bold text-ink"
        >
          {t("worktree.title")}
        </motion.h2>

        <motion.p
          initial={{ opacity: 0, y: 12 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.7, delay: 0.2 }}
          className="mx-auto mt-5 max-w-[640px] text-[17px] leading-relaxed text-ink-muted"
        >
          {t("worktree.lead")}
        </motion.p>

        <motion.div
          initial={{ opacity: 0 }}
          whileInView={{ opacity: 1 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.7, delay: 0.35 }}
          className="mt-8 inline-block font-mono text-[14px] italic text-wx-200"
        >
          {t("worktree.punchline")}
        </motion.div>
      </div>
    </section>
  );
}

// ─── worktree glyph ─────────────────────────────────────────────────────

interface Branch {
  id: string;
  label: string;
  /** Angle in degrees (0 = right, increases clockwise) */
  angle: number;
  tint?: string;
  active?: boolean;
}

const BRANCHES: Branch[] = [
  { id: "a", label: "main",         angle: 200, tint: "#A7C65C", active: true },
  { id: "b", label: "feat/agent",   angle: 250, tint: "#07C160" },
  { id: "c", label: "fix/race",     angle: 300, tint: "#F85149" },
  { id: "d", label: "test/parallel", angle: 340, tint: "#D29922" },
];

const HUB_X = 50;
const HUB_Y = 64;
const RADIUS_INNER = 8;
const RADIUS_OUTER = 38;

function polar(cx: number, cy: number, angleDeg: number, r: number) {
  const a = (angleDeg * Math.PI) / 180;
  return { x: cx + r * Math.cos(a), y: cy + r * Math.sin(a) };
}

function WorktreeGlyph() {
  const [hovered, setHovered] = useState<string | null>(null);

  return (
    <motion.div
      initial={{ opacity: 0, scale: 0.92 }}
      whileInView={{ opacity: 1, scale: 1 }}
      viewport={{ once: true, margin: "-100px" }}
      transition={{ duration: 0.9, ease: [0.22, 1, 0.36, 1] }}
      className="mx-auto w-full max-w-[420px]"
      onMouseLeave={() => setHovered(null)}
    >
      <svg viewBox="0 0 100 100" className="h-auto w-full" aria-hidden>
        {/* Outer ring on the hub — implies "shared upstream" */}
        <motion.circle
          cx={HUB_X}
          cy={HUB_Y}
          r={RADIUS_INNER + 4}
          fill="none"
          stroke="rgba(7,193,96,0.25)"
          strokeWidth="0.4"
          strokeDasharray="2 2"
          initial={{ opacity: 0 }}
          whileInView={{ opacity: 1 }}
          viewport={{ once: true }}
          transition={{ duration: 0.6, delay: 0.3 }}
        />

        {/* Pulsing rings on the hub — only when a branch is active. */}
        <motion.circle
          cx={HUB_X}
          cy={HUB_Y}
          r={RADIUS_INNER}
          fill="none"
          stroke="rgba(7,193,96,0.5)"
          strokeWidth="0.6"
          animate={{ r: [RADIUS_INNER, RADIUS_INNER + 6], opacity: [0.55, 0] }}
          transition={{ duration: 2.6, repeat: Infinity, ease: "easeOut" }}
        />

        {/* Branch lines */}
        {BRANCHES.map((b, i) => {
          const start = polar(HUB_X, HUB_Y, b.angle, RADIUS_INNER);
          const end = polar(HUB_X, HUB_Y, b.angle, RADIUS_OUTER);
          const isOther = hovered !== null && hovered !== b.id;
          return (
            <motion.path
              key={`l-${b.id}`}
              d={`M ${start.x} ${start.y} L ${end.x} ${end.y}`}
              stroke={b.tint ?? "#FFFFFF"}
              strokeWidth={hovered === b.id ? 1.0 : 0.7}
              strokeLinecap="round"
              opacity={isOther ? 0.25 : 0.85}
              initial={{ pathLength: 0 }}
              whileInView={{ pathLength: 1 }}
              viewport={{ once: true }}
              transition={{ duration: 0.7, delay: 0.5 + i * 0.08, ease: "easeOut" }}
            />
          );
        })}

        {/* Hub — central filled circle */}
        <motion.circle
          cx={HUB_X}
          cy={HUB_Y}
          r={RADIUS_INNER}
          fill="#07C160"
          initial={{ scale: 0 }}
          whileInView={{ scale: 1 }}
          viewport={{ once: true }}
          transition={{ duration: 0.5, delay: 0.15, ease: [0.22, 1, 0.36, 1] }}
          style={{ transformOrigin: `${HUB_X}px ${HUB_Y}px` }}
        />
        <text
          x={HUB_X}
          y={HUB_Y + 1.5}
          textAnchor="middle"
          fill="#04231a"
          fontSize="4.6"
          fontWeight="700"
          fontFamily="JetBrains Mono, monospace"
        >
          .git
        </text>

        {/* Branch endpoints — folder marks + labels */}
        {BRANCHES.map((b, i) => {
          const end = polar(HUB_X, HUB_Y, b.angle, RADIUS_OUTER);
          // Folder + label position: same point as the line end; label
          // shifted further along the same ray so it doesn't overlap.
          const labelAt = polar(HUB_X, HUB_Y, b.angle, RADIUS_OUTER + 11);
          const labelAnchor = Math.cos((b.angle * Math.PI) / 180) > 0 ? "start" : "end";
          const isOther = hovered !== null && hovered !== b.id;
          return (
            <motion.g
              key={`n-${b.id}`}
              initial={{ opacity: 0, scale: 0.6 }}
              whileInView={{ opacity: 1, scale: 1 }}
              viewport={{ once: true }}
              transition={{ duration: 0.45, delay: 0.85 + i * 0.08 }}
              onMouseEnter={() => setHovered(b.id)}
              style={{
                cursor: "pointer",
                opacity: isOther ? 0.4 : 1,
                transition: "opacity 0.2s",
              }}
            >
              {/* directory glyph: small rounded rect */}
              <rect
                x={end.x - 3}
                y={end.y - 2.2}
                width="6"
                height="4.4"
                rx="0.8"
                fill={b.tint ?? "#FFFFFF"}
                fillOpacity={hovered === b.id ? 0.95 : 0.75}
              />
              {/* directory "tab" */}
              <rect
                x={end.x - 3}
                y={end.y - 3.0}
                width="2.2"
                height="0.9"
                rx="0.3"
                fill={b.tint ?? "#FFFFFF"}
                fillOpacity={hovered === b.id ? 0.95 : 0.75}
              />
              {/* label */}
              <text
                x={labelAt.x}
                y={labelAt.y + 1}
                textAnchor={labelAnchor}
                fill={hovered === b.id ? "#E8E8EA" : "#8A8A92"}
                fontSize="3.6"
                fontFamily="JetBrains Mono, monospace"
              >
                {b.label}
              </text>
              {b.active && (
                <circle
                  cx={end.x + 3.8}
                  cy={end.y - 2.6}
                  r="0.9"
                  fill="#FFA657"
                />
              )}
            </motion.g>
          );
        })}
      </svg>
    </motion.div>
  );
}
