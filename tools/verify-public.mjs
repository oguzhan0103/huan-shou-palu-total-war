import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import luaparse from "luaparse";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function walk(directory, predicate) {
  if (!fs.existsSync(directory)) return [];
  const files = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) files.push(...walk(absolute, predicate));
    else if (predicate(absolute)) files.push(absolute);
  }
  return files.sort();
}

const luaRoots = [
  path.join(root, "PalFactionTerritory", "mod0", "ue4ss"),
  path.join(root, "PalMultiOtomo", "mod0", "ue4ss"),
];
const luaFiles = luaRoots.flatMap((directory) =>
  walk(directory, (file) => file.toLowerCase().endsWith(".lua")),
);
if (luaFiles.length === 0) throw new Error("No public Lua sources found");

for (const file of luaFiles) {
  const source = fs.readFileSync(file, "utf8");
  try {
    luaparse.parse(source, { luaVersion: "5.3" });
  } catch (error) {
    throw new Error(`Lua syntax check failed: ${path.relative(root, file)}\n${error}`);
  }
}

const suites = [
  {
    project: path.join(root, "PalFactionTerritory"),
    tests: walk(
      path.join(root, "PalFactionTerritory", "mod0", "tests"),
      (file) => file.endsWith(".lua"),
    ),
  },
  {
    project: path.join(root, "PalMultiOtomo"),
    tests: [path.join(root, "PalMultiOtomo", "mod0", "tests", "runtime_smoke.lua")],
  },
];

const executable = path.join(
  root,
  "node_modules",
  ".bin",
  process.platform === "win32" ? "fengari.cmd" : "fengari",
);
if (!fs.existsSync(executable)) {
  throw new Error("Missing local Fengari executable; run npm install first");
}

let testCount = 0;
for (const suite of suites) {
  for (const test of suite.tests) {
    if (!fs.existsSync(test)) throw new Error(`Missing test: ${test}`);
    const relativeTest = path.relative(suite.project, test).replaceAll(path.sep, "/");
    const execution = spawnSync(executable, [relativeTest], {
      cwd: suite.project,
      encoding: "utf8",
      shell: process.platform === "win32",
      timeout: 60_000,
    });
    process.stdout.write(execution.stdout ?? "");
    process.stderr.write(execution.stderr ?? "");
    if (execution.error) throw execution.error;
    if (execution.status !== 0 || /assertion failed|stack traceback:/im.test(`${execution.stdout}\n${execution.stderr}`)) {
      throw new Error(`Lua test failed: ${path.relative(root, test)}`);
    }
    testCount += 1;
  }
}

const forbiddenExtensions = new Set([
  ".pak", ".uasset", ".uexp", ".ubulk", ".usmap", ".sav", ".dmp", ".pdb", ".exe", ".dll",
]);
const trackedCandidates = ["PalFactionTerritory", "PalMultiOtomo", "PalAgentDialogue"]
  .flatMap((directory) => walk(path.join(root, directory), () => true));
for (const file of trackedCandidates) {
  if (forbiddenExtensions.has(path.extname(file).toLowerCase())) {
    const relative = path.relative(root, file);
    if (!relative.includes(`${path.sep}build${path.sep}`)
      && !relative.includes(`${path.sep}artifacts${path.sep}`)
      && !relative.includes(`${path.sep}evidence${path.sep}`)
      && !relative.includes(`${path.sep}generated${path.sep}`)
      && !relative.includes(`${path.sep}outputs${path.sep}`)
      && !relative.includes(`${path.sep}release${path.sep}`)
      && !relative.includes(`${path.sep}tools${path.sep}vendor${path.sep}`)
      && !relative.includes(`${path.sep}target${path.sep}`)) {
      throw new Error(`Forbidden public artifact outside ignored areas: ${relative}`);
    }
  }
}

const tracked = spawnSync("git", ["ls-files", "-z"], {
  cwd: root,
  encoding: "utf8",
});
if (tracked.error) throw tracked.error;
if (tracked.status !== 0) {
  throw new Error(`git ls-files failed: ${tracked.stderr ?? "unknown error"}`);
}

const forbiddenTrackedText = [
  { label: "Steam account ID", pattern: /\b7656119\d{10}\b/ },
  { label: "local Windows user profile path", pattern: /[A-Za-z]:\\Users\\[^<\\\r\n]+\\/i },
  { label: "GitHub access token", pattern: /\bgh[pousr]_[A-Za-z0-9_]{20,}\b/ },
  { label: "OpenAI-style secret key", pattern: /\bsk-[A-Za-z0-9_-]{20,}\b/ },
  { label: "private key", pattern: /-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----/ },
];

let safetyFileCount = 0;
for (const relative of tracked.stdout.split("\0").filter(Boolean)) {
  const file = path.join(root, relative);
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) continue;
  const payload = fs.readFileSync(file);
  if (payload.includes(0)) continue;
  const text = payload.toString("utf8");
  for (const rule of forbiddenTrackedText) {
    if (rule.pattern.test(text)) {
      throw new Error(`Tracked public source contains ${rule.label}: ${relative}`);
    }
  }
  safetyFileCount += 1;
}

console.log(
  `PASS public source verification: ${luaFiles.length} Lua files, ${testCount} Lua tests, ${safetyFileCount} tracked text files scanned`,
);
