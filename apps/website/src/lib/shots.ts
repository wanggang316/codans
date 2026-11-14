import sizes from "../data/shots.json";

// Product media lives in `public/shots/`:
//   <id>.webp   still image (also the poster of a recording)
//   <id>.mp4    optional screen recording, shown in place of the still
// `src/data/shots.json` holds the pixel size of each still, so `<img>` reserves
// its space, and marks the ids that have a recording. The shot list and the
// capture rules are in the website README.

interface ShotSize {
  width: number;
  height: number;
  video?: boolean;
}

export interface ShotMedia {
  src: string;
  width: number;
  height: number;
  video: string | null;
}

export function resolveShot(id: string): ShotMedia {
  const size = (sizes as Record<string, ShotSize>)[id];
  if (!size) throw new Error(`unknown shot "${id}": add it to src/data/shots.json`);
  return {
    src: `/shots/${id}.webp`,
    width: size.width,
    height: size.height,
    video: size.video ? `/shots/${id}.mp4` : null,
  };
}
