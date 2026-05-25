import { useTranslation } from "react-i18next";
import { motion } from "framer-motion";
import SectionHeader from "@/components/SectionHeader";
import { useTypewriter } from "@/lib/useTypewriter";

const COMMANDS = [
  "$ tc tree",
  "$ tc tab new --pane 'claude'",
  "$ tc send tab-1 \"git diff main\"",
  "$ tc broadcast --all \"pnpm test\"",
];

const OUTPUT = [
  "touch-code",
  "├── main",
  "│   └── ●● 2 tabs · 4 panes",
  "├── feat/agent-loop",
  "│   └── ●  1 tab  · 1 pane",
  "└── ui/landing",
  "    └── ●● 2 tabs · 3 panes",
];

export default function CliSection() {
  const { t } = useTranslation();
  const lines = useTypewriter(COMMANDS, { speed: 30, pauseEnd: 4000 });

  return (
    <section className="relative border-t border-line/60 bg-bg py-28 sm:py-36">
      <div className="mx-auto max-w-[1180px] px-5 sm:px-8">
        <SectionHeader
          eyebrow={t("cli.eyebrow")}
          title={t("cli.title")}
          lead={t("cli.lead")}
          align="center"
        />

        <motion.div
          initial={{ opacity: 0, y: 30 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.8, ease: [0.22, 1, 0.36, 1] }}
          className="mx-auto mt-14 grid max-w-[960px] gap-3 lg:grid-cols-[1fr_1fr]"
        >
          {/* Left: typing terminal */}
          <div className="overflow-hidden rounded-xl border border-line bg-[#0c0c0e]">
            <div className="flex h-7 items-center justify-between border-b border-line/70 px-3 font-mono text-[11px] text-ink-dim">
              <span>~/touch-code</span>
              <span>zsh</span>
            </div>
            <div className="h-[260px] p-4 font-mono text-[12.5px] leading-[1.7]">
              {lines.map((l, i) => {
                const isLast = i === lines.length - 1;
                return (
                  <div key={i} className="text-ink/90">
                    <span className="text-leaf-300">❯ </span>
                    <span>{l.slice(2)}</span>
                    {isLast && (
                      <span className="ml-0.5 inline-block h-[12px] w-[6px] -mb-[1px] bg-leaf-300 align-middle animate-blink" />
                    )}
                  </div>
                );
              })}
            </div>
          </div>

          {/* Right: tree output (always visible) */}
          <div className="overflow-hidden rounded-xl border border-line bg-[#0c0c0e]">
            <div className="flex h-7 items-center justify-between border-b border-line/70 px-3 font-mono text-[11px] text-ink-dim">
              <span>$ tc tree</span>
              <span className="flex items-center gap-1.5">
                <span className="h-1.5 w-1.5 rounded-full bg-leaf-300 animate-breathe" />
                live
              </span>
            </div>
            <div className="h-[260px] p-4 font-mono text-[12.5px] leading-[1.7] text-ink/85">
              {OUTPUT.map((l, i) => (
                <motion.div
                  key={i}
                  initial={{ opacity: 0, x: -8 }}
                  whileInView={{ opacity: 1, x: 0 }}
                  viewport={{ once: true }}
                  transition={{ duration: 0.4, delay: 0.4 + i * 0.06 }}
                >
                  {l.includes("●") ? (
                    l.split(/(●●?)/).map((seg, j) =>
                      seg === "●" || seg === "●●" ? (
                        <span key={j} className="text-leaf-300">{seg}</span>
                      ) : (
                        <span key={j}>{seg}</span>
                      ),
                    )
                  ) : (
                    l
                  )}
                </motion.div>
              ))}
            </div>
          </div>
        </motion.div>
      </div>
    </section>
  );
}
