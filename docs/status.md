# 项目状态（docs/status.md）

> **新会话快速上手（给 AI 的引导，读完本文件即可开工，无需重读全部历史）**
> - 角色与协议：你是 MyLanFiles 的开发代理，遵守 `docs/MyLanFiles_开发交接文档.md` 的 §2.5（不确定性管理）与 §9（工作约定）；配套深度背景 `docs/MyLanFiles_可行性报告与开发计划.md` 按需查阅。
> - 一切以本文件「当前阶段 / 下次会话计划 / 待确认」三节为准；风险与雷区见 `docs/risks.md`；关键决策见 `docs/adr/0001`、`0002`；轮计划见 `docs/plan-*.md`。
> - 环境/镜像/构建命令：本文件末尾「环境速查」一节。代理已放开（见速查）。
> - 边界：不推 GitHub（决策人叫停，交接命令备好）；不开始 P2；B 级方向性决策被动摇时停下汇报。测试阶段按决策人指示用**多个独立 agent 跑多轮独立测试**。

> 每次会话结束更新。结构：当前阶段 / 已完成 / 下一步 / 待决策人确认事项。

- 更新：2026-10-04（P1 第 5 轮——双向闭环：上传/反向主场景/虚拟路径/相册端点/健壮化，计划见 docs/plan-p1-round5.md）
- 本机项目根：`F:\MyLanFiles`
- 正式仓库：`F:\MyLanFiles\repo`（分支 `feat/p1-vfs-server`，本地 20+ 提交待推送）

## 当前阶段

**P1 — 双向闭环达成**。产品两个方向都真机全绿：手机↔PC 任一端做服务端/客户端，配对(TLS pin)/浏览/下载(打包流+skip+Range)/上传(原子落名+断点) 全部经独立 agent 多轮验证（sha256 全等）。**「可用成品」的核心传输闭环已完成**；剩余为体验层（相册 UI 入口、缩略图、扫码相机真机验证）与上游互传验收章。

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
