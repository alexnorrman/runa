// Builds dist/code.js (plugin main thread) and dist/ui.html (one self-contained file with the
// bundled UI script and CSS inlined, as Figma requires). `--watch` rebuilds on change.
import * as esbuild from "esbuild";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const watch = process.argv.includes("--watch");
const dist = join(root, "dist");

/** Inlines the UI bundle into src/ui/index.html and writes dist/ui.html. */
const inlineHtml = {
  name: "inline-html",
  setup(build) {
    build.onEnd(async (result) => {
      if (result.errors.length > 0) return;
      const files = result.outputFiles ?? [];
      const js = files.find((file) => file.path.endsWith(".js"))?.text ?? "";
      const css = files.find((file) => file.path.endsWith(".css"))?.text ?? "";
      const template = await readFile(join(root, "src/ui/index.html"), "utf8");
      // Function replacements: the bundle may contain `$&` and similar sequences.
      const html = template
        .replace("/*__RUNA_CSS__*/", () => css.replace(/<\/style/gi, "<\\/style"))
        .replace("/*__RUNA_JS__*/", () => js.replace(/<\/script/gi, "<\\/script"));
      await mkdir(dist, { recursive: true });
      await writeFile(join(dist, "ui.html"), html);
      console.log(`dist/ui.html ${(html.length / 1024).toFixed(1)} kB`);
    });
  },
};

const codeOptions = {
  absWorkingDir: root,
  entryPoints: ["src/code.ts"],
  bundle: true,
  outfile: "dist/code.js",
  format: "iife",
  // The Figma main-thread sandbox is conservative; lower modern syntax.
  target: "es2017",
  minify: !watch,
  logLevel: "info",
};

const uiOptions = {
  absWorkingDir: root,
  entryPoints: ["src/ui/main.ts"],
  bundle: true,
  outdir: "dist/ui-build",
  write: false,
  format: "iife",
  // The UI runs in Figma's Chromium iframe; BigInt needs ES2020.
  target: ["es2020", "chrome100"],
  minify: !watch,
  logLevel: "info",
  plugins: [inlineHtml],
};

await mkdir(dist, { recursive: true });
if (watch) {
  const contexts = await Promise.all([esbuild.context(codeOptions), esbuild.context(uiOptions)]);
  await Promise.all(contexts.map((context) => context.watch()));
  console.log("Watching for changes…");
} else {
  await Promise.all([esbuild.build(codeOptions), esbuild.build(uiOptions)]);
}
