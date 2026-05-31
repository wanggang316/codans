import { Fragment, useState } from "react";
import { useTranslation } from "react-i18next";
import { motion } from "framer-motion";
import { LINKS } from "@/lib/links";

/**
 * v2 Hero. The centerpiece is the real touch-code app screenshot shipped
 * as /hero-app.png. Background is intentionally flat (no mouse-tracked
 * spotlight, no coloured radial wash) — just a faint dot grid — so the
 * accent green reads as a deliberate mark rather than ambient AI haze.
 */
export default function Hero() {
  const { t } = useTranslation();

  return (
    <section className="relative overflow-hidden pt-28 pb-20 sm:pt-32">
      {/* Faint dot grid, masked to fade at the edges. No colour. */}
      <div className="dotgrid pointer-events-none absolute inset-0 opacity-[0.22] [mask-image:radial-gradient(820px_460px_at_50%_22%,#000,transparent_72%)]" />

      <div className="relative mx-auto max-w-[1200px] px-5 sm:px-8">
        {/* Tagline */}
        <motion.h1
          initial={{ opacity: 0, y: 18 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.9, ease: [0.22, 1, 0.36, 1] }}
          className="text-center font-mono text-display-1 font-bold tracking-tight text-ink"
        >
          <RevealLine text={t("hero.tagline")} />
        </motion.h1>

        {/* Subtitle */}
        <motion.p
          initial={{ opacity: 0, y: 12 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.9, delay: 0.25, ease: [0.22, 1, 0.36, 1] }}
          className="mx-auto mt-6 max-w-[620px] text-center text-[17px] leading-relaxed text-ink-muted sm:text-[18px]"
        >
          {t("hero.subtitle")}
        </motion.p>

        {/* CTAs */}
        <motion.div
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.7, delay: 0.5 }}
          className="mt-9 flex flex-col items-center gap-4"
        >
          <PrimaryCta href={LINKS.latestDmg} label={t("hero.primary_cta")} />
          <BrewLine command={t("hero.brew_install")} />
        </motion.div>

        {/* App screenshot */}
        <ScreenshotShowcase />
      </div>
    </section>
  );
}

// ─── reveal helper (real spaces between words, clip-masked rise-in) ───────

function RevealLine({ text }: { text: string }) {
  const words = text.split(" ");
  return (
    <span className="inline-block">
      {words.map((w, i) => (
        <Fragment key={i}>
          <span className="inline-flex overflow-hidden align-bottom">
            <motion.span
              initial={{ y: "110%" }}
              animate={{ y: "0%" }}
              transition={{ duration: 0.7, delay: 0.15 + i * 0.05, ease: [0.22, 1, 0.36, 1] }}
              className="inline-block"
            >
              {w}
            </motion.span>
          </span>
          {/* Real, non-clipped space between words — a trailing space
              inside the inline-block above gets collapsed by the browser,
              which is what glued the words together. */}
          {i < words.length - 1 ? " " : ""}
        </Fragment>
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
      whileTap={{ scale: 0.98 }}
      className="inline-flex h-11 cursor-pointer items-center gap-2 rounded-full bg-acc-500 px-5 text-[14px] font-medium text-white shadow-glow transition-colors hover:bg-acc-400"
    >
      <DownloadGlyph />
      <span>{label}</span>
    </motion.a>
  );
}

/** Small copyable install line under the button — the opencode pattern. */
function BrewLine({ command }: { command: string }) {
  const [copied, setCopied] = useState(false);
  const onCopy = async () => {
    try {
      await navigator.clipboard.writeText(command);
    } catch {
      const ta = document.createElement("textarea");
      ta.value = command;
      document.body.appendChild(ta);
      ta.select();
      document.execCommand("copy");
      ta.remove();
    }
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1600);
  };
  return (
    <button
      type="button"
      onClick={onCopy}
      title="Click to copy"
      className="group inline-flex cursor-pointer items-center gap-2 rounded-md px-2.5 py-1.5 font-mono text-[12.5px] text-ink-muted transition-colors hover:bg-white/[0.04] hover:text-ink"
    >
      <span className="text-acc-300">$</span>
      <span>{copied ? "Copied to clipboard" : command}</span>
      <CopyGlyph copied={copied} />
    </button>
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

function CopyGlyph({ copied }: { copied: boolean }) {
  if (copied) {
    return (
      <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" className="text-acc-300">
        <path d="M5 12l4 4 10-10" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    );
  }
  return (
    <svg
      width="13"
      height="13"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      className="opacity-0 transition-opacity group-hover:opacity-100"
    >
      <rect x="9" y="9" width="11" height="11" rx="2" />
      <path d="M5 15V5a2 2 0 012-2h10" strokeLinecap="round" />
    </svg>
  );
}

// ─── screenshot showcase (static — fades in once, no hover tilt) ─────────

function ScreenshotShowcase() {
  return (
    <motion.div
      initial={{ opacity: 0, y: 40, scale: 0.97 }}
      animate={{ opacity: 1, y: 0, scale: 1 }}
      transition={{ duration: 1.1, delay: 0.3, ease: [0.22, 1, 0.36, 1] }}
      className="relative mx-auto mt-16 w-full max-w-[1120px]"
    >
      {/* Neutral underglow for depth — no colour. */}
      <div
        aria-hidden
        className="pointer-events-none absolute -inset-x-6 -bottom-12 -top-2 -z-10"
        style={{
          background:
            "radial-gradient(720px 220px at 50% 100%, rgba(255,255,255,0.05), transparent 72%)",
        }}
      />
      <div className="relative overflow-hidden rounded-[24px] border border-white/[0.08] bg-bg-elev shadow-window">
        <img
          src="/hero-app.png"
          alt="TouchCode window: sidebar with multiple projects and worktrees, terminal panes, and the command palette open"
          width={2400}
          height={1473}
          className="block h-auto w-full"
          draggable={false}
        />
      </div>
    </motion.div>
  );
}
