import sizes from "../data/shots.json";

// Product media lives in `public/shots/`:
//   <id>.webp           still image at full size
//   <id>-<width>.webp   narrower copies of it, for `srcset`
// `src/data/shots.json` holds the pixel size of each still, so `<img>` reserves
// its space, and the widths of the copies. The shot list and the capture rules
// are in the website README.

interface ShotSize {
  width: number;
  height: number;
  variants?: number[];
}

export interface ShotMedia {
  src: string;
  /** Candidates for `srcset`, or null when the still has no narrower copy. */
  srcset: string | null;
  width: number;
  height: number;
}

export function resolveShot(id: string): ShotMedia {
  const size = (sizes as Record<string, ShotSize>)[id];
  if (!size) throw new Error(`unknown shot "${id}": add it to src/data/shots.json`);
  const src = `/shots/${id}.webp`;
  const copies = (size.variants ?? []).map((width) => `/shots/${id}-${width}.webp ${width}w`);
  return {
    src,
    srcset: copies.length ? [...copies, `${src} ${size.width}w`].join(", ") : null,
    width: size.width,
    height: size.height,
  };
}
