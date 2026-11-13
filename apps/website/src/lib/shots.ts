import fs from "node:fs";
import path from "node:path";

// Product media lives in `public/shots/`, one file set per shot id:
//   <id>.png        still image (also the poster of a recording)
//   <id>-dark.png   optional variant for the dark appearance
//   <id>.mp4        optional screen recording, shown in place of the still
// The shot list and the capture rules are in the website README.

const SHOTS_DIR = path.resolve(process.cwd(), "public/shots");

export interface ShotMedia {
  image: { src: string; width: number; height: number } | null;
  darkImage: string | null;
  video: string | null;
}

export function resolveShot(id: string): ShotMedia {
  const has = (name: string) => fs.existsSync(path.join(SHOTS_DIR, name));
  const png = `${id}.png`;
  return {
    image: has(png) ? { src: `/shots/${png}`, ...pngSize(path.join(SHOTS_DIR, png)) } : null,
    darkImage: has(`${id}-dark.png`) ? `/shots/${id}-dark.png` : null,
    video: has(`${id}.mp4`) ? `/shots/${id}.mp4` : null,
  };
}

/** Width and height from the IHDR chunk, so `<img>` reserves its space. */
function pngSize(file: string): { width: number; height: number } {
  const header = Buffer.alloc(24);
  const fd = fs.openSync(file, "r");
  try {
    fs.readSync(fd, header, 0, 24, 0);
  } finally {
    fs.closeSync(fd);
  }
  if (header.toString("latin1", 12, 16) !== "IHDR") {
    throw new Error(`${file} is not a PNG file`);
  }
  return { width: header.readUInt32BE(16), height: header.readUInt32BE(20) };
}
