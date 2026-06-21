import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { motion } from "framer-motion";
import Logo from "./Logo";
import { LINKS } from "@/lib/links";

export default function Nav() {
  const { t } = useTranslation();
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 8);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <motion.header
      initial={{ y: -20, opacity: 0 }}
      animate={{ y: 0, opacity: 1 }}
      transition={{ duration: 0.6, ease: [0.22, 1, 0.36, 1] }}
      className={`fixed top-0 z-50 w-full transition-all duration-300 ${
        scrolled
          ? "border-b border-line/70 bg-bg/70 backdrop-blur-xl"
          : "border-b border-transparent bg-transparent"
      }`}
    >
      <div className="mx-auto flex h-14 max-w-[1280px] items-center justify-between px-5 sm:px-8">
        <a href="/" className="flex items-center gap-2.5 text-sm font-medium tracking-tight">
          <Logo size={26} />
          <span className="font-mono text-[15px]">{t("brand")}</span>
        </a>
        <nav className="flex items-center gap-1 text-[13px]">
          <NavLink href={LINKS.changelog} internal>
            {t("nav.changelog")}
          </NavLink>
          <NavLink href={LINKS.releases}>{t("nav.download")}</NavLink>
          <NavLink href={LINKS.repo} accent>
            {t("nav.github")}
          </NavLink>
          <LangToggle />
        </nav>
      </div>
    </motion.header>
  );
}

/**
 * EN / 中文 segmented toggle. Drives `i18n.changeLanguage`; the choice is
 * persisted to localStorage by the listener in i18n.ts. Default is English.
 */
function LangToggle() {
  const { i18n } = useTranslation();
  const current = i18n.language?.startsWith("zh") ? "zh" : "en";
  return (
    <div className="ml-1.5 flex items-center overflow-hidden rounded-full border border-line bg-bg-elev/60 text-[12px]">
      <LangButton active={current === "en"} onClick={() => i18n.changeLanguage("en")}>
        EN
      </LangButton>
      <span className="h-3.5 w-px bg-line" />
      <LangButton active={current === "zh"} onClick={() => i18n.changeLanguage("zh")}>
        中文
      </LangButton>
    </div>
  );
}

function LangButton({
  active,
  onClick,
  children,
}: {
  active: boolean;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      className={`px-2.5 py-1 transition-colors ${
        active ? "text-ink" : "text-ink-dim hover:text-ink-muted"
      }`}
    >
      {children}
    </button>
  );
}

function NavLink({
  href,
  children,
  accent,
  internal,
}: {
  href: string;
  children: React.ReactNode;
  accent?: boolean;
  /** Same-site route — render a plain link, not a new-tab external one. */
  internal?: boolean;
}) {
  return (
    <a
      href={href}
      {...(internal ? {} : { target: "_blank", rel: "noreferrer" })}
      className={`group relative rounded-md px-3 py-1.5 transition-colors ${
        accent
          ? "text-acc-300 hover:text-acc-200"
          : "text-ink/80 hover:text-ink"
      }`}
    >
      <span className="relative z-10">{children}</span>
      <span className="absolute inset-0 -z-0 rounded-md bg-ink/0 transition-colors group-hover:bg-ink/[0.04]" />
    </a>
  );
}
