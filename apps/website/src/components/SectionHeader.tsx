import { motion } from "framer-motion";
import { ReactNode } from "react";

interface Props {
  eyebrow: string;
  title: string;
  lead?: string;
  align?: "left" | "center";
  trailing?: ReactNode;
}

export default function SectionHeader({ eyebrow, title, lead, align = "left", trailing }: Props) {
  const alignClass = align === "center" ? "text-center mx-auto" : "text-left";
  return (
    <motion.div
      initial={{ opacity: 0, y: 20 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: "-80px" }}
      transition={{ duration: 0.7, ease: [0.22, 1, 0.36, 1] }}
      className={`max-w-[640px] ${alignClass}`}
    >
      <div className="flex items-center gap-2 font-mono text-[11px] uppercase tracking-[0.2em] text-leaf-300/80">
        <span className="h-px w-6 bg-leaf-500/40" />
        {eyebrow}
      </div>
      <h2 className="mt-4 font-mono text-display-2 font-bold text-ink">{title}</h2>
      {lead && (
        <p className="mt-5 text-[16px] leading-relaxed text-ink-muted sm:text-[17px]">{lead}</p>
      )}
      {trailing}
    </motion.div>
  );
}
