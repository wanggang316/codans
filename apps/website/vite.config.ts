import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import fs from "node:fs";
import path from "node:path";

/**
 * The repo-root CHANGELOG.md is the single source of truth for releases.
 * This plugin:
 *   1. exposes its raw markdown to the bundle as `virtual:changelog-raw`, and
 *   2. rewrites the clean `/changelog` URL to its built HTML entry in dev
 *      (GitHub Pages resolves extensionless URLs to `.html` for us in prod).
 */
function changelog(): Plugin {
  const virtualId = "virtual:changelog-raw";
  const resolvedId = "\0" + virtualId;
  const file = path.resolve(__dirname, "../../CHANGELOG.md");
  return {
    name: "codans-changelog",
    resolveId(id) {
      if (id === virtualId) return resolvedId;
    },
    load(id) {
      if (id === resolvedId) {
        this.addWatchFile(file);
        return `export default ${JSON.stringify(fs.readFileSync(file, "utf8"))};`;
      }
    },
    configureServer(server) {
      server.middlewares.use((req, _res, next) => {
        const url = req.url?.split("?")[0];
        if (url === "/changelog" || url === "/changelog/") req.url = "/changelog.html";
        next();
      });
    },
  };
}

export default defineConfig({
  plugins: [react(), changelog()],
  resolve: {
    alias: { "@": path.resolve(__dirname, "src") },
  },
  server: { port: 5173, host: true },
  build: {
    target: "es2022",
    sourcemap: false,
    rollupOptions: {
      input: {
        main: path.resolve(__dirname, "index.html"),
        changelog: path.resolve(__dirname, "changelog.html"),
      },
    },
  },
});
