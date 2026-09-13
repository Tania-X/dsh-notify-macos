#!/usr/bin/env node
/**
 * 契约自检：DSH 升级之后，5 秒内告诉我们「本插件依赖的契约有没有变」。
 *
 * 只读本机真实安装（`$DSH_HOME`，默认 `~/.dsh`）的文件，不启动任何进程、不联网。
 * 检查项来自本插件实际用到的东西 —— 事件名直接从 `lib/index.js` 里抽，避免脚本与代码漂移。
 *
 * 用法:
 *   node test/manual/contract-check.mjs            # 检查默认安装
 *   DSH_HOME=/tmp/try-home node test/manual/contract-check.mjs   # 检查隔离 home（升级前置验证）
 *
 * 退出码：0 = 契约未变（或有降级但可用）；1 = 核心契约缺失（功能必坏）。
 */
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

const DSH_HOME = process.env.DSH_HOME ?? path.join(os.homedir(), ".dsh");
const NM = path.join(DSH_HOME, "node_modules", "@deepseek-ai");
const PLUGIN_DIR = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));

const results = [];
/** @param level - "ok" | "warn" | "fail" */
const record = (level, area, detail) => results.push({ level, area, detail });

const read = (file) => {
  try {
    return fs.readFileSync(file, "utf8");
  } catch {
    return undefined;
  }
};
const readJSON = (file) => {
  const text = read(file);
  if (text === undefined) return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
};
const versionOf = (pkg) => readJSON(path.join(NM, pkg, "package.json"))?.version;

// --- 1) 版本坐标 -----------------------------------------------------------
const pluginManifest = readJSON(path.join(PLUGIN_DIR, "package.json")) ?? {};
record(
  "ok",
  "版本",
  `插件 ${pluginManifest.version}；dsh ${versionOf("dsh") ?? "?"}；dsh-agent ${
    versionOf("dsh-agent") ?? "?"
  }；cordis ${versionOf("cordis") ?? "?"}`
);
record("ok", "插件 peer", JSON.stringify(pluginManifest.peerDependencies ?? {}));

// --- 2) 事件名：从我们的代码里抽，对着官方词表核 -----------------------------
const hostSource = read(path.join(PLUGIN_DIR, "lib", "index.js")) ?? "";
// 两种写法都要抓，否则将来只在 `switch (event.type) { case "…" }` 里新增的事件会被漏掉：
//   1) 纯函数里的 `event.type === "…"`；
//   2) 事件分支里的 `case "…":`（用 `/` 过滤掉同一文件里其它 switch 的标签，例如动作名 "jump-web"）。
const usedEvents = [
  ...new Set([
    ...[...hostSource.matchAll(/event\.type === "([^"]+)"/g)].map((m) => m[1]),
    ...[...hostSource.matchAll(/case "([^"]+)":/g)].map((m) => m[1]).filter((name) => name.includes("/"))
  ])
];
const knownText = read(path.join(NM, "dsh-session", "lib", "types", "known-event-types.js"));
if (usedEvents.length === 0) {
  // 自保：抽取正则一旦与代码写法失配，这项检查会静默变成"永远通过" —— 那比没有检查更糟。
  record(
    "fail",
    "事件词表",
    "从 lib/index.js 抽到 0 个事件名（正则失配）—— 检查本身失效，请修 test/manual/contract-check.mjs"
  );
} else if (!knownText) {
  record("warn", "事件词表", "找不到 dsh-session 的 known-event-types.js，无法核对（该包结构可能变了）");
} else {
  const known = new Set([...knownText.matchAll(/^\s*'([^']+)',/gm)].map((m) => m[1]));
  const missing = usedEvents.filter((name) => !known.has(name));
  record(
    missing.length === 0 ? "ok" : "fail",
    "事件词表",
    missing.length === 0
      ? `我们监听的 ${usedEvents.length} 个事件名都在官方词表里：${usedEvents.join(", ")}`
      : `官方词表里已找不到这些事件名：${missing.join(", ")}（对应卡片会静默不再出现）`
  );
}

// --- 3) Cordis 事件与我们硬编码的语义名 -------------------------------------
const treeFiles = (() => {
  const out = [];
  const walk = (dir, depth = 0) => {
    if (depth > 4) return;
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) walk(full, depth + 1);
      else if (e.name.endsWith(".js")) out.push(full);
    }
  };
  walk(NM);
  return out;
})();
const treeHas = (needle) => {
  for (const file of treeFiles) {
    const text = read(file);
    if (text !== undefined && text.includes(needle)) return true;
  }
  return false;
};
for (const [label, needle, why] of [
  ["agent/status（完成卡）", '"agent/status"', "完成类卡片不会出现"],
  ["ask_user_question（提问类琥珀卡）", "ask_user_question", "提问类琥珀卡不会出现"]
]) {
  record(
    treeHas(needle) ? "ok" : "warn",
    label,
    treeHas(needle) ? "在安装里找到" : `安装里找不到（${why}；若是重命名，改 lib/index.js 对应字符串即可）`
  );
}

// --- 4) 前端锚点（位置跳转依赖）--------------------------------------------
const convClient = path.join(NM, "dsh-client-ui-conversation", "lib", "client.js");
const convText = read(convClient);
if (convText === undefined) {
  record("warn", "前端锚点", "找不到 dsh-client-ui-conversation/lib/client.js（包结构可能变了）");
} else {
  const anchors = [
    ["data-chat-anchor-key", "行锚点属性"],
    ["turn-tail", "turn 尾行 key"],
    ["loadOlder", "「加载更早」按钮"]
  ].filter(([needle]) => !convText.includes(needle));
  record(
    anchors.length === 0 ? "ok" : "warn",
    "前端锚点",
    anchors.length === 0
      ? "行锚点 / turn-tail / loadOlder 都在"
      : `缺失：${anchors.map(([n, w]) => `${n}（${w}）`).join("、")} —— 位置跳转会降级为「钉最新」，不会崩`
  );
}

// --- 5) client 半区依赖的服务 ----------------------------------------------
const runtimeText = read(path.join(NM, "dsh-client-runtime", "lib", "client.js")) ?? "";
record(
  runtimeText.includes("sessions") ? "ok" : "warn",
  "前端服务 sessions",
  runtimeText.includes("sessions")
    ? "在 dsh-client-runtime 里出现（启发式检查）"
    : "未出现（启发式检查）——跳转可能失效，卡片本身不受影响"
);

// --- 6) profile 接线 -------------------------------------------------------
const profilesDir = path.join(DSH_HOME, "profiles");
let checkedProfiles = 0;
for (const name of (() => {
  try {
    return fs.readdirSync(profilesDir);
  } catch {
    return [];
  }
})()) {
  const manifest = readJSON(path.join(profilesDir, name, "package.json"));
  if (!manifest) continue;
  checkedProfiles += 1;
  const dep = manifest.dependencies?.["dsh-notify-macos"];
  const inBundles = (manifest.dsh?.profile?.bundles ?? []).includes("dsh-notify-macos");
  if (dep === undefined) continue;
  record(
    inBundles ? "ok" : "fail",
    `profile ${name}`,
    inBundles
      ? `已接入（依赖 ${dep}，并在 dsh.profile.bundles 里）`
      : `依赖是 ${dep}，但不在 dsh.profile.bundles 里 —— 插件不会被激活（包装完缺 dsh.bundle？）`
  );
}
if (checkedProfiles === 0) record("warn", "profile", `在 ${profilesDir} 下没找到任何 profile`);

// --- 输出 -----------------------------------------------------------------
const icon = { ok: "✅", warn: "⚠️ ", fail: "❌" };
console.log(`契约自检 · DSH_HOME=${DSH_HOME}\n`);
for (const { level, area, detail } of results) {
  console.log(`${icon[level]} ${area.padEnd(22)} ${detail}`);
}
const failed = results.filter((r) => r.level === "fail").length;
const warned = results.filter((r) => r.level === "warn").length;
console.log(
  `\n结论：${failed > 0 ? `❌ 核心契约缺失（${failed} 项）—— 需要适配后才能用` : warned > 0 ? `⚠️  契约有变化（${warned} 项），功能会降级但不会崩` : "✅ 契约未变，插件可用"}`
);
process.exit(failed > 0 ? 1 : 0);
