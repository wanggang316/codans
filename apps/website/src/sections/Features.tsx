import { useTranslation } from "react-i18next";
import { motion } from "framer-motion";

interface FeatureItem {
  title: string;
  body: string;
}

/**
 * The "什么是 TouchCode？" intro region below the hero — opencode.ai-style:
 * text only, single column, no illustrations. A heading + intro paragraph,
 * then the feature list in the exact order authored in landing.json
 * (`features.items` is an ordered array — order on the page === order in
 * the JSON). Copy is rendered verbatim; this component never rewords it.
 *
 * The section reads as Chinese copy, so headings + labels use the sans
 * stack (Geist for Latin, system CJK for Chinese) rather than the Latin
 * monospace used in the English hero.
 */
export default function Features() {
  const { t } = useTranslation();
  const items = t("features.items", { returnObjects: true }) as FeatureItem[];

  return (
    <section className="relative border-t border-line/60 bg-bg py-24 sm:py-32">
      <div className="mx-auto max-w-[720px] px-5 sm:px-8">
        {/* Heading + intro */}
        <motion.div
          initial={{ opacity: 0, y: 16 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.6, ease: [0.22, 1, 0.36, 1] }}
        >
          <h2 className="text-display-2 font-bold tracking-tight text-ink">
            {t("features.heading")}
          </h2>
          <p className="mt-5 text-[17px] leading-relaxed text-ink-muted">
            {t("features.intro")}
          </p>
        </motion.div>

        {/* Single-column feature list, in authored order */}
        <div className="mt-14 flex flex-col">
          {items.map((item, i) => (
            <motion.div
              key={i}
              initial={{ opacity: 0, y: 14 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, margin: "-60px" }}
              transition={{ duration: 0.5, delay: i === 0 ? 0 : 0.04, ease: [0.22, 1, 0.36, 1] }}
              className="border-t border-line/70 py-7 first:border-t-0 first:pt-0"
            >
              <h3 className="text-[17px] font-semibold text-ink">{item.title}</h3>
              <p className="mt-2.5 text-[15px] leading-relaxed text-ink-muted">{item.body}</p>
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
}
