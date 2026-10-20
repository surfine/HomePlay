#!/usr/bin/env node
// 把已提交的 main 壓成公開快照，過洩漏閘門，必要時推到公開倉庫。
//
//   node tooling/public-snapshot.mjs                 # 建快照 + 閘門 + 跟公開倉庫比對（dry-run，什麼都不推）
//   node tooling/public-snapshot.mjs --ref <commit>  # 從指定提交建（預設 main）
//   node tooling/public-snapshot.mjs --push          # 以上全過之後，追加一個提交到公開倉庫 main
//
// 只讀 git 裡已提交的內容（git archive），工作區沒提交的改動永遠不會進快照。
// 推送只發生在一次性的暫存 clone 裡，不碰這個倉庫的分支和 remote；不用 --force。

import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, mkdirSync, readFileSync, writeFileSync, readdirSync, statSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import * as M from "./public-manifest.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const ref = args.includes("--ref") ? args[args.indexOf("--ref") + 1] : "main";
const push = args.includes("--push");
const out = path.join(root, ".build", "public-snapshot");

const git = (a, opts = {}) => execFileSync("git", a, { cwd: root, encoding: "utf8", maxBuffer: 1 << 28, ...opts }).trim();
const under = (p, prefix) => (prefix.endsWith("/") ? p.startsWith(prefix) : p === prefix);
const fail = (msg) => { console.error(`✗ ${msg}`); process.exit(1); };

// 1. 歸類：每個被追蹤的檔案都要明確 include 或 exclude
const sha = git(["rev-parse", "--short", ref]);
const tracked = git(["ls-tree", "-r", "--name-only", "-z", ref]).split("\0").filter(Boolean);
const excluded = (p) => M.excludePaths.some((e) => under(p, e.path));
const included = (p) => M.includePaths.some((i) => under(p, i));
const unclassified = tracked.filter((p) => !excluded(p) && !included(p));
if (unclassified.length) {
  fail(`這些檔案沒被 tooling/public-manifest.mjs 歸類（加進 includePaths 或 excludePaths 並寫原因）：\n  ${unclassified.join("\n  ")}`);
}
const ship = tracked.filter((p) => included(p) && !excluded(p));

// 2. 建快照：git archive 只取要的路徑，再放覆蓋檔
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
const tar = execFileSync("git", ["archive", "--format=tar", ref, "--", ...ship], { cwd: root, maxBuffer: 1 << 30 });
execFileSync("tar", ["-x", "-C", out], { input: tar });
for (const [dst, src] of Object.entries(M.overlays)) {
  if (!tracked.includes(src)) fail(`覆蓋檔 ${src} 還沒提交`);
  mkdirSync(path.dirname(path.join(out, dst)), { recursive: true });
  writeFileSync(path.join(out, dst), git(["show", `${ref}:${src}`]) + "\n");
}

// 3. 洩漏閘門
const files = [];
const walk = (d) => { for (const n of readdirSync(d)) { const p = path.join(d, n); statSync(p).isDirectory() ? walk(p) : files.push(path.relative(out, p)); } };
walk(out);
const findings = [];
for (const f of files) {
  if (M.forbiddenPathPatterns.some((re) => re.test(f))) findings.push(`${f}：禁止公開的路徑`);
  const size = statSync(path.join(out, f)).size;
  if (size > M.maxFileBytes) findings.push(`${f}：${(size / 1048576).toFixed(1)} MB 超過單檔上限`);
  const buf = readFileSync(path.join(out, f));
  if (buf.subarray(0, 8000).includes(0)) continue; // 二進位檔不掃內容
  const text = buf.toString("utf8");
  for (const { name, re } of M.forbiddenContentPatterns) {
    const m = text.match(re);
    if (m) {
      const line = text.slice(0, m.index).split("\n").length;
      findings.push(`${f}:${line}：${name}（${m[0].slice(0, 4)}…已遮蔽）`);
    }
  }
}
if (findings.length) fail(`洩漏閘門擋下 ${findings.length} 處：\n  ${findings.join("\n  ")}`);
console.log(`✓ 快照 ${sha}：${files.length} 個檔案，閘門通過 → ${path.relative(root, out)}`);

// 4. 跟公開倉庫比對；--push 才提交與推送
const work = mkdtempSync(path.join(tmpdir(), "homeplay-public-"));
try {
  let empty = false;
  try {
    execFileSync("git", ["clone", "--quiet", "--branch", M.publicBranch, "--single-branch", M.publicRepo, work], { stdio: "pipe" });
  } catch (e) {
    const msg = String(e.stderr || e.message);
    if (/not found in upstream|Remote branch .* not found|empty repository/i.test(msg)) {
      execFileSync("git", ["clone", "--quiet", M.publicRepo, work], { stdio: "pipe" });
      empty = true;
    } else if (/Repository not found|could not read/i.test(msg)) {
      console.log(`· 公開倉庫 ${M.publicRepo} 還不存在；dry-run 到此為止。`);
      if (push) fail("要先建立公開倉庫才能 --push（見 docs/publishing.md）");
      process.exit(0);
    } else throw e;
  }
  const g = (a) => execFileSync("git", a, { cwd: work, encoding: "utf8" }).trim();
  for (const n of readdirSync(work)) if (n !== ".git") rmSync(path.join(work, n), { recursive: true, force: true });
  for (const f of files) { mkdirSync(path.dirname(path.join(work, f)), { recursive: true }); copyFileSync(path.join(out, f), path.join(work, f)); }
  g(["add", "-A"]);
  const stat = g(["diff", "--cached", "--stat"]);
  if (!stat) { console.log("· 跟公開倉庫一樣，沒有要同步的東西。"); process.exit(0); }
  console.log(`· 跟公開倉庫${empty ? "（空倉庫，首次提交）" : ""}相比：\n${stat.split("\n").slice(-25).join("\n")}`);
  if (!push) { console.log("· dry-run：沒有提交也沒有推送。確認無誤後加 --push。"); process.exit(0); }
  const [name, email] = M.commitAuthor.match(/^(.*) <(.*)>$/).slice(1);
  execFileSync("git", ["-c", `user.name=${name}`, "-c", `user.email=${email}`, "commit", "--quiet", "-m", `Sync public snapshot (${sha})`], { cwd: work });
  execFileSync("git", ["push", "origin", `HEAD:${M.publicBranch}`], { cwd: work, stdio: "inherit" });
  console.log(`✓ 已推到 ${M.publicRepo} ${M.publicBranch}`);
} finally {
  rmSync(work, { recursive: true, force: true });
}
