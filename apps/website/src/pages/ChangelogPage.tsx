import { Fragment, useEffect, useMemo, type ReactNode } from "react";
import { useTranslation } from "react-i18next";
import { motion } from "framer-motion";
import Nav from "@/components/Nav";
import Footer from "@/components/Footer";
import raw from "virtual:changelog-raw";
import { parseChangelog, type ChangeKind, type Release } from "@/lib/changelog";

/**
 * Changelog page. Renders the repo-root CHANGELOG.md (parsed at build time
 * from `virtual:changelog-raw`) as a Linear/Vercel-style timeline: a sticky
 * version+date rail on the left, kind-tagged change groups on the right.
 * Reuses the site's Nav + Footer and dark / accent-blue design system.
 */
export default function ChangelogPage() {
  const { t } = useTranslation();
  const releases = useMemo(() => parseChangelog(raw), []);
  const fmt = useDateFormatter();

  useEffect(() => {
    document.title = `${t("changelog.title")} — ${t("brand")}`;
  }, [t]);

  return (
    <div className="relative min-h-screen bg-bg text-ink">
      <Nav />
      <main>
        {/* Header */}
        <section className="relative overflow-hidden pt-32 pb-10 sm:pt-36">
          <div className="dotgrid pointer-events-none absolute inset-0 opacity-[0.18] [mask-image:radial-gradient(680px_340px_at_50%_0%,#000,transparent_70%)]" />
          <div className="relative mx-auto max-w-[760px] px-5 sm:px-8">
            <motion.h1
              initial={{ opacity: 0, y: 16 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.7, ease: [0.22, 1, 0.36, 1] }}
              className="font-mono text-display-2 font-bold tracking-tight text-ink"
            >
              {t("changelog.title")}
            </motion.h1>
            <motion.p
              initial={{ opacity: 0, y: 12 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.7, delay: 0.12, ease: [0.22, 1, 0.36, 1] }}
              className="mt-4 text-[17px] leading-relaxed text-ink-muted"
            >
              {t("changelog.subtitle")}
            </motion.p>
          </div>
        </section>

        {/* Timeline */}
        <section className="relative pb-28">
          <div className="mx-auto max-w-[760px] px-5 sm:px-8">
            {releases.map((release, i) => (
              <ReleaseBlock
                key={release.version}
                release={release}
                latest={i === 0}
                dateLabel={formatDate(fmt, release.date)}
                latestLabel={t("changelog.latest")}
              />
            ))}
          </div>
        </section>
      </main>
      <Footer />
    </div>
  );
}

// ─── release block ─────────────────────────────────────────────────────────

const KIND_STYLES: Record<ChangeKind, string> = {
  Added: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300",
  Changed: "border-acc-500/30 bg-acc-500/10 text-acc-200",
  Fixed: "border-amber-500/25 bg-amber-500/10 text-amber-300",
  Removed: "border-rose-500/25 bg-rose-500/10 text-rose-300",
  Deprecated: "border-zinc-500/25 bg-zinc-500/10 text-zinc-300",
  Security: "border-violet-500/25 bg-violet-500/10 text-violet-300",
};

function ReleaseBlock({
  release,
  latest,
  dateLabel,
  latestLabel,
}: {
  release: Release;
  latest: boolean;
  dateLabel: string;
  latestLabel: string;
}) {
  const { t } = useTranslation();
  const anchor = `v${release.version}`;

  return (
    <motion.article
      id={anchor}
      initial={{ opacity: 0, y: 16 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: "-80px" }}
      transition={{ duration: 0.5, ease: [0.22, 1, 0.36, 1] }}
      className="scroll-mt-24 border-t border-line/60 py-10 first:border-t-0 first:pt-2 md:grid md:grid-cols-[150px_1fr] md:gap-x-12"
    >
      {/* Left rail: version + date (sticky on desktop) */}
      <div className="md:sticky md:top-24 md:self-start">
        <div className="flex items-center gap-2">
          <a
            href={`#${anchor}`}
            className="font-mono text-[15px] font-semibold text-ink transition-colors hover:text-acc-300"
          >
            {release.version}
          </a>
          {latest && (
            <span className="rounded-full border border-acc-500/30 bg-acc-500/10 px-2 py-0.5 text-[10px] font-medium uppercase tracking-wide text-acc-200">
              {latestLabel}
            </span>
          )}
        </div>
        {dateLabel && <div className="mt-1 text-[13px] text-ink-dim">{dateLabel}</div>}
      </div>

      {/* Right column: change groups, with the timeline line + node */}
      <div className="relative mt-5 md:mt-0 md:border-l md:border-line/70 md:pl-12">
        <span className="absolute -left-[5px] top-1.5 hidden h-2.5 w-2.5 rounded-full bg-acc-500 ring-4 ring-bg md:block" />
        <div className="flex flex-col gap-7">
          {release.groups.map((group) => (
            <div key={group.kind}>
              <span
                className={`inline-flex items-center rounded-full border px-2.5 py-0.5 text-[11px] font-medium ${
                  KIND_STYLES[group.kind] ?? "border-line bg-bg-elev text-ink-muted"
                }`}
              >
                {t(`changelog.kinds.${group.kind}`, { defaultValue: group.kind })}
              </span>
              <ul className="mt-3 flex flex-col gap-2.5">
                {group.items.map((item, j) => (
                  <li
                    key={j}
                    className="relative pl-5 text-[14.5px] leading-relaxed text-ink-muted"
                  >
                    <span className="absolute left-0 top-[0.6em] h-1 w-1 rounded-full bg-ink-dim" />
                    {renderInline(item)}
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      </div>
    </motion.article>
  );
}

// ─── inline markdown (bold lead, inline code, links) ────────────────────────

// A fresh regex per call: renderInline recurses (a bold lead can wrap inline
// code), and a shared /g regex would have its lastIndex clobbered by the
// nested call mid-loop. Keys come from the Fragment wrap at the end.
function renderInline(text: string): ReactNode[] {
  const re = /\*\*([^*]+)\*\*|`([^`]+)`|\[([^\]]+)\]\(([^)]+)\)/g;
  const nodes: ReactNode[] = [];
  let last = 0;
  for (let m = re.exec(text); m; m = re.exec(text)) {
    if (m.index > last) nodes.push(text.slice(last, m.index));
    if (m[1] !== undefined) {
      // Bold lead — brighten against the muted body; may itself wrap code.
      nodes.push(
        <strong className="font-semibold text-ink">{renderInline(m[1])}</strong>,
      );
    } else if (m[2] !== undefined) {
      nodes.push(
        <code className="rounded bg-white/[0.06] px-1 py-0.5 font-mono text-[0.86em] text-ink">
          {m[2]}
        </code>,
      );
    } else if (m[3] !== undefined) {
      nodes.push(
        <a
          href={m[4]}
          target="_blank"
          rel="noreferrer"
          className="text-acc-300 underline-offset-2 hover:underline"
        >
          {m[3]}
        </a>,
      );
    }
    last = re.lastIndex;
  }
  if (last < text.length) nodes.push(text.slice(last));
  return nodes.map((n, i) => <Fragment key={i}>{n}</Fragment>);
}

// ─── date formatting ────────────────────────────────────────────────────────

function useDateFormatter(): Intl.DateTimeFormat {
  const { i18n } = useTranslation();
  return useMemo(() => {
    const locale = i18n.language?.startsWith("zh") ? "zh-CN" : "en-US";
    return new Intl.DateTimeFormat(locale, { year: "numeric", month: "long", day: "numeric" });
  }, [i18n.language]);
}

function formatDate(fmt: Intl.DateTimeFormat, iso: string | null): string {
  if (!iso) return "";
  const m = iso.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (!m) return iso;
  return fmt.format(new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
}
