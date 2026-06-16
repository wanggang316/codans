import { useTranslation } from "react-i18next";
import { LINKS } from "@/lib/links";

export default function Footer() {
  const { t } = useTranslation();
  return (
    <footer className="relative border-t border-line bg-bg">
      <div className="mx-auto flex max-w-[1280px] flex-col items-start gap-8 px-5 py-12 sm:flex-row sm:items-center sm:justify-between sm:px-8">
        <div className="text-xs text-ink-muted">
          © 2026{" "}
          <a
            className="hover:text-ink"
            href="https://github.com/wanggang316"
            target="_blank"
            rel="noreferrer"
          >
            Gump
          </a>
        </div>
        <ul className="flex flex-wrap items-center gap-x-6 gap-y-2 text-xs text-ink-muted">
          <li>
            <a className="hover:text-ink" href={LINKS.releases} target="_blank" rel="noreferrer">
              {t("footer.releases")}
            </a>
          </li>
          <li>
            <a className="hover:text-ink" href={LINKS.issues} target="_blank" rel="noreferrer">
              {t("footer.issues")}
            </a>
          </li>
          <li>
            <a className="hover:text-ink" href={LINKS.repo} target="_blank" rel="noreferrer">
              {t("footer.repo")}
            </a>
          </li>
        </ul>
      </div>
    </footer>
  );
}
