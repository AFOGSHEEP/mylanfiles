# 项目状态（docs/status.md）

> **新会话快速上手（给 AI 的引导，读完本文件即可开工，无需重读全部历史）**
> - 角色与协议：你是 MyLanFiles 的开发代理，遵守 `docs/MyLanFiles_开发交接文档.md` 的 §2.5（不确定性管理）与 §9（工作约定）；配套深度背景 `docs/MyLanFiles_可行性报告与开发计划.md` 按需查阅。
> - 一切以本文件「当前阶段 / 下次会话计划 / 待确认」三节为准；风险与雷区见 `docs/risks.md`；关键决策见 `docs/adr/0001`、`0002`；轮计划见 `docs/plan-*.md`。
> - 环境/镜像/构建命令：本文件末尾「环境速查」一节。代理已放开（见速查）。
> - 边界：不推 GitHub（决策人叫停，交接命令备好）；不开始 P2；B 级方向性决策被动摇时停下汇报。测试阶段按决策人指示用**多个独立 agent 跑多轮独立测试**。

> 每次会话结束更新。结构：当前阶段 / 已完成 / 下一步 / 待决策人确认事项。

- 更新：2026-10-05（R7 补充轮——大众化自动发现 + 传输算法优化，决策人两项目标驱动；研究笔记 docs/research/transfer-optimization.md）
- 本机项目根：`F:\MyLanFiles`
- 正式仓库：`F:\MyLanFiles\repo`（分支 `feat/p1-vfs-server`，本地 20+ 提交待推送）

## 当前阶段

**P1 — 日常可用达成（R6 末）**。在双向传输闭环之上补齐日常使用三件事：找得到（入口正名）、记得住（端口/配对/设备全记忆化，重启零操作恢复）、看得见照片（相册网格+缩略图，真实 500 张相册实测 0.54s/张后台预取）。**核心场景「电脑浏览手机相册并原图拉取」已端到端真机全绿。**

## 第 5 轮已完成（R5,计划 6 工作流全部落地）

1. **WS1 R-013 虚拟路径语义**：前导 `/`=共享根（协议规范形）；主机绝对路径仅根内兼容接受；list/stat 只吐虚拟路径（盘符/主机目录不再出协议）；符号链接复检改直连前缀比对 `containsReal`（堵住语义变更引入的逃逸回归——被既有 symlink 测试当场抓住）
2. **WS2 上传通道**：`MlfClient.upload` 远端 `<name>.mlfpart` 暂存 + 断点（offset=远端已有长度）+ 长度确认 + rename 原子落名；浏览页「上传到当前目录」（file_picker 多选）进队列（进度/取消/重配对/自动刷新）；`fs/write` 流式 PUT（StreamedRequest）
3. **WS3 反向 E2E 设施**：手机 `mlf-server.flag` 自动开服务（配对 JSON 进 logcat）；桌面 `MLF_PAIR_FILE` 自动连接 + `MLF_DL_FILE`/`MLF_UL_FILE` 清单驱动传输——**双向全部无人值守可测**
4. **WS4 相册快路径**：`GET /api/v1/media/list`（已知桶白名单 DCIM/Pictures/… 天然免疫穿越；深度≤3 walk；image/video/audio 分类；mtime 倒序分页）。目录桶版（纯 Dart 跨平台）；原生 MediaStore 通道待性能数据再议
5. **WS5 健壮化**：R-014 落地（/pair 豁免业务黑名单但自带独立限速器；成功配对双清）；队列自动退避重试（2s/8s 可注入，退避期间任务保持 queued 不闪失败）
6. **WS6 多 agent 独立回归（3 agent）**：
   - **反向真机 E2E：PASS**——PC 客户端↔手机服务端（共享根=手机全存储 74 条目）：打包下载 3/3 sha 全等、上传 2/2 sha 全等、无 .mlfpart 残留；顺带抓出 3 个 harness 缺陷（权限竞态/桌面开页/死代码 targetDir）→ 当轮修复并真机复验
   - **对抗协议 v2：9/10** → 4 项全部修复+回归测试（pair 畸形 JSON 曾可无限刷绕过限速；op 扁平体 500；rename 穿越 newName 静默消毒；media 负数分页 500）
   - 完整性：双向 sha256 全等
7. 测试基线：**core 46 + server 40 + queue 10 = 96 全绿**；本轮 7 个功能提交 + 2 个修复提交

## 待决策人确认事项

### 1. 需要你在场的 10 分钟（不变，攒着随时做）
- 手机扫 PC 屏二维码（相机链路 + ML Kit 在 MIUI 的表现）；上游互传验收章（PC 弹接收框点允许）

### 2. GitHub 推送（仍暂停，命令保留备用）
```
F:\bin\gh.exe auth login --hostname github.com
```

## R10 发布轮（2026-10-05,决策人授权:「自己上传」+ 双语 README + 博客 + 宣传）

- **已上传**:fork localsend/localsend → 改名 **AFOGSHEEP/mylanfiles**(凭据走 GitHub Desktop 的 Windows 凭据管理器令牌);推送 feat/p1-vfs-server(50+ 提交)并设为默认分支;topics×10;描述/主页;**v0.1.0 release 附三件套**(APK/Win zip/mlf-serve.exe):https://github.com/AFOGSHEEP/mylanfiles/releases/tag/v0.1.0
- **README 中英双语**(原 README.md 移至 docs/README-LocalSend-upstream.md 保留);**开发博客** blog/2026-10-05-the-journey.md(六天实录:平行架构赌注/垂直切片/Mathis 驱动优化/多 agent 方法论)
- **宣传**:自动渠道已尽(topics/release/双语首页/fork 关系);`F:\MyLanFiles\promotion\一键发布素材包.md` 含 HN/Reddit/V2EX/知乎/X 五平台现成文案;发帖需决策人账号(建议顺序 HN→Reddit→V2EX→知乎→X)
- 推送边界解除记录:决策人 2026-10-05 明示「你自己上传」,原「不推 GitHub」约束作废

## R9 完备性审计轮（2026-10-05,决策人目标:「仓库完备性,可上传作为测试版」+ 多 agent 严格复查）

**自查修复**:版本 0.1.0+1;release 签名 debug 回退(新 clone 可出包,审计实测生效);CI 升 3.47.5+纳入 app 门禁;lint 清零。
**三 agent 严格审计**(`F:\MyLanFilesudit\`):
- 全新克隆构建:**READY** — git archive→pub get→format/analyze/test→编译并运行 mlf-serve→无签名配置出 release APK(签名回退验证);「本地能跑克隆跑不了」零缺失(CHANGELOG.md 符号链接为 Windows 观感小瑕疵)
- 发布就绪:NEEDS-FIX→已修 — write 回执 sha256 测试断言(卫生审计同发现)、上游 ci.yml packaging 加 fork 守卫、README 计数、NOTICE(Apache §4(b))、包 license 字段、mlf-serve 版本输出;机密扫描零命中
- git 卫生:NEEDS-CLEANUP→已修 4/4 — .gitattributes 行尾规范化、噪音文件确认已与上游一致、Gradle/Kotlin 升级理由引用 R-011;**遗留:仅 upstream 远端无 origin(推送待决策人 gh auth)**
最终门禁:format 0 改动 + analyze 0 error + **101 测试全绿**;工作树干净。

## R8 Demo 轮（2026-10-05,决策人目标:「多端部署、初步功能的初版 demo」）

**交付物 `F:\MyLanFiles\demo\`**:①`MyLanFiles-android-v0.1.0.apk`(签名 release,146MB);②`localsend-app-win64-v0.1.0.zip`(release,解压即用);③`mlf-serve.exe`(**无头服务器单二进制 10.4MB**,`--root/--alias/--port/--no-pair`,身份在共享根外,端口持久,自动发现);④快速开始 README。
**验证**:mlf-serve 被 PC 客户端 Wi-Fi 发现(DEMO-NAS)→配对→打包下载 sha 全等;Windows release(AOT)配对下载 sha 全等;Android release 装机待决策人点 MIUI 弹窗(debug 版全程在机,功能矩阵已全绿)。iOS/macOS/Linux:源码兼容,各自平台一条命令编译(README 有)。

## R7 补充轮（2026-10-05,决策人批评驱动:「不能自己发现设备,太极客」「传输算法深度优化」）

1. **自动发现(大众化核心)**:UDP 广播宣告/监听(core 包,广播而非组播=零权限零平台通道);浏览页「附近设备」chips,点一下即连(与扫码同一条 pin 配对路径,安全模型不降级);**真机验证:PC 纯 Wi-Fi 发现手机(`discovered: Android 设备@192.168.3.149`),零 USB 零配置**。首次使用流程缩短为:两端开 app→点设备→用。
2. **传输优化(学术检索→工程)**:见 docs/research/transfer-optimization.md(Mathis 方程/并行 TCP 模型/FastCDC/shelf-H2 现状,全引用)。落地:≥8MB 全新下载自动 4 路 Range 并行(交错 A/B 实测 **2.25×**:11.2 vs 5.0 MB/s,5 轮全 sha 校验);缩略图 isolate 解码 1.17×(如实记录,原生解码列 P2)。
3. 修:QR 的 lanIPv4 接口优选(虚拟 172 网段曾排在 WLAN 前);RAF 偏移写陷阱(writeFrom 第二参=缓冲区下标);队列失败日志;串行计时日志。
4. 顺手:上传 64MB 验证对称 ✓;测试 core 49 + server 41 + app 10 = 100 绿。

## 第 6 轮已完成（R6,计划 6 工作流全落地）

1. **WS1 入口正名**：删 spike1 遗迹；「浏览对端文件 / 相册」OutlinedButton 升格
2. **WS2 记忆化配对**：服务端端口持久（重启端口不变，真机×2 验证）+ 配对表落盘（幂等）+ QR 带设备别名；客户端记住最近 10 台设备（chips 一键重连 + 开页静默自动重连）——**重启矩阵 3/3 PASS：双端重启后零操作恢复连接**
3. **WS3 相册脸面**：/thumb（服务端随机 token，结构性防枚举；image 包解码缩放；mtime 键磁盘缓存）+ 相册网格（桶 chips、3 列网格、点按原图走队列、整页后台预取 2 并发）；真机：真实 DCIM 500 张，139 缩略图/75s；原图 pack 下载 3/3 sha 全等
4. **WS4 完整性**：fs/write 回执 sha256（服务端流式哈希；全新上传逐字节比对，续传验长度）；fs/stat 端点；.part/.mlfpart 超龄清理（7 天，深度≤3）
5. **WS5 性能**：MediaService 桶缓存（桶根 mtime 键 + 30s TTL，过滤与缓存解耦）
6. **WS6 三 agent 回归**：相册 E2E（原图 PASS；缩略图 6/20 停滞=懒加载语义→催生预取改进）；对抗轮3 7/8（size 越界/write offset 契约/token 编码已修，R-016）；重启矩阵 3/3 PASS
7. 测试：core 46 + server 41 + queue 10 = **97 全绿**；本轮 7 提交

## 下次会话计划（P1 收尾 → 体验层）

1. **相册浏览 UI**：浏览页接 media/list（桶切换 + 缩略图网格）；/thumb 端点（token 防穿越）
2. **扫码相机真机验证**（需你在场）+ 上游互传验收
3. 队列取消按钮真机、`.part` 超龄清理策略
4. MediaStore 原生通道 vs 目录桶真机 A/B（决定是否值得上平台通道）
5. （可选）正式共享根用户可选（现在 Android=全存储、桌面=Downloads，应做成设置）

## 环境速查（累积更新）

- Flutter `F:\flutter`（3.47.5）；pub 缓存 `F:\PubCache`；gh(`F:\bin\gh.exe`)
- Android SDK `F:\SDK`；adb `F:\SDK\platform-tools\adb.exe`；NDK 28.2；`SKIP_JDK_VERSION_CHECK=1`
- Rust 1.97.1（钉版）+ android 三 target；rsproxy；Gradle 8.14.3 / Kotlin 2.2.20 / AGP 8.12.1
- **构建 APK**：`cd repo/app && PATH+=~/.cargo/bin:/f/flutter/bin ANDROID_SDK_ROOT=F:\SDK RUSTUP_DIST_SERVER=…rsproxy… flutter build apk --debug`
- **部署**：`adb install -r`（MIUI「USB 安装」需开）；debug 包名 `org.localsend.localsend_app.debug`；MANAGE：`adb shell appops set <pkg> MANAGE_EXTERNAL_STORAGE allow`
- **E2E 设施（双向）**：
  - PC 服务：`MLF_AUTO_SERVER=1 MLF_ROOT=<dir>`（日志 `[MLF-PAIRING] {json}`）
  - 手机服务：push `/sdcard/Download/mlf-server.flag` 重启（logcat 同上）
  - 客户端自动配对：Android `/sdcard/Download/mlf-pairing.json`；桌面 `MLF_PAIR_FILE=<file>`
  - 自动传输：Android `mlf-download.json`（{paths,mode}）；桌面 `MLF_DL_FILE` / `MLF_UL_FILE`（{files,targetDir}）
  - 验证一律 `adb logcat -s flutter | grep MLF`（手机）或进程 stdout（PC）
- 手机：Xiaomi 23078RKD5C，Android 15，192.168.3.149；PC 192.168.3.23（WLAN 同段）；防火墙规则已加
- 代理：FlClash `127.0.0.1:7890` 可用（镜像优先）
