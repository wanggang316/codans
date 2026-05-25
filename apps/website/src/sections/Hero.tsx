import { useRef } from "react";
import { useTranslation } from "react-i18next";
import { motion } from "framer-motion";
import AppWindow from "@/components/AppWindow";
import Button from "@/components/Button";
import { LINKS } from "@/lib/links";

export default function Hero() {
  const { t } = useTranslation();
  const ref = useRef<HTMLDivElement>(null);

  const onMove = (e: React.MouseEvent) => {
    const el = ref.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    el.style.setProperty("--mx", `${e.clientX - rect.left}px`);
    el.style.setProperty("--my", `${e.clientY - rect.top}px`);
  };

  return (
    <section
      ref={ref}
      onMouseMove={onMove}
      className="grain relative overflow-hidden pt-28 pb-24 sm:pt-36"
      style={{ "--mx": "50%", "--my": "30%" } as React.CSSProperties}
    >
      {/* Mouse-tracked spotlight */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 opacity-100"
        style={{
          background:
            "radial-gradient(600px circle at var(--mx) var(--my), rgba(167,198,92,0.08), transparent 55%)",
        }}
      />
      {/* Static ambient glow + top gradient */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0"
        style={{
          background:
            "radial-gradient(900px 500px at 50% -100px, rgba(132,173,64,0.18), transparent 70%)",
        }}
      />
      {/* dot grid */}
      <div className="dotgrid pointer-events-none absolute inset-0 opacity-[0.35] [mask-image:radial-gradient(800px_500px_at_50%_30%,#000,transparent_70%)]" />

      <div className="relative mx-auto max-w-[1180px] px-5 sm:px-8">
        {/* Eyebrow */}
        <motion.div
          initial={{ opacity: 0, y: 8 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.6 }}
          className="mb-6 flex items-center justify-center gap-2 font-mono text-[11px] uppercase tracking-[0.2em] text-ink-muted"
        >
          <span className="h-px w-6 bg-line-strong" />
          <span>{t("hero.eyebrow")}</span>
          <span className="h-px w-6 bg-line-strong" />
        </motion.div>

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
          className="mx-auto mt-6 max-w-[640px] text-center text-[16px] leading-relaxed text-ink-muted sm:text-[17px]"
        >
          {t("hero.subtitle")}
        </motion.p>

        {/* CTAs */}
        <motion.div
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.7, delay: 0.5 }}
          className="mt-8 flex flex-wrap items-center justify-center gap-3"
        >
          <Button href={LINKS.latestDmg} variant="primary" size="lg" icon={<DownloadIcon />}>
            {t("hero.primary_cta")}
          </Button>
          <Button href={LINKS.repo} variant="secondary" size="lg" icon={<GitHubIcon />}>
            {t("hero.secondary_cta")}
          </Button>
        </motion.div>
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ duration: 0.7, delay: 0.8 }}
          className="mt-4 text-center font-mono text-[11px] text-ink-dim"
        >
          {t("hero.footnote")}
        </motion.div>

        {/* App window */}
        <motion.div
          initial={{ opacity: 0, y: 40, scale: 0.97 }}
          animate={{ opacity: 1, y: 0, scale: 1 }}
          transition={{ duration: 1.1, delay: 0.3, ease: [0.22, 1, 0.36, 1] }}
          className="relative mx-auto mt-16 max-w-[1080px]"
        >
          {/* perspective wrap for parallax */}
          <div className="relative">
            <div
              aria-hidden
              className="pointer-events-none absolute -inset-x-8 -bottom-16 -top-8 -z-10 opacity-70"
              style={{
                background:
                  "radial-gradient(700px 220px at 50% 100%, rgba(167,198,92,0.18), transparent 70%)",
              }}
            />
            <AppWindow />
          </div>
        </motion.div>
      </div>
    </section>
  );
}

// Word-by-word reveal of a sentence. We render real spaces between words
// (so the text is selectable, accessible, and copy/paste-able) and use a
// per-word overflow-clipped wrapper to mask the rise-in transform.
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
            {i < words.length - 1 ? " " : ""}
          </motion.span>
        </span>
      ))}
    </span>
  );
}

function DownloadIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2">
      <path d="M12 3v12m0 0l-4-4m4 4l4-4M5 21h14" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function GitHubIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor">
      <path d="M12 .5C5.65.5.5 5.66.5 12.02c0 5.09 3.29 9.4 7.86 10.93.57.11.78-.25.78-.55 0-.27-.01-1-.02-1.95-3.2.7-3.87-1.54-3.87-1.54-.52-1.34-1.28-1.7-1.28-1.7-1.04-.72.08-.7.08-.7 1.16.08 1.77 1.2 1.77 1.2 1.03 1.78 2.71 1.27 3.37.97.1-.76.4-1.27.74-1.56-2.55-.29-5.24-1.28-5.24-5.72 0-1.27.45-2.3 1.19-3.11-.12-.3-.52-1.49.11-3.1 0 0 .98-.32 3.2 1.18a11 11 0 015.83 0c2.22-1.5 3.2-1.18 3.2-1.18.63 1.61.23 2.8.11 3.1.74.81 1.18 1.84 1.18 3.11 0 4.45-2.7 5.42-5.27 5.71.41.36.78 1.07.78 2.16 0 1.56-.01 2.81-.01 3.19 0 .3.21.67.79.55A11.52 11.52 0 0023.5 12.02C23.5 5.66 18.35.5 12 .5z" />
    </svg>
  );
}
