# MyLanFiles

**Browse and move files between your phone and computer over your own Wi-Fi — no account, no cloud, no internet.**

[English](#english) · [中文](#中文)

---

## English

MyLanFiles turns every device on your LAN into both a server and a client: open the app on two machines and they find each other automatically (UDP broadcast), pair with a single tap (self-signed TLS with certificate fingerprint pinning), and then you can browse the other side's file tree and photo albums, and transfer in both directions with resumable, verified, multi-stream transfers.

Built as a fork of [LocalSend](https://github.com/localsend/localsend) — keeping its polished shell and its device-to-device sharing, while adding a parallel pure-Dart protocol stack (see [docs/adr/0002](docs/adr/0002-dart-packages-parallel-to-upstream-rust.md)) for browsing, albums and high-speed transfer.

### Features (v0.1.0)

- **Zero-configuration discovery** — devices announce themselves on the LAN; tap "nearby device" to connect. No QR gymnastics required for everyday use.
- **Security that doesn't get in the way** — self-signed TLS, fingerprint pinned at pairing (same trust model as scanning a QR); identity/port/pairings persist, so restarts reconnect silently; two-tier rate limiting keeps brute-force out without ever locking the scan-to-recover path.
- **Browse** — full virtual-path file tree (host layout never leaks) plus a photo-album grid with server-rendered thumbnails (random unguessable tokens).
- **Fast downloads** — files ≥8 MB automatically split into 4 parallel range streams (measured 2.25× on real Wi-Fi); smaller batches go through a packed stream with content-addressed skip (only missing files travel); everything resumable at file or byte level.
- **Verified uploads** — the server returns a streaming sha256 receipt; the client compares and deletes on mismatch. Atomic landing via staged `.mlfpart` + rename.
- **Headless server** — `mlf-serve`, a single ~10 MB binary, turns any directory on any machine (NAS/Linux/Windows/macOS) into a discoverable share.

### Quick start

Grab the demo kit (Android APK / Windows portable zip / mlf-serve) from the [v0.1.0 release](../../releases), or build from source:

```sh
cd app && flutter build apk --release      # Android (needs android/key.properties, falls back to debug signing if absent)
cd app && flutter build windows --release  # Windows
cd packages/mylanfiles_server && dart compile exe bin/serve.dart -o mlf-serve   # headless server, any desktop OS
```

### Architecture

```
repo/
├─ app/                    # Flutter app (LocalSend shell + MyLanFiles pages)
├─ packages/
│  ├─ mylanfiles_core/     # pure Dart: VFS, PathGuard (path-safety lifeline),
│  │                       #   packed-stream codec, UDP discovery
│  └─ mylanfiles_server/   # pure Dart: shelf + self-signed TLS, all §4.1
│                          #   endpoints, thumbnails, dual rate limiters,
│                          #   MlfClient (protocol peer), bin/serve.dart
└─ docs/                   # protocol, decisions, risks, research notes
```

Protocol summary (§4.1): self-signed HTTPS + `x-mlf-fingerprint` header; unpaired requests get 403 with rate limiting. `/` in any path means the *share root* — host paths are never addressable, so traversal is structurally impossible (three adversarial test rounds).

### Quality

- 101 unit/integration tests green; full matrix verified on real devices (Android 15 ↔ Windows 11 over real Wi-Fi, sha256-verified end to end)
- Three independent adversarial test rounds (protocol robustness, path security, rate-limit semantics) — every finding fixed with regression tests
- Measured: 64 MB parallel download 11.2 MB/s (serial 5.0, 2.25×); packed stream 2.95× vs per-file; thumbnails 0.46 s each
- Development write-up: [blog/2026-10-05-the-journey.md](blog/2026-10-05-the-journey.md)

### Roadmap

Proper release signing & APK size split, iOS/macOS/Linux official builds, i18n via upstream translations, HEIC thumbnails, native thumbnail decoding (10×+), block-level incremental sync (FastCDC, researched), FTS5 search, QUIC transport.

### License

Apache-2.0 (inherited from LocalSend, see LICENSE and NOTICE).

---

## 中文

**在你自己的 Wi-Fi 里,手机和电脑互相浏览、互相传文件——无需账号、无需云端、不联网。**

MyLanFiles 让局域网里的每台设备既是服务端又是客户端:两台机器各打开应用,自动互相发现(UDP 广播),点一下「附近设备」即完成配对(自签 TLS + 证书指纹钉住),然后浏览对端的文件树与相册,双向传输,断点续传,全程校验。

基于 [LocalSend](https://github.com/localsend/localsend) fork——保留其成熟的壳与设备互传能力,新增一套平行的纯 Dart 协议栈(见 [docs/adr/0002](docs/adr/0002-dart-packages-parallel-to-upstream-rust.md))承担浏览、相册与高速传输。

### 功能(v0.1.0)

- **零配置发现**:设备在局域网自动宣告,点「附近设备」直连,日常使用无需扫码贴 JSON
- **不添乱的安全**:自签 TLS、配对即指纹钉住(与扫码同一信任模型);身份/端口/配对持久化,重启静默重连;双限速器防爆破,但扫码恢复路径永不锁死
- **浏览**:虚拟路径文件树(不泄露主机盘符)+ 相册缩略图网格(服务端随机 token,结构性防枚举)
- **高速下载**:≥8MB 自动 4 路并行分块(真机实测 2.25×);小文件批量走打包流 + 内容寻址 skip(只传缺失);文件级/字节级断点续传
- **可校验上传**:服务端流式 sha256 回执,客户端比对不符即删;`.mlfpart` 暂存 + 原子改名落盘
- **无头服务器** `mlf-serve`:约 10MB 单二进制,把任意机器(NAS/Linux/Windows/macOS)的任意目录变成可发现的共享端

### 快速开始

从 [v0.1.0 release](../../releases) 下载演示三件套(Android APK / Windows 免安装包 / mlf-serve),或源码构建:

```sh
cd app && flutter build apk --release      # Android(需 android/key.properties,缺失时回退 debug 签名)
cd app && flutter build windows --release  # Windows
cd packages/mylanfiles_server && dart compile exe bin/serve.dart -o mlf-serve   # 无头服务器
```

### 架构

```
repo/
├─ app/                    # Flutter 应用(LocalSend 壳 + MyLanFiles 页面)
├─ packages/
│  ├─ mylanfiles_core/     # 纯 Dart:VFS、PathGuard(路径安全生命线)、
│  │                       #   打包流编解码、UDP 发现
│  └─ mylanfiles_server/   # 纯 Dart:shelf + 自签 TLS、§4.1 全端点、缩略图、
│                          #   双限速器、MlfClient(协议对端)、bin/serve.dart
└─ docs/                   # 协议、决策、风险、研究笔记
```

协议摘要(§4.1):自签 HTTPS + `x-mlf-fingerprint` 指纹头;未配对请求 403 且限速。路径中的 `/` 一律指**共享根**——主机路径不可寻址,穿越被结构性排除(经三轮对抗测试)。

### 质量

- 101 个单元/集成测试全绿;真机全矩阵验证(Android 15 ↔ Windows 11,真实 Wi-Fi,端到端 sha256 校验)
- 三轮独立对抗测试(协议健壮性/路径安全/限速语义),发现项全部修复并带回归测试
- 实测:64MB 并行下载 11.2MB/s(串行 5.0,2.25×);打包流对逐文件 2.95×;缩略图 0.46 秒/张
- 开发全程记录:[blog/2026-10-05-the-journey.md](blog/2026-10-05-the-journey.md)

### 路线图

正式签名与 APK 体积拆分、iOS/macOS/Linux 官方构建、i18n 接入上游翻译、HEIC 缩略图、原生解码缩略图(10×+)、块级增量同步(FastCDC,已调研)、FTS5 搜索、QUIC 传输。

### 许可

Apache-2.0(继承自 LocalSend,见 LICENSE 与 NOTICE)。
