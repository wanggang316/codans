import { useTranslation } from "react-i18next";
import Logo from "./Logo";
import { LINKS } from "@/lib/links";

export default function Footer() {
  const { t } = useTranslation();
  return (
    <footer className="relative border-t border-line bg-bg">
      <div className="mx-auto flex max-w-[1280px] flex-col items-start gap-8 px-5 py-12 sm:flex-row sm:items-center sm:justify-between sm:px-8">
        <div className="flex items-center gap-3">
          <Logo size={28} />
          <div>
            <div className="font-mono text-sm text-ink">{t("brand")}</div>
            <div className="text-xs text-ink-muted">{t("footer.tagline")}</div>
          </div>
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
          <li className="font-mono text-ink-dim">{t("footer.license")}</li>
          <li className="font-mono text-ink-dim">{t("footer.version")}</li>
        </ul>
      </div>
    </footer>
  );
}
