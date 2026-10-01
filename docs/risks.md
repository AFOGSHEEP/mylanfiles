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

### R-009（⚠️ 约束变更，已按决策人口头指示执行）「不开模拟器」调整为「模拟器做功能面，性能/OEM 验收留真机」

- **背景**：交接文档 §3 明确「不开模拟器」。2026-10-01 决策人主动提出「用虚拟机」代替真机在场，以解除开发阻塞。
- **调整后口径**：Android 模拟器承担**功能面**（Android 构建链 bring-up、权限引导页、MediaStore、配对/浏览/打包/断点全链路 E2E、上游互传功能验证）；以下各项**模拟器数据不可信**，仍留真机：雷区 #5（打包流 29× 增益，依赖真实 Wi-Fi RTT，虚拟网卡 RTT≈0）、雷区 #6（OEM 杀后台，模拟器是 AOSP）、热点场景、相机扫 QR、BLE、Windows 防火墙 LAN 入站规则（模拟器流量经 qemu 走宿主内部，不触发真实入站）。P0 验收「-d 安卓机互传」：模拟器过功能，真机补测章。
- **本机可行性探测（2026-10-01）**：`HypervisorPresent=True`（WHPX 加速可用；此时 VT-firmware 显示 False 属正常，VT 已被 Hyper-V 接管）；`F:\SDK` 已有 emulator 主程序/JDK17/build-tools 36/37/platforms android-36；**缺** system-images、NDK（cargokit Rust Android 构建必需），共约 2–3GB，dl.google.com 直连可下；无 AVD（avdmanager 现建）。F 盘余 35GB，充足。注意：模拟器是 x86_64 镜像，Rust 需加 `x86_64-linux-android` target（真机再补 `aarch64-linux-android`），rustup 走 rsproxy。
- **是否动摇 B 级**：否（验收手段调整，验收项本身不变）。

### R-008 Windows 首次 anyIPv4 TLS bind 触发防火墙放行（预期内，非意外雷）

- **现象**：浏览页服务端从 loopback 改绑 `InternetAddress.anyIPv4`（§4.1 LAN 可达所需），debug exe 首次 bind 时 Windows 防火墙可能弹放行对话框；拒绝则 LAN 对端连不上、loopback 演示不受影响。
- **处置**：交接文档 §8 坑 1 已有预案（为调试产物加专用网络入站放行）；留待真机联调会话与用户一起过 UAC。
- **是否动摇 B 级**：否。

## 三、已关闭（本次会话处理完的雷）

| # | 雷 | 处置 |
|---|-----|------|
| E1 | Git Bash GNU tar 不认 zip，SDK 解压失败 | 换 `unzip`；顺手教训：Windows 下 zip 一律 unzip/PowerShell |
| E2 | win32 包 vtable 约定踩坑（`lpVtbl.value[n]` 双重解引用→崩溃；`asFunction` 泛型不能运行时传；跨行泛型解析歧义） | 已写进 S2 NOTES 的方法论，后续 WinRT 绑定照抄 |
| E3 | flutter create 模板 test 引用被删类 + pubspec 依赖插错段 | 已修（S3） |
| E4 | rsproxy 的 `RUSTUP_UPDATE_ROOT` 404（cargokit rustup 自更新挂掉） | 正确值 `https://rsproxy.cn/rustup`（不带 /dist，官方文档写法有误）；已固化进环境约定 |
| E5 | 中文 Windows 代码页 936：C4819 警告当错误，connectivity_plus 编译失败（`CL=/utf-8` 环境变量对 MSBuild 链无效） | CMake `add_compile_options(/utf-8)` 补丁（已进 fork，可上游化） |
| E6 | 上游 `localsend_msix_helper.msix` 被 gitignore 但 CMake 无条件安装 → 新 clone INSTALL 步骤必失败 | 条件安装补丁（已进 fork，可上游化） |

## 四、P0 尚未完成的验收项（依赖待确认清单）

- [ ] clone 上游 → `flutter run -d windows` / `-d 安卓机` 各跑通一次互传（阻塞：R-001/003/004 + R-006）
- [ ] 电脑开热点 + filebrowser 手机浏览器实测（阻塞：需要用户手机在场；filebrowser 单二进制可随时部署）
- [ ] CI 上线 + 分支保护（阻塞：GitHub 仓库初始化方案待确认，见 status.md）
