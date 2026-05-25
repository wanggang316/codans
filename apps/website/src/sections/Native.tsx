import { useRef } from "react";
import { useTranslation } from "react-i18next";
import { motion, useMotionValue, useSpring, useTransform } from "framer-motion";
import SectionHeader from "@/components/SectionHeader";

const CARDS = [
  { label: "libghostty", sub: "Terminals you can feel.", glyph: "▎" },
  { label: "Swift 6", sub: "Strict concurrency.", glyph: "≋" },
  { label: "Apple Silicon", sub: "Tuned for M-series.", glyph: "✦" },
  { label: "Xcode 26", sub: "Built with the latest toolchain.", glyph: "⌘" },
];

export default function Native() {
  const { t } = useTranslation();
  return (
    <section className="relative border-t border-line/60 bg-bg py-28 sm:py-36">
      <div className="mx-auto max-w-[1180px] px-5 sm:px-8">
        <SectionHeader
          eyebrow={t("native.eyebrow")}
          title={t("native.title")}
          lead={t("native.lead")}
          align="center"
        />
        <div className="mx-auto mt-14 grid max-w-[1080px] grid-cols-2 gap-4 sm:grid-cols-4">
          {CARDS.map((c, i) => (
            <TiltCard key={c.label} delay={i * 0.08}>
              <div className="text-leaf-300 text-3xl font-mono">{c.glyph}</div>
              <div className="mt-6 font-mono text-[14px] text-ink">{c.label}</div>
              <div className="mt-1.5 text-[12px] text-ink-muted">{c.sub}</div>
            </TiltCard>
          ))}
        </div>
      </div>
    </section>
  );
}

function TiltCard({ children, delay = 0 }: { children: React.ReactNode; delay?: number }) {
  const ref = useRef<HTMLDivElement>(null);
  const mx = useMotionValue(0);
  const my = useMotionValue(0);
  const rx = useSpring(useTransform(my, [-0.5, 0.5], [6, -6]), { stiffness: 220, damping: 22 });
  const ry = useSpring(useTransform(mx, [-0.5, 0.5], [-6, 6]), { stiffness: 220, damping: 22 });

  const onMove = (e: React.MouseEvent) => {
    const el = ref.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    mx.set((e.clientX - r.left) / r.width - 0.5);
    my.set((e.clientY - r.top) / r.height - 0.5);
  };
  const onLeave = () => {
    mx.set(0);
    my.set(0);
  };

  return (
    <motion.div
      ref={ref}
      onMouseMove={onMove}
      onMouseLeave={onLeave}
      style={{ rotateX: rx, rotateY: ry, transformPerspective: 900 }}
      initial={{ opacity: 0, y: 20 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: "-80px" }}
      transition={{ duration: 0.6, delay, ease: [0.22, 1, 0.36, 1] }}
      className="group relative overflow-hidden rounded-xl border border-line bg-bg-card p-6 transition-colors hover:border-leaf-500/50"
    >
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 opacity-0 transition-opacity duration-300 group-hover:opacity-100"
        style={{
          background:
            "radial-gradient(220px circle at 50% 30%, rgba(167,198,92,0.15), transparent 70%)",
        }}
      />
      <div className="relative">{children}</div>
    </motion.div>
  );
}
