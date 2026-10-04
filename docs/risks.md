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

### R-002（✅ 已拍板：选项 A）上游 LocalSend 架构已 Rust 化

- **现象**：clone 上游后发现 `packages/core` 是 Rust crate（crypto/discovery/http server+client/multicast/webrtc，75 个 .rs 文件），app 经 `packages/localsend_isolates`（flutter_rust_bridge + cargokit）调用；Dart 侧（app/lib 272 文件）主要是 UI/provider。上游自带 AGENTS.md 确认此布局。
- **根因**：交接文档调研快照（§9.14 "79.6% Dart"）已过时，上游此后完成了协议层 Rust 迁移。
- **影响**：B 级决策"新代码只进 `packages/core`、`packages/server`"的路径假设失效——`packages/core` 名字被占用，且若走 Rust 路线，shelf/FTS5/Everything 等 Dart 生态设计（§4）都要换栈。
- **决策（2026-09-30）**：**选项 A** —— 新建 `packages/mylanfiles_core`/`mylanfiles_server` 与上游 Rust 平行，详见 docs/adr/0002。以下候选留档：
  - **A（AI 倾向）**：新建 Dart 包 `packages/mylanfiles_core` + `packages/mylanfiles_server`（shelf+TLS），与上游 Rust 平行。自研浏览/VFS/搜索全 Dart；上游 Rust 只服务原互传功能。+：贴文档技术栈与全部既有设计；fork 卫生最佳。-：放弃复用上游 Rust 协议层；产物带双 runtime。
  - **B**：新协议层跟随上游写 Rust（FRB 桥）。+：单语言协议层。−：Rust+cargokit+FRB 学习/维护成本，Dart 生态设计全部重做。
  - **C**：Route B 自建壳，仅复用上游 Rust core。+：壳干净。−：同样绑 Rust 栈，且丢掉上游 UI。
- **登记时间**：2026-09-30（Spike 1）。

### R-001（✅ 已解除）本机缺 VS C++ BuildTools（"使用 C++ 的桌面开发"负载）

- **现象**：`flutter doctor` `[X] Visual Studio - develop Windows apps`；F:\VisualStudioPackages 只是安装包缓存，无实际 VS。
- **影响**：`flutter run -d windows` 不可构建 → S1/S3 的运行级验证、P0 "clone 上游跑通 Windows 互传" 验收全部阻塞。
- **解法**：✅ 已装（VS 2022 BuildTools 17.14.41 + C++ 桌面负载，winget，2026-09-30 会话 2）。flutter doctor 全绿。
- **是否动摇 B 级**：否（纯环境）。

### R-003（✅ 已解除）Windows 开发者模式未开启

- **现象**：`flutter pub get` 报 "Building with plugins requires symlink support"；UAC 提权尝试被取消（无人值守）。
- **根因**：Flutter 插件在 Windows 上创建 symlink 需要开发者模式（或管理员每次运行）。
- **影响**：带 plugin 的项目（上游 app、S3 PoC）pub get/构建受阻；**绕过**：workspace 根 `dart pub get` 可完成依赖解析+analyze（已用此法完成 S1/S3 静态验证）。
- **解法**：✅ 已开启（会话 2 经 UAC 注册表写入并验证 `0x1`）。flutter pub get 的 plugin symlink 正常。
- **是否动摇 B 级**：否。

### R-004（✅ 已解除）本机无 Rust 工具链

- **现象**：`cargo` 不在 PATH；上游构建链含 cargokit（Flutter 构建时编译 `packages/localsend_isolates/rust`，锁 rust-toolchain.toml）。
- **影响**：无论架构选项 A/B/C，只要构建上游 app（Windows/Android 产物含 Rust 编译），本机就需要 Rust。选项 A 也需要（上游 app 的互传功能仍在）。
- **解法**：✅ 已装（stable 1.98.1 + 上游钉版 1.97.1，rsproxy 镜像；crates.io 走 rsproxy sparse 源）。cargokit 链实测通过（localsend_app.exe 构建成功）。
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

### R-007（✅ 已解除）flutter_rust_bridge 运行时/代码生成版本漂移，上游 Rust 桥 init 失败

- **现象**（P1 第 2 次会话冒烟测试发现）：debug 构建启动即打 `[SEVERE] [Init] Error during init — rust_lib_localsend_app's codegen version (2.12.0) should be the same as runtime version (2.13.0)`。app 不崩（init 错误被上游吞掉继续跑），但 **Rust 协议层（上游互传的全部功能）运行期不可用**。
- **根因**：`packages/localsend_isolates/pubspec.yaml` 用 caret 约束 `flutter_rust_bridge: ^2.12.0`，而已提交的生成代码 `frb_generated.dart` 是 2.12.0 codegen 产物；P0 会话提交的 `pubspec.lock` 解析到了 2.13.0（caret 放行），运行时 sanity check 失败。**属上游依赖约束与提交产物不一致，非本会话引入**（HEAD 的 lock 里就是 2.13.0）。
- **影响**：直接撞 P0 验收项「上游 App 双端互传一次」——真机测试前必须修。MyLanFiles 自研功能纯 Dart（ADR-0002），不受影响。
- **解法**：✅ 已 pin `flutter_rust_bridge: 2.12.0`（精确版本）+ 重新解析 lock，`fix(deps)` 提交；debug 冒烟复测 0 个 init 错误。教训：**凡提交生成代码的包，依赖约束一律精确 pin**（cargokit/FRB 类桥接尤甚）。
- **是否动摇 B 级**：否（上游集成层问题）。

### R-009（✅ 已解除）「不开模拟器」约束变更 → 真机到场，模拟器方案归档

- **背景**：交接文档 §3「不开模拟器」；2026-10-01 决策人指示改用虚拟机解除阻塞。
- **结局**：2026-10-04 决策人接入真机（Xiaomi 23078RKD5C / Android 15），真机 E2E 矩阵全绿（见 status.md 第 4 次会话），模拟器路径不再需要（构建链/权限/Rust targets 均已按真机打通）。方法论保留：视觉坐标驱动 UI 精度不足（±30%），**logcat 面包屑闭环**（`[MLF]` 日志 + 文件/env 门控 E2E 钩子）是无人值守验证的正解。
- **是否动摇 B 级**：否。

### R-010（✅ 已解除）MIUI USB 安装门槛

- **现象**：`adb install` 报 `INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`；MIUI 弹窗 10s 超时自动拒绝；开发者选项默认关「USB 安装」。
- **解法**：决策人开启「USB 安装」+ 在场点掉弹窗（首次）；后续 install 直接 Success。debug 构建包名带 `.debug` 后缀（applicationIdSuffix），appops 等命令注意用全名。
- **是否动摇 B 级**：否（环境）。

### R-011（✅ 已解除）Flutter 3.47 对上游 Android 构建的最低版本要求

- **现象**：Gradle 8.13 < 8.14.0、Kotlin 2.2.0 < 2.2.20，flutter-gradle-plugin 校验直接失败。
- **解法**：wrapper 升 8.14.3、KGP 升 2.2.20（fork 内两个小版本号改动，**可上游化**）；另有 AGP 8.12.1「即将弃用」警告（非阻塞，留观）。
- **教训**：上游钉的构建版本组合对其 CI 的 Flutter 版本成立，对本机 3.47.5 不成立；fork 升级 Flutter 时构建链版本三件套（Gradle/Kotlin/AGP）要一起过。
- **是否动摇 B 级**：否。

### R-008 Windows 首次 anyIPv4 TLS bind 触发防火墙放行（✅ 已解除）

- **现象**：浏览页服务端从 loopback 改绑 `InternetAddress.anyIPv4`（§4.1 LAN 可达所需），debug exe 首次 bind 时 Windows 防火墙可能弹放行对话框；拒绝则 LAN 对端连不上、loopback 演示不受影响。
- **解法**：✅ 2026-10-04 经 UAC（决策人批准）添加入站规则 `MyLanFiles Debug In`（域/专用/公用，按程序路径放行 debug exe）；真机 LAN 直连实测通过。
- **是否动摇 B 级**：否。

## 三、已关闭（本次会话处理完的雷）

| # | 雷 | 处置 |
|---|-----|------|
| E7 | MIUI USB 安装默认禁用 + 弹窗 10s 超时（R-010） | 决策人开开关+点弹窗 |
| E8 | sdkmanager 拒认 JDK 版本串 `17+35-LTS` | `SKIP_JDK_VERSION_CHECK=1` |
| E9 | Gradle 8.13/Kotlin 2.2.0 低于 Flutter 3.47 最低要求（R-011） | 升 8.14.3 / 2.2.20（可上游化） |
| E10 | `grep -c` 计数 0 → 退出码 1 → `&&` 链断，构建静默未跑 | 判断改显式 |
| E11 | 截图 CDN 撞名返回旧图；视觉模型坐标 ±30% 不可靠 | 放弃像素驱动；`[MLF]` 日志面包屑 + 文件/env 门控 E2E 钩子闭环 |
| E12 | Git Bash 把设备路径 `/storage/...` 改写成本机路径 | `MSYS_NO_PATHCONV=1` |
| E13 | 上游 app 单实例机制：旧进程不杀，新实例带新 env 启动即退出 | 起服务前 `taskkill //IM localsend_app.exe //F` |

| # | 雷 | 处置 |
|---|-----|------|
| E1 | Git Bash GNU tar 不认 zip，SDK 解压失败 | 换 `unzip`；顺手教训：Windows 下 zip 一律 unzip/PowerShell |
| E2 | win32 包 vtable 约定踩坑（`lpVtbl.value[n]` 双重解引用→崩溃；`asFunction` 泛型不能运行时传；跨行泛型解析歧义） | 已写进 S2 NOTES 的方法论，后续 WinRT 绑定照抄 |
| E3 | flutter create 模板 test 引用被删类 + pubspec 依赖插错段 | 已修（S3） |
| E4 | rsproxy 的 `RUSTUP_UPDATE_ROOT` 404（cargokit rustup 自更新挂掉） | 正确值 `https://rsproxy.cn/rustup`（不带 /dist，官方文档写法有误）；已固化进环境约定 |
| E5 | 中文 Windows 代码页 936：C4819 警告当错误，connectivity_plus 编译失败（`CL=/utf-8` 环境变量对 MSBuild 链无效） | CMake `add_compile_options(/utf-8)` 补丁（已进 fork，可上游化） |
| E6 | 上游 `localsend_msix_helper.msix` 被 gitignore 但 CMake 无条件安装 → 新 clone INSTALL 步骤必失败 | 条件安装补丁（已进 fork，可上游化） |

## 四、P0/P1 尚未完成的验收项（依赖待确认清单）

- [x] clone 上游 → Windows 构建/运行（P0，2026-09-30 达成；R-007 FRB 修复后 init 零错误）
- [x] MyLanFiles 真机全链路（P1，2026-10-04：配对/浏览/下载/Range 续传/打包/skip，真实 Wi-Fi）
- [ ] 上游互传手机↔Windows 一次（发现已互通；传输需 PC 端点接收确认框，等 10 分钟窗口）
- [ ] MyLanFiles 扫码配对真机（相机对准屏幕，等 10 分钟窗口）
- [ ] filebrowser 手机浏览器基准线体验（可随时部署，等在场）
- [ ] CI 上线 + 分支保护（阻塞：GitHub 推送仍暂停）
- [ ] 打包流 29× 增益 A/B 正式测速（雷区 #5；单流基线 2.7MB/s 已测）
