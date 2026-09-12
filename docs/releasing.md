# 发版流程

发版只做一次准备（配 npm token），之后每次发版都是「升版本 → 建 Release → 自动上 npm」。

## 一次性准备（维护者）

1. 注册 [npm](https://www.npmjs.com/signup) 账号（建议顺手开启 2FA）；
2. 生成 **Automation** 类型的 Access Token（Automation 类型不会被 CI 里的 2FA 卡住）；
3. 在本仓库 `Settings → Secrets and variables → Actions` 添加 secret：**`NPM_TOKEN`** = 上一步的 token。

配好之后，`.github/workflows/publish.yml` 就会在每次发布 Release 时自动把包发到 npm。

## 每次发版

```bash
# 1) 升版本（npm 上版本号不可复用，必须升）
#    改 package.json 与 package-lock.json 的 version，并把 CHANGELOG 顶部改成同一版本号
# 2) 走 PR 合进 main（CI 会跑测试 + AI 评审）
# 3) 在 GitHub UI 建 Release：tag 形如 v0.2.0（必须与 package.json 的版本一致，workflow 会校验）
```

Release 一发布，`Publish to npm` 就会：

1. 校验 **tag 与 `package.json` 版本一致**（不一致直接失败，避免把错误版本号发上去）；
2. 检查 npm 上该版本是否已存在（存在就跳过，流水线不会红）；
3. `npm publish --provenance --access public`。

## 为什么要有这些约束

- **版本号不可复用**：npm 上同一个版本号永久占用，发布后不能覆盖、不能重发；
- **provenance**：`--provenance` 让 npm 上的包带上签名证明 —— 这个版本来自本仓库的某个 commit、由某个 workflow 构建，朋友可以自己核验；
- **tag / CHANGELOG / npm 三者一致**：否则用户看到的版本、看到的说明、装到的包会对不上。

## 发布后要做的

1. 确认 npm 页面可见：`npm view dsh-notify-macos version`；
2. 更新 README 里的首选安装方式（若刚从 `github:` 切到 npm）：
   ```bash
   dsh plugin --profile web add dsh-notify-macos
   ```
3. GitHub Release 说明里同样把 npm 方式写在最前。

## 备选安装方式（不发 npm 也能用）

| 方式 | 命令 | 代价 |
| --- | --- | --- |
| GitHub 依赖 | `dsh plugin --profile web add github:Tania-X/dsh-notify-macos` | 首次约 3 分钟（git） |
| Release 附件 | 下载 `dsh-notify-macos-<版本>.tgz` 后 `add <路径>` | 秒级，但 profile 里记的是**绝对路径**：把 tgz 挪走后，profile 里任何 `pnpm install` 都会 `ENOENT` 报错（插件本身仍可用） |
