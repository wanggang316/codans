import { ReactNode } from "react";

interface Props {
  title?: string;
  subtitle?: string;
  children: ReactNode;
  className?: string;
}

export default function TerminalWindow({ title, subtitle, children, className = "" }: Props) {
  return (
    <div
      className={`relative overflow-hidden rounded-2xl border border-line bg-bg-elev shadow-window ${className}`}
    >
      <div className="flex h-9 items-center gap-3 border-b border-line/80 bg-bg-card/70 px-4">
        <div className="flex gap-1.5">
          <span className="h-3 w-3 rounded-full bg-[#ff5f57]" />
          <span className="h-3 w-3 rounded-full bg-[#febc2e]" />
          <span className="h-3 w-3 rounded-full bg-[#28c840]" />
        </div>
        {title && (
          <div className="flex min-w-0 flex-1 items-center justify-center gap-2 font-mono text-[12px] text-ink-muted">
            <span className="truncate">{title}</span>
            {subtitle && (
              <>
                <span className="text-ink-dim">·</span>
                <span className="truncate text-ink-dim">{subtitle}</span>
              </>
            )}
          </div>
        )}
        <div className="flex w-[58px] justify-end gap-1 text-ink-dim">
          <span className="h-1.5 w-1.5 rounded-full bg-ink-dim/60" />
          <span className="h-1.5 w-1.5 rounded-full bg-ink-dim/60" />
        </div>
      </div>
      {children}
    </div>
  );
}
