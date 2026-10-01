# 项目状态（docs/status.md）

> **新会话快速上手（给 AI 的引导，读完本文件即可开工，无需重读全部历史）**
> - 角色与协议：你是 MyLanFiles 的开发代理，遵守 `docs/MyLanFiles_开发交接文档.md` 的 §2.5（不确定性管理）与 §9（工作约定）；配套深度背景 `docs/MyLanFiles_可行性报告与开发计划.md` 按需查阅。
> - 一切以本文件「当前阶段 / 下次会话计划 / 待确认」三节为准；风险与雷区见 `docs/risks.md`；关键决策见 `docs/adr/0001`、`0002`。
> - 环境/镜像/构建命令：本文件末尾「环境速查」一节。全程不开代理。
> - 边界：不推 GitHub（决策人叫停，交接命令备好）；不开始 P2；B 级方向性决策被动摇时停下汇报。

> 每次会话结束更新。结构：当前阶段 / 已完成 / 下一步 / 待决策人确认事项。

- 更新：2026-09-30（P0 第 2 次会话——上接第 1 次会话的环境+spike）
- 本机项目根：`F:\MyLanFiles`
- 正式仓库：`F:\MyLanFiles\repo`（上游完整 clone；分支 `feat/p0-baseline` 4 个提交待推送）

## 当前阶段

**P0 — 环境 + 链路验证，接近完成**。剩余仅两件：GitHub 推送交接（等你一条命令）+ 真机互传/filebrowser 实测（需手机在场）。

## 第 2 次会话已完成

1. **三件大件全部落位**：
   - VS 2022 BuildTools 17.14.41（"使用 C++ 的桌面开发"，winget）→ flutter doctor 全绿
   - Rust 1.98.1 stable-msvc + 上游钉住的 1.97.1（rsproxy 镜像；crates.io 已配 rsproxy 源）
   - Windows 开发者模式已开启（UAC 通过）
2. **两条 Windows 构建链打通**：
   - spike03 BLE：`flutter build windows --debug` 51.7s 成功（win_ble 插件链验证）；本机有蓝牙适配器
   - **上游 LocalSend：`√ Built localsend_app.exe`（含 Rust cargokit 链 + 探针页），已启动运行确认不崩**（Spike 1 运行级通过；探针按钮在"发送"页底部）
3. **架构选项 A 拍板落地**：ADR-0002 定案；`packages/mylanfiles_core` 骨架 + **PathGuard 路径安全模块**（§7 生命线第一块）+ 17 个表驱动安全测试全绿（穿越/绝对路径注入/UNC/verbatim/大小写折叠/信息泄露）
4. **两个可上游化的构建修复**（已进 fork，`fix(windows)` 提交）：
   - 中文 Windows 代码页 936 → C4819 警告当错误 → CMake 加 `/utf-8`
   - 上游 gitignore 的 `localsend_msix_helper.msix` 被 CMake 无条件安装 → 新 clone 必失败 → 改条件安装
5. **正式仓库就绪**：`feat/p0-baseline` 分支 4 个提交（core 骨架 / 探针页 / 构建修复 / docs+CI），CI 门禁 yml 就位（windows+ubuntu 双 runner：format+analyze+test）。

## 踩雷记录（本次）

| 雷 | 处置 |
|----|------|
| rsproxy 的 `RUSTUP_UPDATE_ROOT` 路径 404（cargokit 自更新失败） | 正确值是 `https://rsproxy.cn/rustup`（**不带** `/dist`；官方文档写法有误），已写入环境约定 |
| C4819（CP936 × UTF-8 源码）构建失败 | CMake `add_compile_options(/utf-8)`（`CL` 环境变量对 MSBuild 链无效） |
| msix helper 缺失 → INSTALL 步骤失败 | 条件安装补丁 |
| gh 的 winget 安装挂死 | 直接下 GitHub release zip → `F:\bin\gh.exe` |

## 待决策人确认事项

### 1. GitHub 推送（决策人指示：本轮暂缓，命令保留备用）

在任意终端跑（gh 在 `F:\bin\gh.exe`）：

```
F:\bin\gh.exe auth login --hostname github.com
# 选 HTTPS → Login with a web browser → 浏览器输设备码
```

完成后告诉我，我接手剩下的全自动：fork localsend/localsend → 改名 mylanfiles → 设 origin → push `feat/p0-baseline` → 开 PR → main 分支保护（mylanfiles-ci 必须绿）。
（或你想直接粘贴 PAT 也行，用后我会提醒你撤销。）

### 2. 需要你在场的 P0 收尾（手机）

- Android 真机开 USB 调试插上 → 上游 App 双端互传一次（P0 验收）
- 电脑开热点 + 手机浏览器 → filebrowser 基准线体验（filebrowser 单二进制我随时可部署）

## 下次会话计划（P1 继续）

1. **TLS 真接**：浏览页改走 https（自签身份已在 server 包）+ 二维码配对（证书指纹入 QR，复用上游 qr 组件）
2. **打包流接进浏览页**：多选 → 中位文件 <2MB 走 /api/v1/pack → 客户端解包落盘（PackStreamReader 就绪）；skip 断点续传演示
3. **传输队列 + 进度 UI**；大文件 Range 断点联调
4. Android 侧：MANAGE 权限引导页 + MediaStore 快路径（等真机）
5. （GitHub 推送随时可恢复，交接命令见下）

## 环境速查（累积更新）

- Flutter `F:\flutter`（3.47.5）；pub 缓存 `F:\PubCache`；melos、gh(`F:\bin\gh.exe`)
- Android SDK `F:\SDK`；adb `F:\SDK\platform-tools\adb.exe`
- Rust：stable 1.98.1 + 1.97.1（上游钉版）；`~/.cargo/config.toml` 已配 rsproxy
- **构建 LocalSend 的环境变量**（bash）：`PATH+=~/.cargo/bin`，`RUSTUP_DIST_SERVER=https://rsproxy.cn`，`RUSTUP_UPDATE_ROOT=https://rsproxy.cn/rustup`，PUB/FLUTTER 镜像，`ANDROID_SDK_ROOT=F:\SDK`
- 项目：`F:\MyLanFiles`（docs/ + spikes/ + repo/）
- 上游代码两份：`spikes\spike01-localsend-page\upstream`（已构建✅，探针页）、`repo`（正式仓库，同补丁）
- 约束：全程无代理
