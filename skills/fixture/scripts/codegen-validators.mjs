import { execFileSync } from "node:child_process";
import { mkdir, readdir, writeFile } from "node:fs/promises";
import path from "node:path";

const ROOT = path.resolve(import.meta.dirname, "..");
const SCHEMA_DIR = path.join(ROOT, "schemas");
const OUT_DIR = path.join(ROOT, "generated");
const JTD_CODEGEN = process.env.JTD_CODEGEN ?? "jtd-codegen";

function exportName(stem) {
  return "validate" + stem.replace(/(^|-)([a-z])/g, (_, __, c) => c.toUpperCase());
}

const schemas = (await readdir(SCHEMA_DIR)).filter((f) => f.endsWith(".jtd.json"));
await mkdir(OUT_DIR, { recursive: true });

const barrelLines = [];
for (const file of schemas.sort()) {
  const stem = file.replace(/\.jtd\.json$/, "");
  const schemaPath = path.join(SCHEMA_DIR, file);
  const outPath = path.join(OUT_DIR, `${stem}.mjs`);
  const code = execFileSync(JTD_CODEGEN, ["--target", "js", schemaPath], {
    encoding: "utf8",
  });
  await writeFile(outPath, code);
  barrelLines.push(`export { validate as ${exportName(stem)} } from "./${stem}.mjs";`);
  console.log(`generated ${path.relative(ROOT, outPath)}`);
}

await writeFile(path.join(OUT_DIR, "validators.mjs"), barrelLines.join("\n") + "\n");
console.log("generated validators.mjs barrel");
