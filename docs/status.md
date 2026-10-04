# 项目状态（docs/status.md）

> **新会话快速上手（给 AI 的引导，读完本文件即可开工，无需重读全部历史）**
> - 角色与协议：你是 MyLanFiles 的开发代理，遵守 `docs/MyLanFiles_开发交接文档.md` 的 §2.5（不确定性管理）与 §9（工作约定）；配套深度背景 `docs/MyLanFiles_可行性报告与开发计划.md` 按需查阅。
> - 一切以本文件「当前阶段 / 下次会话计划 / 待确认」三节为准；风险与雷区见 `docs/risks.md`；关键决策见 `docs/adr/0001`、`0002`。
> - 环境/镜像/构建命令：本文件末尾「环境速查」一节。代理已放开（见速查）。
> - 边界：不推 GitHub（决策人叫停，交接命令备好）；不开始 P2；B 级方向性决策被动摇时停下汇报。

> 每次会话结束更新。结构：当前阶段 / 已完成 / 下一步 / 待决策人确认事项。

- 更新：2026-10-04（P1 第 3 次会话——真机 E2E 全绿：TLS 配对/浏览/打包流/skip/Range 断点）
- 本机项目根：`F:\MyLanFiles`
- 正式仓库：`F:\MyLanFiles\repo`（分支 `feat/p1-vfs-server`，本地提交待推送）

## 当前阶段

**P1 — 真机闭环达成**。手机（Xiaomi 23078RKD5C / Android 15 / arm64）与 Windows PC 在真实 Wi-Fi 上完成了 MyLanFiles 全功能矩阵：TLS 指纹 pin 配对、目录浏览、单文件下载（64MB 实测 2.7MB/s）、Range 断点续传、打包流 + 逐帧 sha 校验、内容寻址 skip 断点。**核心传输链路已是"可用成品"水平**；剩余为扫码 UI 真机验证、上游互传验收、A/B 正式测速、MediaStore 快路径。

## 第 4 次会话已完成（真机联调 + 多 agent 独立测试）

**测试方法论（决策人指示）**：测试阶段由多个独立 agent 执行多轮独立测试——本轮 4 个 agent：真机打包轮 / 真机逐文件轮（串行，单手机约束）/ PC 对抗协议轮（并行）/ 完整性校验轮。全部 PASS。

1. **Android 构建链从零打通**：NDK 28.2（sdkmanager，Java 版本串检查要 `SKIP_JDK_VERSION_CHECK=1`）+ Rust 三 ABI 交叉编译（armv7/arm64/x86_64，rsproxy）+ Gradle 8.13→8.14.3 + Kotlin 2.2.0→2.2.20（Flutter 3.47 最低要求）；首次 APK 867s，增量 ~90s
2. **真机部署**：MIUI「USB 安装」拦一道（决策人开了开关+点了弹窗）；debug 包名带 `.debug` 后缀；MANAGE 经 `adb shell appops set ... MANAGE_EXTERNAL_STORAGE allow` 免 UI 授予
3. **MyLanFiles 真机 E2E 矩阵全绿**（真实 Wi-Fi 192.168.3.x + 自签 TLS + 指纹 pin）：
   - 配对/列目录（手机 → PC，4 条目）
   - 单文件 64MB：24.6s ≈ 2.7MB/s，`.part` 原子改名
   - **Range 断点**：意外（app 重启打断产生 .part）+ 刻意（30MB .part → `@offset=31457280` → 3.5s 完成）双验证
   - **打包流**：3 文件帧解码+sha 复核+落盘；**skip 断点**：`+1 skipped=2`（补缺）→ `+0 skipped=3`（全跳过零流量）
4. **A/B 测速（雷区 #5 落袋，R-012）**：100×50KB，打包流 2790ms（27.9ms/文件）vs 逐文件 8216ms（82.2ms/文件）= **2.95×**；sha256 全量 100/100 一致；每请求开销 ≈54ms（Wi-Fi RTT 主导，29× 假设量级不符但方向正确）
5. **对抗性协议测试 12/12**（独立 agent，PC loopback）：中文/emoji 文件名、空文件、offset 边界（==size/​>size/负值）、空 pack、全 skip、未配对 403×5→429、路径穿越三连（403）、8 并发、10MB 尾字节；**新发现 R-013（虚拟路径语义）与 R-014（黑名单挡 /pair）**
6. **E2E 无人值守设施**（dev 专用，文件/env 门控）：`MLF_AUTO_SERVER=1`+`MLF_ROOT`（桌面自动开服务+配对日志）；`mlf-pairing.json`+`mlf-download.json`（支持 mode:pack/sequential 与子目录 basename 匹配）；`[MLF]` 日志面包屑
7. **新功能**：相机扫码页（mobile_scanner，仅移动端）、MANAGE 引导卡、任务取消（保留断点）、`.part` 越界重置、403 自动重配对重试、防火墙规则（UAC 已批）
8. 78 个单测全绿（server 26 + core 44 + queue 8）；本地提交 7 个

## 踩雷记录（本次，详见 risks.md）

| 雷 | 处置 |
|----|------|
| MIUI USB 安装弹窗 10s 超时 + 默认禁用 | 决策人开「USB 安装」；弹窗需在场点掉 |
| sdkmanager 拒认本机 JDK 版本串（17+35-LTS） | `SKIP_JDK_VERSION_CHECK=1` |
| Gradle/Kotlin 低于 Flutter 3.47 最低版 | 8.14.3 / 2.2.20（fork 内可上游化） |
| 上游互传链路的 FRB 版本漂移（上次会话 R-007） | 已修；本次真机互传可测 |
| `grep -c` 计数 0 时退出码 1 断了 `&&` 链 | 构建静默未跑，浪费一轮；改用显式判断 |
| 截图 CDN 撞名返回旧图 + 视觉坐标精度 ±30% | 放弃像素驱动，改 logcat 面包屑闭环（方法论沉淀） |
| Git Bash 把 `/storage/...` 设备路径改写为本机路径 | `MSYS_NO_PATHCONV=1` |

## 待决策人确认事项

### 1. 需要你在场的 10 分钟（ anytime ）

- **扫码配对真机**：手机 app 浏览页 → 扫码按钮 → 对准 PC 屏幕上的二维码（相机链路 + ML Kit 在国产 ROM 的表现，我无法替你拍屏幕）
- **P0 验收：上游互传**：手机「发送」页已能看到 PC（发现互通已验证）；选个文件发 PC，PC 弹接收框时点一下允许（PC 端确认框我点不了）
- 顺手：手机相册选张图发 PC（上游 saveToGallery 反向）

### 2. GitHub 推送（仍暂停，命令保留备用）

```
F:\bin\gh.exe auth login --hostname github.com
```

## 下次会话计划（P1 收尾）

1. **R-013 修复**：协议虚拟路径语义（`/`=根，list 返回根内路径，主机布局不泄露）——对抗 agent 发现的协议不一致
2. **MediaStore 快路径**（§4.1 media/list 端点 + 相册桶浏览）——真机在手可开发验证
3. **传输健壮化补充**：取消按钮真机验证、`.part` 清理策略、断网自动重试退避；R-014 黑名单语义等产品定调
4. **上游互传验收 + 扫码真机**（等上面 10 分钟窗口）
5. （GitHub 推送随时可恢复）

## 环境速查（累积更新）

- Flutter `F:\flutter`（3.47.5）；pub 缓存 `F:\PubCache`；melos、gh(`F:\bin\gh.exe`)
- Android SDK `F:\SDK`；adb `F:\SDK\platform-tools\adb.exe`；**NDK 28.2.13676358 已装**；`SKIP_JDK_VERSION_CHECK=1`（sdkmanager）
- Rust：stable 1.98.1 + 1.97.1（钉版）+ android targets（aarch64/armv7/x86_64）；`~/.cargo/config.toml` 走 rsproxy
- **构建 Android APK**（bash）：`cd repo/app && PATH+=~/.cargo/bin:/f/flutter/bin ANDROID_SDK_ROOT=F:\SDK RUSTUP_DIST_SERVER=https://rsproxy.cn RUSTUP_UPDATE_ROOT=https://rsproxy.cn/rustup flutter build apk --debug`
- **真机部署**：`adb install -r`（MIUI 需「USB 安装」开）；debug 包名 `org.localsend.localsend_app.debug`；MANAGE：`adb shell appops set org.localsend.localsend_app.debug MANAGE_EXTERNAL_STORAGE allow`
- **E2E 设施**：PC 端 `MLF_AUTO_SERVER=1 MLF_ROOT=<dir>` 起服务（日志 `[MLF-PAIRING] {json}`）；手机推 `/sdcard/Download/mlf-pairing.json` + `mlf-download.json` 重启即自动配对+下载；验证走 `adb logcat -s flutter | grep MLF`
- 项目：`F:\MyLanFiles`（docs/ + spikes/ + repo/）；测试根 `F:\mlf-e2e-root`
- 代理：FlClash `127.0.0.1:7890` 可用（2026-10-04 决策人放开；镜像优先不动）
- 手机：Xiaomi 23078RKD5C（Redmi/K60e 系），Android 15，屏 1220×2712，Wi-Fi 192.168.3.x 与 PC 同网段；PC 192.168.3.23
