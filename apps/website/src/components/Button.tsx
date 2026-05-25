import { ReactNode } from "react";
import { motion } from "framer-motion";

interface Props {
  href?: string;
  onClick?: () => void;
  children: ReactNode;
  variant?: "primary" | "secondary" | "ghost";
  size?: "md" | "lg";
  icon?: ReactNode;
}

export default function Button({
  href,
  onClick,
  children,
  variant = "primary",
  size = "md",
  icon,
}: Props) {
  const sz =
    size === "lg" ? "h-11 px-5 text-[14px]" : "h-9 px-4 text-[13px]";
  const v =
    variant === "primary"
      ? "bg-leaf-300 text-bg hover:bg-leaf-100 shadow-glow"
      : variant === "secondary"
        ? "border border-line bg-bg-elev text-ink hover:border-line-strong hover:bg-bg-card"
        : "text-ink-muted hover:text-ink";

  const Inner = (
    <motion.span
      whileHover={{ y: -1 }}
      whileTap={{ scale: 0.97 }}
      className={`group relative inline-flex items-center gap-2 rounded-full font-medium transition-colors ${sz} ${v}`}
    >
      {icon && <span className="opacity-90">{icon}</span>}
      <span>{children}</span>
    </motion.span>
  );

  if (href) {
    return (
      <a href={href} target="_blank" rel="noreferrer" className="inline-flex">
        {Inner}
      </a>
    );
  }
  return (
    <button onClick={onClick} className="inline-flex">
      {Inner}
    </button>
  );
}
