import { useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { motion, useMotionValue, useSpring, useTransform } from "framer-motion";
import { LINKS } from "@/lib/links";

/**
 * v2 Hero. The centerpiece is the real touch-code app screenshot
 * (apps/mac/.../) shipped as /hero-app.png; the previous synthetic
 * AppShell is retired. CTAs go primary (.dmg) / brew capsule (copyable) /
 * GitHub. WeChat brand green drives the accent.
 */
export default function Hero() {
  const { t } = useTranslation();
  const sectionRef = useRef<HTMLDivElement>(null);

  const onMove = (e: React.MouseEvent) => {
    const el = sectionRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    el.style.setProperty("--mx", `${e.clientX - rect.left}px`);
    el.style.setProperty("--my", `${e.clientY - rect.top}px`);
  };

  return (
    <section
      ref={sectionRef}
      onMouseMove={onMove}
      className="relative overflow-hidden pt-28 pb-20 sm:pt-36"
      style={{ "--mx": "50%", "--my": "30%" } as React.CSSProperties}
    >
      {/* Mouse-tracked spotlight */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0"
        style={{
          background:
            "radial-gradient(600px circle at var(--mx) var(--my), rgba(7,193,96,0.10), transparent 55%)",
        }}
      />
      {/* Top ambient glow */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-x-0 top-0 h-[520px]"
        style={{
          background:
            "radial-gradient(900px 480px at 50% 0%, rgba(7,193,96,0.16), transparent 70%)",
        }}
      />
      {/* Faint dot grid */}
      <div className="dotgrid pointer-events-none absolute inset-0 opacity-[0.30] [mask-image:radial-gradient(800px_500px_at_50%_30%,#000,transparent_70%)]" />

      <div className="relative mx-auto max-w-[1200px] px-5 sm:px-8">
        {/* Tagline */}
        <motion.h1
          initial={{ opacity: 0, y: 18 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.9, ease: [0.22, 1, 0.36, 1] }}
          className="text-center font-mono text-display-1 font-bold text-ink"
        >
          <RevealLine text={t("hero.tagline")} />
        </motion.h1>

        {/* Subtitle */}
        <motion.p
          initial={{ opacity: 0, y: 12 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.9, delay: 0.25, ease: [0.22, 1, 0.36, 1] }}
          className="mx-auto mt-6 max-w-[640px] text-center text-[17px] leading-relaxed text-ink-muted sm:text-[18px]"
        >
          {t("hero.subtitle")}
        </motion.p>

        {/* CTAs */}
        <motion.div
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.7, delay: 0.5 }}
          className="mt-9 flex flex-wrap items-center justify-center gap-3"
        >
          <PrimaryCta href={LINKS.latestDmg} label={t("hero.primary_cta")} />
          <BrewCapsule command={t("hero.brew_install")} />
          <GhostCta href={LINKS.repo} label={t("hero.secondary_cta")} />
        </motion.div>

        {/* App screenshot */}
        <ScreenshotShowcase />
      </div>
    </section>
  );
}

// ─── reveal helpers ─────────────────────────────────────────────────────

function RevealLine({ text }: { text: string }) {
  const words = text.split(" ");
  return (
    <span className="inline-block">
      {words.map((w, i) => (
        <span key={i} className="inline-flex overflow-hidden align-bottom">
          <motion.span
            initial={{ y: "110%" }}
            animate={{ y: "0%" }}
            transition={{ duration: 0.7, delay: 0.15 + i * 0.05, ease: [0.22, 1, 0.36, 1] }}
            className="inline-block"
          >
            {w}
            {i < words.length - 1 ? " " : ""}
          </motion.span>
        </span>
      ))}
    </span>
  );
}

// ─── CTAs ────────────────────────────────────────────────────────────────

function PrimaryCta({ href, label }: { href: string; label: string }) {
  return (
    <motion.a
      href={href}
      target="_blank"
      rel="noreferrer"
      whileHover={{ y: -1 }}
      whileTap={{ scale: 0.97 }}
      className="group relative inline-flex h-11 cursor-pointer items-center gap-2 rounded-full bg-wx-500 px-5 text-[14px] font-medium text-[#04231a] shadow-glow transition-colors hover:bg-wx-400"
    >
      <DownloadGlyph />
      <span>{label}</span>
    </motion.a>
  );
}

function GhostCta({ href, label }: { href: string; label: string }) {
  return (
    <motion.a
      href={href}
      target="_blank"
      rel="noreferrer"
      whileHover={{ y: -1 }}
      whileTap={{ scale: 0.97 }}
      className="inline-flex h-11 cursor-pointer items-center gap-2 rounded-full border border-line bg-bg-elev px-5 text-[14px] font-medium text-ink transition-colors hover:border-line-strong hover:bg-bg-card"
    >
      <GitHubGlyph />
      <span>{label}</span>
    </motion.a>
  );
}

function BrewCapsule({ command }: { command: string }) {
  const [copied, setCopied] = useState(false);
  const onCopy = async () => {
    try {
      await navigator.clipboard.writeText(command);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1600);
    } catch {
      // Older browsers without clipboard API: select-fallback via execCommand
      const ta = document.createElement("textarea");
      ta.value = command;
      document.body.appendChild(ta);
      ta.select();
      document.execCommand("copy");
      ta.remove();
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1600);
    }
  };
  return (
    <motion.button
      type="button"
      onClick={onCopy}
      whileHover={{ y: -1 }}
      whileTap={{ scale: 0.97 }}
      title="Click to copy"
      className="group inline-flex h-11 cursor-pointer items-center gap-2 rounded-full border border-wx-500/30 bg-wx-500/[0.08] px-5 font-mono text-[13px] text-wx-100 transition-colors hover:border-wx-500/50 hover:bg-wx-500/[0.12]"
    >
      <span className="text-wx-300">{copied ? "✓" : "$"}</span>
      <span>{copied ? "Copied" : command}</span>
    </motion.button>
  );
}

// ─── glyphs ──────────────────────────────────────────────────────────────

function DownloadGlyph() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4">
      <path d="M12 3v12m0 0l-4-4m4 4l4-4M5 21h14" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function GitHubGlyph() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor">
      <path d="M12 .5C5.65.5.5 5.66.5 12.02c0 5.09 3.29 9.4 7.86 10.93.57.11.78-.25.78-.55 0-.27-.01-1-.02-1.95-3.2.7-3.87-1.54-3.87-1.54-.52-1.34-1.28-1.7-1.28-1.7-1.04-.72.08-.7.08-.7 1.16.08 1.77 1.2 1.77 1.2 1.03 1.78 2.71 1.27 3.37.97.1-.76.4-1.27.74-1.56-2.55-.29-5.24-1.28-5.24-5.72 0-1.27.45-2.3 1.19-3.11-.12-.3-.52-1.49.11-3.1 0 0 .98-.32 3.2 1.18a11 11 0 015.83 0c2.22-1.5 3.2-1.18 3.2-1.18.63 1.61.23 2.8.11 3.1.74.81 1.18 1.84 1.18 3.11 0 4.45-2.7 5.42-5.27 5.71.41.36.78 1.07.78 2.16 0 1.56-.01 2.81-.01 3.19 0 .3.21.67.79.55A11.52 11.52 0 0023.5 12.02C23.5 5.66 18.35.5 12 .5z" />
    </svg>
  );
}

// ─── screenshot showcase with mouse-driven parallax tilt ─────────────────

function ScreenshotShowcase() {
  const ref = useRef<HTMLDivElement>(null);
  const mx = useMotionValue(0);
  const my = useMotionValue(0);
  // Tilt is small so the image stays readable; springs smooth the motion.
  const rx = useSpring(useTransform(my, [-0.5, 0.5], [3, -3]), { stiffness: 180, damping: 22 });
  const ry = useSpring(useTransform(mx, [-0.5, 0.5], [-3, 3]), { stiffness: 180, damping: 22 });

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
      initial={{ opacity: 0, y: 40, scale: 0.97 }}
      animate={{ opacity: 1, y: 0, scale: 1 }}
      transition={{ duration: 1.1, delay: 0.3, ease: [0.22, 1, 0.36, 1] }}
      style={{ rotateX: rx, rotateY: ry, transformPerspective: 1200 }}
      className="relative mx-auto mt-16 w-full max-w-[1120px]"
    >
      {/* underglow */}
      <div
        aria-hidden
        className="pointer-events-none absolute -inset-x-8 -bottom-16 -top-4 -z-10 opacity-80"
        style={{
          background:
            "radial-gradient(720px 240px at 50% 100%, rgba(7,193,96,0.20), transparent 70%)",
        }}
      />
      {/* window frame */}
      <div className="relative overflow-hidden rounded-[14px] border border-white/[0.08] bg-bg-elev shadow-window">
        {/* Specular highlight that scans on hover */}
        <div className="group/img relative">
          <img
            src="/hero-app.png"
            alt="touch-code window: sidebar with multiple projects and worktrees, terminal panes, command palette open"
            width={2400}
            height={1473}
            className="block h-auto w-full"
            draggable={false}
          />
          <span
            aria-hidden
            className="pointer-events-none absolute inset-0 opacity-0 transition-opacity duration-500 group-hover/img:opacity-100"
            style={{
              background:
                "linear-gradient(120deg, transparent 0%, rgba(255,255,255,0.06) 45%, transparent 60%)",
              mixBlendMode: "screen",
            }}
          />
        </div>
      </div>
    </motion.div>
  );
}
