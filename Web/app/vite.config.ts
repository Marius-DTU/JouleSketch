import { defineConfig } from "vite";

// The Swift part is built into ./core by ../build.sh.
export default defineConfig({
  // Relative paths, so the site works from any folder (e.g. GitHub Pages).
  base: "./",
  build: {
    target: "es2022",
    outDir: "dist",
  },
});
