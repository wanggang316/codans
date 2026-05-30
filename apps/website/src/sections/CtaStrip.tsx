import { useState } from "react";
import { useTranslation } from "react-i18next";
import { motion } from "framer-motion";
import { LINKS } from "@/lib/links";

const BREW_COMMAND = "brew install --cask touch-code";

export default function CtaStrip() {
  const { t } = useTranslation();
  return (
    <section className="relative overflow-hidden border-t border-line/60 bg-bg py-28 sm:py-32">
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 -z-0"
        style={{
          background:
            "radial-gradient(700px 280px at 50% 0%, rgba(7,193,96,0.16), transparent 70%)",
        }}
      />
      <motion.div
        initial={{ opacity: 0, y: 24 }}
        whileInView={{ opacity: 1, y: 0 }}
        viewport={{ once: true, margin: "-80px" }}
        transition={{ duration: 0.8, ease: [0.22, 1, 0.36, 1] }}
        className="mx-auto max-w-[840px] px-5 text-center sm:px-8"
      >
        <h3 className="font-mono text-display-2 font-bold text-ink">{t("cta.title")}</h3>
        <p className="mx-auto mt-4 max-w-[520px] text-ink-muted">{t("cta.sub")}</p>
        <div className="mt-8 flex flex-wrap items-center justify-center gap-3">
          <a
            href={LINKS.latestDmg}
            target="_blank"
            rel="noreferrer"
            className="inline-flex h-11 items-center gap-2 rounded-full bg-wx-500 px-5 text-[14px] font-medium text-[#04231a] shadow-glow transition-colors hover:bg-wx-400"
          >
            {t("cta.primary")}
          </a>
          <BrewPill command={BREW_COMMAND} />
          <a
            href={LINKS.repo}
            target="_blank"
            rel="noreferrer"
            className="inline-flex h-11 items-center gap-2 rounded-full border border-line bg-bg-elev px-5 text-[14px] font-medium text-ink transition-colors hover:border-line-strong hover:bg-bg-card"
          >
            {t("cta.secondary")} →
          </a>
        </div>
      </motion.div>
    </section>
  );
}

function BrewPill({ command }: { command: string }) {
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
      className="inline-flex h-11 cursor-pointer items-center gap-2 rounded-full border border-wx-500/30 bg-wx-500/[0.08] px-5 font-mono text-[13px] text-wx-100 transition-colors hover:border-wx-500/50 hover:bg-wx-500/[0.12]"
    >
      <span className="text-wx-300">{copied ? "✓" : "$"}</span>
      <span>{copied ? "Copied" : command}</span>
    </button>
  );
}
