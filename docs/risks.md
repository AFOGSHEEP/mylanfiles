# 不确定性登记表（docs/risks.md）

> 依据交接文档 §2.5 协议：任何"文档没预料到的问题"必须在此登记——现象/根因/解法/是否动摇 B 级决策。
> 每次 P 检查点回顾一次；已关闭条目保留供追溯。

## 一、P0 三个侦察 spike 结论（2026-09-30）

| Spike | 雷区 | 结论 | 置信度 |
|-------|------|------|--------|
| **S1 fork 加页面 PoC** | 1 | "加页面"改动面极小（1 新文件 + 1 上游文件 2 行；无路由表/无代码生成注册，`context.push(()=>Page())` 即跳转）。**但发现上游架构已 Rust 化**（见 R-002）。`dart analyze` 全 app 通过（仅 1 个预存无关 warning）。UI 集成耦合担忧解除；架构层出现新雷 | 高（代码级）；运行级待环境 |
| **S2 Dart FFI 调 WinRT 热点** | 2 | ✅ **完全成功**。win32 5.15 + winmd 解析的 GUID/vtable 槽位，普通权限读出 `TetheringOperationalState=2(Off)` 与 SSID，与 PowerShell 一致。方法论可推广到任意 WinRT API（含 StartAsync/ConfigureAsync 槽位已探明）。剩余难点仅 IAsyncOperation 等待模式（P2，预估 0.5–1 天） | 高（真机已跑通） |
| **S3 Windows BLE 扫描** | 3 | 官方路径确认：`flutter_blue_plus_windows`（维护者 endorsed，基于 win_ble），**API 零改动**（hide+双 import）。依赖解析成功（FBP 1.34.5 + wrapper 1.26.1 无冲突），扫描/连接/notify/20 字节写代码 analyze 通过。运行验证待 VS BuildTools | 中高（依赖+静态验证）；运行级待环境 |

**雷区记分卡（P0 后）**：#1 UI 部分✅/架构部分⚠️新雷 · #2 ✅关闭 · #3 ✅关闭（待运行复核）· #4-#10 未侦察（按期）。

## 二、问题登记表

### R-002（⚠ 动摇 B 级）上游 LocalSend 架构已 Rust 化

- **现象**：clone 上游后发现 `packages/core` 是 Rust crate（crypto/discovery/http server+client/multicast/webrtc，75 个 .rs 文件），app 经 `packages/localsend_isolates`（flutter_rust_bridge + cargokit）调用；Dart 侧（app/lib 272 文件）主要是 UI/provider。上游自带 AGENTS.md 确认此布局。
- **根因**：交接文档调研快照（§9.14 "79.6% Dart"）已过时，上游此后完成了协议层 Rust 迁移。
- **影响**：B 级决策"新代码只进 `packages/core`、`packages/server`"的路径假设失效——`packages/core` 名字被占用，且若走 Rust 路线，shelf/FTS5/Everything 等 Dart 生态设计（§4）都要换栈。
- **候选解法**（**需决策人拍板，AI 不自行定**）：
  - **A（AI 倾向）**：新建 Dart 包 `packages/mylanfiles_core` + `packages/mylanfiles_server`（shelf+TLS），与上游 Rust 平行。自研浏览/VFS/搜索全 Dart；上游 Rust 只服务原互传功能。+：贴文档技术栈与全部既有设计；fork 卫生最佳。-：放弃复用上游 Rust 协议层；产物带双 runtime。
  - **B**：新协议层跟随上游写 Rust（FRB 桥）。+：单语言协议层。−：Rust+cargokit+FRB 学习/维护成本，Dart 生态设计全部重做。
  - **C**：Route B 自建壳，仅复用上游 Rust core。+：壳干净。−：同样绑 Rust 栈，且丢掉上游 UI。
- **登记时间**：2026-09-30（Spike 1）。

### R-001 本机缺 VS C++ BuildTools（"使用 C++ 的桌面开发"负载）

- **现象**：`flutter doctor` `[X] Visual Studio - develop Windows apps`；F:\VisualStudioPackages 只是安装包缓存，无实际 VS。
- **影响**：`flutter run -d windows` 不可构建 → S1/S3 的运行级验证、P0 "clone 上游跑通 Windows 互传" 验收全部阻塞。
- **解法**：**待决策人确认安装**（下载 ~2-3GB，走 winget/官方离线包）。
- **是否动摇 B 级**：否（纯环境）。

### R-003 Windows 开发者模式未开启

- **现象**：`flutter pub get` 报 "Building with plugins requires symlink support"；UAC 提权尝试被取消（无人值守）。
- **根因**：Flutter 插件在 Windows 上创建 symlink 需要开发者模式（或管理员每次运行）。
- **影响**：带 plugin 的项目（上游 app、S3 PoC）pub get/构建受阻；**绕过**：workspace 根 `dart pub get` 可完成依赖解析+analyze（已用此法完成 S1/S3 静态验证）。
- **解法**：设置→系统→开发者选项开启；或管理员运行
  `reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock /v AllowDevelopmentWithoutDevLicense /t REG_DWORD /d 1 /f`。**需用户一次性操作**。
- **是否动摇 B 级**：否。

### R-004 本机无 Rust 工具链

- **现象**：`cargo` 不在 PATH；上游构建链含 cargokit（Flutter 构建时编译 `packages/localsend_isolates/rust`，锁 rust-toolchain.toml）。
- **影响**：无论架构选项 A/B/C，只要构建上游 app（Windows/Android 产物含 Rust 编译），本机就需要 Rust。选项 A 也需要（上游 app 的互传功能仍在）。
- **解法**：**待确认后安装**（rustup，国内镜像 `rsproxy.cn`，约 500MB；msvc target 需先有 R-001 的 BuildTools）。
- **是否动摇 B 级**：否（环境），但加重 A 选项的"双栈"成本论据。

### R-005 国内镜像可用性笔记（环境情报，非风险项）

- Flutter SDK：清华/上交 `*/flutter/` 路径 404（目录结构调整）；**`storage.flutter-io.cn`（Google 中国 CDN）可用且支持断点续传**——SDK 3.47.5 已装于 `F:\flutter`。pub 走 `pub.flutter-io.cn`。
- dl.google.com（Android cmdline-tools）直连可用，无需代理（遵守"不开代理"约束）。
- pip 走清华；GitHub 直连 clone 可用（速度尚可，LocalSend ~几十 MB 数分钟）。
- 用户环境变量已设：`PUB_HOSTED_URL`/`FLUTTER_STORAGE_BASE_URL`/`PUB_CACHE=F:\PubCache`/`ANDROID_SDK_ROOT=F:\SDK`。

### R-006 Android 真机未连接

- **现象**：`adb devices` 空（adb 37.0.0 正常，daemon 已起）。
- **影响**：P0 验收项"-d 安卓机跑通互传"挂起；S1 运行级验证的替代路径（Android 端）也不可用。
- **解法**：用户插入真机并开 USB 调试（P0 收尾时）。
- **是否动摇 B 级**：否。

## 三、已关闭（本次会话处理完的雷）

| # | 雷 | 处置 |
|---|-----|------|
| E1 | Git Bash GNU tar 不认 zip，SDK 解压失败 | 换 `unzip`；顺手教训：Windows 下 zip 一律 unzip/PowerShell |
| E2 | win32 包 vtable 约定踩坑（`lpVtbl.value[n]` 双重解引用→崩溃；`asFunction` 泛型不能运行时传；跨行泛型解析歧义） | 已写进 S2 NOTES 的方法论，后续 WinRT 绑定照抄 |
| E3 | flutter create 模板 test 引用被删类 + pubspec 依赖插错段 | 已修（S3） |

## 四、P0 尚未完成的验收项（依赖待确认清单）

- [ ] clone 上游 → `flutter run -d windows` / `-d 安卓机` 各跑通一次互传（阻塞：R-001/003/004 + R-006）
- [ ] 电脑开热点 + filebrowser 手机浏览器实测（阻塞：需要用户手机在场；filebrowser 单二进制可随时部署）
- [ ] CI 上线 + 分支保护（阻塞：GitHub 仓库初始化方案待确认，见 status.md）
