# 项目状态（docs/status.md）

> **新会话快速上手（给 AI 的引导，读完本文件即可开工，无需重读全部历史）**
> - 角色与协议：你是 MyLanFiles 的开发代理，遵守 `docs/MyLanFiles_开发交接文档.md` 的 §2.5（不确定性管理）与 §9（工作约定）；配套深度背景 `docs/MyLanFiles_可行性报告与开发计划.md` 按需查阅。
> - 一切以本文件「当前阶段 / 下次会话计划 / 待确认」三节为准；风险与雷区见 `docs/risks.md`；关键决策见 `docs/adr/0001`、`0002`。
> - 环境/镜像/构建命令：本文件末尾「环境速查」一节。全程不开代理。
> - 边界：不推 GitHub（决策人叫停，交接命令备好）；不开始 P2；B 级方向性决策被动摇时停下汇报。

> 每次会话结束更新。结构：当前阶段 / 已完成 / 下一步 / 待决策人确认事项。

- 更新：2026-10-01（P1 第 2 次会话——TLS+二维码配对 / 打包流进浏览页 / 传输队列）
- 本机项目根：`F:\MyLanFiles`
- 正式仓库：`F:\MyLanFiles\repo`（分支 `feat/p1-vfs-server`，本地提交待推送）

## 当前阶段

**P1 — 浏览/传输闭环（Dart 侧）**。同机链路已全部打通且经测试：https 自签 TLS + 指纹 pin 配对 + 二维码 + 打包流（skip 断点）+ 传输队列/进度。**下一里程碑是真机联调**（手机扫 QR + LAN 互访 + Range 大文件断点），需决策人在场。

## 第 3 次会话已完成（P1 计划项 1/2/3）

1. **TLS 真接（服务端+客户端）**：
   - `tls_context`：指纹定义改为 **SHA-256 over DER**（客户端可从 TLS 握手的 `X509Certificate.der` 直接重算比对，无需 PEM 重包装）；`loadOrCreateIdentity` 身份持久化（`tls_identity.json`，存应用私有目录——共享根之外），QR 指纹跨重启稳定
   - `MlfClient`（server 包新模块，协议对端）：**pin 握手**（证书指纹 ≠ QR 指纹 → 握手直接失败）、pair/list/read/pack、字节计数 tee（进度 UI 用）
   - `MlfPairingInfo`：QR 载荷 `{v:1,proto:"mlf",ip,port,fp}`，JSON 或裸 URL 均可解析
2. **二维码配对**：浏览页服务端改绑 anyIPv4 + TLS，LAN 地址入 QR；QR 弹窗用上游同组件 `pretty_qr_code` 自建（ADR-0002，不碰上游 i18n/refena 外壳）；客户端粘贴 QR JSON → pin → pair → 浏览；「本机演示」一键 loopback 自连
3. **打包流进浏览页**：多选文件 → §4.2 自适应（中位 <2MiB 走 pack，否则逐文件）→ 客户端 `PackStreamReader` 解包落盘，**逐帧 SHA-256 落盘复核**；skip 断点 = 收件箱同名同尺寸文件的 sha 集合（内容寻址，重传只补缺）
4. **传输队列 + 进度 UI**：`TransferQueue`（串行执行、节流进度通知、失败重试、清已完成）；单文件 **Range 断点**（`.part` 落盘，失败保留，重试从 offset 续传）；队列面板（每任务进度条/状态/重试）
5. **雷 R-007 修复**：FRB codegen 2.12.0 vs runtime 2.13.0 漂移（上游互传运行期全废，P0 真机验收会撞上）→ pin 2.12.0 + lock 重解析，冒烟 0 init 错误（详见 risks.md R-007）
6. **验证**：server 包 26 测试 + app 队列 7 测试全绿；analyze 0 问题；`flutter build windows --debug` 通过；exe 冒烟 10s 不崩且无 init 错误
7. 本地提交 4 个：`feat(server)` 客户端对端+TLS 身份 / `fix(deps)` FRB pin / `feat(app)` 浏览页 TLS+QR+打包+队列 / `docs` 检查点

## 踩雷记录（本次）

| 雷 | 处置 |
|----|------|
| FRB 版本漂移（R-007）：上游 `^2.12.0` caret 放进 2.13.0，生成代码是 2.12.0 的 → Rust 桥 init SEVERE、互传功能运行期全废 | 精确 pin 2.12.0；教训入 risks.md：**凡提交生成代码的包，依赖约束一律精确 pin** |
| basic_utils 的 PEM 标记行无空格（`-----ENDCERTIFICATE-----`）+ CRLF → base64 严格解码炸 | `pemToDer` 压平后正则剥标记行 |
| `pack` 端点对绝对路径 `/a.txt` 返回 403（Windows 解析到盘符根，PathGuard 拦截，行为正确） | 客户端统一用 `list` 返回的 entry.path（根内归一化绝对路径） |
| 身份持久化首版用换行分隔符拼 certPem/key，certPem 无尾换行 → 拆分失效静默重新生成 | 改 JSON 文件存储 |

## 待决策人确认事项

### 1. GitHub 推送（仍暂停，命令保留备用）

```
F:\bin\gh.exe auth login --hostname github.com
# 选 HTTPS → Login with a web browser → 浏览器输设备码
```

完成后我接手：fork localsend/localsend → 改名 mylanfiles → 设 origin → push `feat/p0-baseline` + `feat/p1-vfs-server` → 开 PR → main 分支保护。

### 2. 真机联调（下次会话核心，需你在场）

- 手机插入（USB 调试）→ 上游 App 双端互传一次（R-007 已修，此项恢复可测）
- 防火墙为 debug exe 放行（§8 坑 1，可能弹 UAC/放行框）→ 手机浏览器/同 app 扫 QR → https 浏览 + 打包传输
- 大文件中断 → Range 断点续传演示

## 下次会话计划（P1 继续）

1. **真机联调**（见上）：Android 端扫码（camera 权限+移动端 QR 扫描页，桌面端粘贴过渡）、LAN 防火墙、真机打包流 A/B 实测（雷区 #5：29× 增益假设）
2. **传输健壮化**：队列任务取消按钮；`.part` 大于远端文件时（远端缩小）自动重置重传；pairing 过期（服务端重启后 403）自动重配对
3. **Android 侧**：MANAGE 权限引导页 + MediaStore 快路径（等真机）
4. （GitHub 推送随时可恢复）

## 环境速查（累积更新）

- Flutter `F:\flutter`（3.47.5）；pub 缓存 `F:\PubCache`；melos、gh(`F:\bin\gh.exe`)
- Android SDK `F:\SDK`；adb `F:\SDK\platform-tools\adb.exe`
- Rust：stable 1.98.1 + 1.97.1（上游钉版）；`~/.cargo/config.toml` 已配 rsproxy
- **构建 LocalSend 的环境变量**（bash）：`PATH+=~/.cargo/bin`，`RUSTUP_DIST_SERVER=https://rsproxy.cn`，`RUSTUP_UPDATE_ROOT=https://rsproxy.cn/rustup`，PUB/FLUTTER 镜像，`ANDROID_SDK_ROOT=F:\SDK`
- 项目：`F:\MyLanFiles`（docs/ + spikes/ + repo/）
- 上游代码两份：`spikes\spike01-localsend-page\upstream`（已构建✅，探针页）、`repo`（正式仓库，同补丁）
- 约束：全程无代理
