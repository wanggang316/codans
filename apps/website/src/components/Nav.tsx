import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { motion } from "framer-motion";
import Logo from "./Logo";
import { LINKS } from "@/lib/links";

export default function Nav() {
  const { t } = useTranslation();
  const [scrolled, setScrolled] = useState(false);
  const [open, setOpen] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 8);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  // Close the mobile menu on Escape, and whenever the viewport grows to the
  // desktop breakpoint (where the inline nav takes over and the panel hides).
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open]);

  useEffect(() => {
    const mq = window.matchMedia("(min-width: 640px)");
    const onChange = () => mq.matches && setOpen(false);
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, []);

  return (
    <motion.header
      initial={{ y: -20, opacity: 0 }}
      animate={{ y: 0, opacity: 1 }}
      transition={{ duration: 0.6, ease: [0.22, 1, 0.36, 1] }}
      className={`fixed top-0 z-50 w-full transition-all duration-300 ${
        scrolled || open
          ? "border-b border-line/70 bg-bg/70 backdrop-blur-xl"
          : "border-b border-transparent bg-transparent"
      }`}
    >
      <div className="mx-auto flex h-14 max-w-[1280px] items-center justify-between px-5 sm:px-8">
        <a href="/" className="flex items-center gap-2.5 text-sm font-medium tracking-tight">
          <Logo size={26} />
          <span className="font-mono text-[15px]">{t("brand")}</span>
        </a>
        <div className="flex items-center gap-1.5">
          {/* Inline links — desktop / tablet only. Collapsed into the menu
              below on phones, where the full row overflows the viewport. */}
          <nav className="hidden items-center gap-1 text-[13px] sm:flex">
            <NavLink href={LINKS.changelog} internal>
              {t("nav.changelog")}
            </NavLink>
            <NavLink href={LINKS.releases}>{t("nav.download")}</NavLink>
            <NavLink href={LINKS.repo}>{t("nav.github")}</NavLink>
          </nav>
          <LangToggle />
          <MenuToggle open={open} onClick={() => setOpen((v) => !v)} />
        </div>
      </div>

      {/* Mobile dropdown. Conditionally rendered (not height-animated) so it
          never depends on a JS animation tick to reveal navigation; the enter
          is a CSS keyframe that snaps instantly under reduced-motion. */}
      {open && (
        <nav
          id="mobile-menu"
          className="border-t border-line/60 animate-menu-in sm:hidden"
        >
          <div className="mx-auto flex max-w-[1280px] flex-col gap-0.5 px-3 py-2 text-[15px]">
            <MobileLink href={LINKS.changelog} internal onNavigate={() => setOpen(false)}>
              {t("nav.changelog")}
            </MobileLink>
            <MobileLink href={LINKS.releases} onNavigate={() => setOpen(false)}>
              {t("nav.download")}
            </MobileLink>
            <MobileLink href={LINKS.repo} onNavigate={() => setOpen(false)}>
              {t("nav.github")}
            </MobileLink>
          </div>
        </nav>
      )}
    </motion.header>
  );
}

/** Hamburger / close toggle — phones only; desktop uses the inline nav. */
function MenuToggle({ open, onClick }: { open: boolean; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={open ? "Close menu" : "Open menu"}
      aria-expanded={open}
      aria-controls="mobile-menu"
      className="ml-0.5 inline-flex h-9 w-9 items-center justify-center rounded-md text-ink/80 transition-colors hover:bg-ink/[0.06] hover:text-ink sm:hidden"
    >
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
        {open ? (
          <>
            <line x1="5" y1="5" x2="19" y2="19" />
            <line x1="19" y1="5" x2="5" y2="19" />
          </>
        ) : (
          <>
            <line x1="3.5" y1="7.5" x2="20.5" y2="7.5" />
            <line x1="3.5" y1="12" x2="20.5" y2="12" />
            <line x1="3.5" y1="16.5" x2="20.5" y2="16.5" />
          </>
        )}
      </svg>
    </button>
  );
}

/**
 * Single-button language switch. The label is the language it will switch
 * *to* (中文 while in English, EN while in Chinese) so it reads as an action.
 * Drives `i18n.changeLanguage`; the choice is persisted to localStorage by
 * the listener in i18n.ts. Default is English.
 */
function LangToggle() {
  const { i18n } = useTranslation();
  const next = i18n.language?.startsWith("zh") ? "en" : "zh";
  return (
    <button
      type="button"
      onClick={() => i18n.changeLanguage(next)}
      aria-label={next === "zh" ? "切换到中文" : "Switch to English"}
      className="ml-1.5 inline-flex items-center gap-1.5 rounded-full border border-line bg-bg-elev/60 px-2.5 py-1 text-[12px] text-ink-muted transition-colors hover:text-ink"
    >
      <GlobeGlyph />
      <span>{next === "zh" ? "中文" : "EN"}</span>
    </button>
  );
}

function GlobeGlyph() {
  return (
    <svg
      width="13"
      height="13"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      aria-hidden="true"
    >
      <circle cx="12" cy="12" r="9" />
      <path d="M3 12h18M12 3c2.6 2.7 2.6 15.3 0 18M12 3c-2.6 2.7-2.6 15.3 0 18" strokeLinecap="round" />
    </svg>
  );
}

function NavLink({
  href,
  children,
  internal,
}: {
  href: string;
  children: React.ReactNode;
  /** Same-site route — render a plain link, not a new-tab external one. */
  internal?: boolean;
}) {
  return (
    <a
      href={href}
      {...(internal ? {} : { target: "_blank", rel: "noreferrer" })}
      className="group relative rounded-md px-3 py-1.5 text-ink/80 transition-colors hover:text-ink"
    >
      <span className="relative z-10">{children}</span>
      <span className="absolute inset-0 -z-0 rounded-md bg-ink/0 transition-colors group-hover:bg-ink/[0.04]" />
    </a>
  );
}

/** Full-width tappable row used inside the mobile dropdown menu. */
function MobileLink({
  href,
  children,
  internal,
  onNavigate,
}: {
  href: string;
  children: React.ReactNode;
  internal?: boolean;
  onNavigate: () => void;
}) {
  return (
    <a
      href={href}
      {...(internal ? {} : { target: "_blank", rel: "noreferrer" })}
      onClick={onNavigate}
      className="rounded-md px-3 py-2.5 text-ink/85 transition-colors hover:bg-ink/[0.04] hover:text-ink"
    >
      {children}
    </a>
  );
}
