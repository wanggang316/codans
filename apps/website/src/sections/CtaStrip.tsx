import { useState } from "react";
import { useTranslation } from "react-i18next";
import { motion } from "framer-motion";
import { LINKS } from "@/lib/links";

export default function CtaStrip() {
  const { t } = useTranslation();
  return (
    <section className="relative overflow-hidden border-t border-line/60 bg-bg py-28 sm:py-32">
      <motion.div
        initial={{ opacity: 0, y: 20 }}
        whileInView={{ opacity: 1, y: 0 }}
        viewport={{ once: true, margin: "-80px" }}
        transition={{ duration: 0.7, ease: [0.22, 1, 0.36, 1] }}
        className="mx-auto flex max-w-[840px] flex-col items-center px-5 text-center sm:px-8"
      >
        <h3 className="font-mono text-display-2 font-bold text-ink">{t("cta.title")}</h3>
        <p className="mx-auto mt-4 max-w-[520px] text-ink-muted">{t("cta.sub")}</p>
        <div className="mt-8 flex items-center justify-center">
          <a
            href={LINKS.latestDmg}
            target="_blank"
            rel="noreferrer"
            className="inline-flex h-11 items-center gap-2 rounded-full bg-acc-500 px-5 text-[14px] font-medium text-white shadow-glow transition-colors hover:bg-acc-400"
          >
            {t("cta.primary")}
          </a>
        </div>
        <BrewLine command={t("hero.brew_install")} />
      </motion.div>
    </section>
  );
}

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
      className="group mt-4 inline-flex cursor-pointer items-center gap-2 rounded-md px-2.5 py-1.5 font-mono text-[12.5px] text-ink-muted transition-colors hover:bg-white/[0.04] hover:text-ink"
    >
      <span className="text-acc-300">$</span>
      <span>{copied ? "Copied to clipboard" : command}</span>
    </button>
  );
}
