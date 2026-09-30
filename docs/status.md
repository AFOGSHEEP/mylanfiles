# 项目状态（docs/status.md）

> 每次会话结束更新。结构：当前阶段 / 已完成 / 下一步 / 待决策人确认事项。

- 更新：2026-09-30（P0 第 1 次会话）
- 本机项目根：`F:\MyLanFiles`（spikes/ + docs/；正式 repo 尚未初始化——见"待确认"）

## 当前阶段

**P0 — 环境 + 链路验证**，进行中（约 3/6 项达成；三个侦察 spike 已完成 2 个全绿 + 1 个代码级）。

## 已完成（本次会话）

1. **本机环境盘点**（避免重复下载）：
   - 已有：Android Studio（F:\andoridStudio）、Android SDK（F:\SDK：platforms 36/36.1、build-tools 36.1/37.0、platform-tools/adb 37.0.0）、JDK 17（E:\JDK）、Git（E:\Git）、VS Code（F:）+ 已补装 Flutter/Dart 插件、Everything（E:\everything）、Chrome 未装（web 目标不需要）。
   - 新装：**Flutter 3.47.5 stable**（F:\flutter，storage.flutter-io.cn 镜像）、Android cmdline-tools（F:\SDK\cmdline-tools\latest，dl.google.com 直连）、**melos 8.9.0**、licenses 已接受。
   - `flutter doctor`：Flutter✅ Android✅ Windows 版本✅ 设备✅；剩 [X]Visual Studio（待确认）、[X]Chrome（忽略）。
   - 环境变量（用户级，已永久）：PATH+=`F:\flutter\bin;F:\PubCache\bin`，`PUB_HOSTED_URL`/`FLUTTER_STORAGE_BASE_URL`/`PUB_CACHE=F:\PubCache`/`ANDROID_SDK(_ROOT)=F:\SDK`。
2. **Spike 2（雷区2）✅ 全绿**：Dart FFI 调 WinRT 热点 API 成功（详见 spikes/spike02-winrt-hotspot/NOTES.md）。
3. **Spike 1（雷区1）代码级 ✅**：LocalSend 加页面改动面极小；**发现上游 Rust 化**（R-002，B 级动摇，已上报待拍板）。
4. **Spike 3（雷区3）静态 ✅**：flutter_blue_plus_windows 官方路线确认，依赖+analyze 通过（运行验证待 BuildTools）。
5. 文档三件套建立：`docs/adr/0001`（fork 卫生 + trigram，含挂起项）、`docs/risks.md`（登记表+spike 结论）、本文件。

## 下一步（下次会话，按优先序）

1. **等决策人**：架构选项 A/B/C（R-002）+ 三件大件安装确认（见下）→ 装 VS BuildTools + Rust + 开发者模式。
2. 补 Spike 1/3 运行级验证（`flutter run -d windows` 各跑一次；S3 需 BLE 外设/手机配合）。
3. P0 剩余验收：上游互传双端跑通（含插 Android 真机）、热点 + filebrowser 零代码链路实测、CI + 分支保护。
4. （若选项 A 批准）`packages/mylanfiles_core` 骨架 + 路径安全测试先行（P1 首任务预备）。

## 待决策人确认事项（按重要性排序）

### 1. 架构路线（R-002，阻塞 P1 开工）——**需拍板**

上游 `packages/core` 已是 Rust crate。选 **A**（新建 Dart 包 `mylanfiles_core`/`mylanfiles_server`，与上游 Rust 平行，AI 推荐）/ **B**（跟随 Rust+FRB）/ **C**（自建壳复用 Rust core）。详见 risks.md R-002。

### 2. 大型依赖安装清单（约 3-4GB 磁盘 + 下载流量）——**需确认**

| 项 | 大小 | 用途 | 安装方式（国内镜像，无代理） |
|----|------|------|------------------------------|
| VS 2022 Build Tools + "使用 C++ 的桌面开发"负载 | ~2-3GB | flutter run -d windows 必需 | `winget install Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"`（或官方离线 iso） |
| Rust 工具链（rustup + stable-msvc） | ~500MB-1GB | 上游 app 构建含 cargokit Rust 编译（任何架构选项都需要） | rsproxy.cn 下载 rustup-init.exe，设 `RUSTUP_DIST_SERVER=https://rsproxy.cn`、`RUSTUP_UPDATE_ROOT=https://rsproxy.cn/rustup/dist` 后 `rustup default stable-msvc`；crates.io 换 rsproxy 源 |

### 3. Windows 开发者模式——**需一次性手动操作**（10 秒）

设置 → 系统 → 开发者选项 → 开；或管理员执行：
`reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock /v AllowDevelopmentWithoutDevLicense /t REG_DWORD /d 1 /f`
（解锁 Flutter 插件 symlink；不开则每次构建都要管理员权限）

### 4. GitHub 仓库初始化方案——**fork 前需过目**

```
推荐方案（fork 模式）：
1. GitHub 上 fork localsend/localsend → <你的账号>/mylanfiles（保留 fork 关系，
   便于日后向上游提 bug fix PR；Apache-2.0 合规自动体现在 LICENSE 文件保留）
2. 本地：git clone https://github.com/<你>/mylanfiles F:\MyLanFiles\repo
   cd repo && git remote add upstream https://github.com/localsend/localsend.git
3. 把本次 P0 产物（docs/、spikes/ 的 NOTES）作为首个分支 feat/p0-baseline 并入
4. CI：.github/workflows/ci.yml（dart format --set-exit-if-changed + dart analyze
   + flutter test；matrix: windows-latest + ubuntu-latest）+ 分支保护（CI 绿才可合并）
5. 分支模型：main 跟随（每月 merge upstream）；功能走 <3 天短命分支 + PR + squash

备选（import 模式）：GitHub 建空仓 mylanfiles，把上游 clone 推上去 + upstream remote。
区别：fork 模式在 GitHub 侧有 fork 标记（star/PR 生态友好）；import 模式仓库更"干净"
（不会有 fork 网络的约束）。
```

**注意**：在架构选项（事项 1）拍板前，不向仓库推送任何 `packages/*` 业务代码——P0 产物（docs/spikes）不受影响。

### 5. P0 收尾需要用户在场的两项

- 插入 Android 真机（USB 调试开）跑一次上游互传验收；
- 电脑开热点 + 手机浏览器访问 filebrowser（届时我先在 F 盘部署 filebrowser 单二进制）。

## 环境速查（下次会话直接用）

- Flutter：`F:\flutter`（3.47.5）；pub 缓存 `F:\PubCache`；melos 8.9.0
- Android SDK：`F:\SDK`（ANDROID_HOME 已设）；adb=`F:\SDK\platform-tools\adb.exe`（未入 PATH，可用完整路径）
- 项目：`F:\MyLanFiles`（docs/ 本文档 + spikes/ 三个 spike + 两份原始文档拷贝）
- 上游代码：`F:\MyLanFiles\spikes\spike01-localsend-page\upstream`（含探针页改动，未推送任何远端）
- 镜像：SDK=storage.flutter-io.cn，pub=pub.flutter-io.cn，pip=清华，rust=rsproxy.cn（待装）
- 约束：全程不使用代理（用户 dsh 记忆 + 本次会话指示）
