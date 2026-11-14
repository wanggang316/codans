import { defineConfig } from "astro/config";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  site: "https://codans.dev",
  // Emit `changelog.html`, not `changelog/index.html`: GitHub Pages then
  // serves the clean `/changelog` URL without a redirect to a trailing slash.
  build: { format: "file" },
  vite: {
    plugins: [tailwindcss()],
    // The changelog page imports the repository-root CHANGELOG.md.
    server: { fs: { allow: ["../.."] } },
  },
});
