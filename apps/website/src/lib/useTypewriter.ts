import { useEffect, useRef, useState } from "react";

interface Options {
  speed?: number;
  startDelay?: number;
  loop?: boolean;
  pauseEnd?: number;
}

export function useTypewriter(lines: string[], opts: Options = {}): string[] {
  const { speed = 28, startDelay = 0, loop = true, pauseEnd = 2400 } = opts;
  const [rendered, setRendered] = useState<string[]>([]);
  const timer = useRef<number | null>(null);

  useEffect(() => {
    let cancelled = false;
    let lineIdx = 0;
    let charIdx = 0;
    const acc: string[] = [];

    const step = () => {
      if (cancelled) return;
      if (lineIdx >= lines.length) {
        if (!loop) return;
        timer.current = window.setTimeout(() => {
          if (cancelled) return;
          acc.length = 0;
          lineIdx = 0;
          charIdx = 0;
          setRendered([]);
          step();
        }, pauseEnd);
        return;
      }
      const line = lines[lineIdx];
      if (charIdx === 0) acc.push("");
      acc[acc.length - 1] = line.slice(0, charIdx + 1);
      setRendered([...acc]);
      charIdx += 1;
      if (charIdx >= line.length) {
        lineIdx += 1;
        charIdx = 0;
        timer.current = window.setTimeout(step, 380);
      } else {
        timer.current = window.setTimeout(step, speed + Math.random() * 32);
      }
    };

    timer.current = window.setTimeout(step, startDelay);
    return () => {
      cancelled = true;
      if (timer.current) window.clearTimeout(timer.current);
    };
  }, [lines, speed, startDelay, loop, pauseEnd]);

  return rendered;
}
