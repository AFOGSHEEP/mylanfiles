# Spike 1 NOTES — fork LocalSend 加最小新页面 PoC（雷区 1）

日期：2026-09-30 · 结果：⚠️ 部分（代码级验证 ✅；运行级验证被环境阻塞，见文末）

## 结论速览

1. **"加个页面"的 UI 耦合担忧不成立**——改动面极小（雷区 1 对新增页面的担忧解除）。
2. **真正的雷在上游架构漂移**：LocalSend 已把协议层迁到 Rust（文档调研时的"纯 Flutter 应用"认知过时）→ **动摇 B 级决策，需决策人拍板**（详见下）。
3. 本机构建 LocalSend（Windows 目标）需要三件缺失的大件：VS C++ BuildTools、Windows 开发者模式、Rust 工具链。

## 实证 1：加页面的改动面（fork 卫生友好）

- 导航：**无路由表、无代码生成注册**。任意处 `context.push(() => const XxxPage())` 即跳转（上游自带的 context 扩展）。
- i18n：slang 生成产物（`lib/gen/strings_g.dart`）已提交在仓库，新页面可硬编码字符串绕过 i18n，零代码生成依赖。
- 实际改动：
  - **新增** `app/lib/pages/mylanfiles_probe_page.dart`（纯新文件，~47 行，不 import 任何上游 i18n/状态管理）
  - **修改** `app/lib/pages/tabs/send_tab.dart`（+1 import，+8 行入口按钮）
- 验证：`dart format` 0 改动；`dart analyze`（整个 app）除 1 个预存的无关 warning 外 **0 issue**。
- 注意：`flutter pub get` 因 Windows 开发者模式（symlink）失败，但 `dart pub get`（workspace 根）成功，analyze 依赖的 package_config 已生成。

## 实证 2：上游架构已 Rust 化（B 级决策动摇 ⚠️）

上游 AGENTS.md（仓库自带 AI 开发指南）+ 目录实证：

| 路径 | 现状 | 性质 |
|------|------|------|
| `app/` | Flutter UI（272 个 dart 文件） | Dart |
| `packages/core/` | **Rust crate**：crypto / discovery / **http（server+client）** / multicast / **webrtc** / model（75 个 rs 文件） | **Rust** |
| `packages/localsend_isolates/` | flutter_rust_bridge 桥 + rust 插件 crate（cargokit，锁 rust-toolchain） | 胶水 |
| `cli/`、`server/` | Rust CLI、Rust WebSocket 信令 | Rust |

依赖方向：app → localsend_isolates → rust_lib_localsend_app → localsend(Rust core)。

**与交接文档的冲突**：文档 §14.1 规划"新代码进 `packages/core`（纯 Dart 协议+VFS）+ `packages/server`（shelf）"——但 `packages/core` 这个名字已被 Rust crate 占用，且上游的 HTTP server/协议/加密**全部在 Rust**，Dart 侧只剩 UI。

**选项（需决策人拍板，AI 不自行定）**：

| 选项 | 做法 | 代价/收益 |
|------|------|-----------|
| A（AI 倾向） | 新建 Dart 包 `packages/mylanfiles_core` + `packages/mylanfiles_server`（shelf），与上游 Rust 平行；浏览/VFS/搜索全自研 Dart；上游 Rust 只服务于原互传功能 | 保持文档技术栈意图（Dart 全端自研）；fork 卫生最佳；放弃复用上游 Rust 协议层 |
| B | 跟随上游，新协议层也写 Rust（FRB 桥接） | 协议单语言；但要学 Rust+FRB+cargokit，单人成本高，与文档"Dart 生态"（FTS5/Everything/shelf）路线背离 |
| C | Route B：自建精简壳，只复用上游 `packages/core`（Rust） | 壳新但绑死 Rust 栈 |

**佐证 A 的数据**：我们自研的核心（VFS API、打包流、FTS5 trigram、Everything HTTP、缩略图管线）在 Dart 生态都有现成轮子（文档 §16 已实测 Dart IO/TLS/SHA 性能足够）；上游 Rust 层的互传协议（v2 HTTP+组播）本来就不需要改造。两平行栈唯一代价是产物体积（Rust so/dll + Flutter runtime 都要带）。

## 实证 3：本机构建 LocalSend 的缺失大件（P0 环境新发现）

1. **VS C++ BuildTools**（"使用 C++ 的桌面开发"负载）——flutter doctor 已确认缺失；
2. **Windows 开发者模式**——`flutter pub get`/plugin symlink 必需；尝试 UAC 提权被取消（用户不在场）。开启方式：设置 → 系统 → 开发者选项，或管理员注册表：`reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock /v AllowDevelopmentWithoutDevLicense /t REG_DWORD /d 1 /f`
3. **Rust 工具链**——cargokit 在 Flutter 构建时编译上游 Rust（rust-toolchain.toml 锁版本）；国内镜像 rsproxy.cn 可装。
4. Flutter 版本：上游 fvm 锁 3.41.9 / pubspec `^3.41.0`；本机 3.47.5 已满足约束（依赖解析成功，lock 更新无冲突）。

## 运行级验证（待环境补齐后补做，≤30 分钟）

`flutter run -d windows`（或 Android 真机）→ Send 标签页应出现 "MyLanFiles Probe (spike1)" 按钮 → 点击进入探针页 → 点击计数正常。

## 复现

```
cd F:\MyLanFiles\spikes\spike01-localsend-page\upstream
dart pub get                # workspace 根；flutter pub get 需先开开发者模式
cd app && dart analyze      # 预期：仅 1 个无关 warning
```
