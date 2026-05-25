import { useTranslation } from "react-i18next";
import { motion } from "framer-motion";
import Button from "@/components/Button";
import { LINKS } from "@/lib/links";

export default function CtaStrip() {
  const { t } = useTranslation();
  return (
    <section className="relative overflow-hidden border-t border-line/60 bg-bg py-28 sm:py-32">
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 -z-0"
        style={{
          background:
            "radial-gradient(700px 280px at 50% 0%, rgba(167,198,92,0.16), transparent 70%)",
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
          <Button href={LINKS.latestDmg} variant="primary" size="lg">
            {t("cta.primary")}
          </Button>
          <Button href={LINKS.repo} variant="ghost" size="lg">
            {t("cta.secondary")} →
          </Button>
        </div>
      </motion.div>
    </section>
  );
}
