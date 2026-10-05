# MyLanFiles

> 局域网文件/相册互览互传——手机与电脑(以及任意 NAS/服务器)在同一个 Wi-Fi 里
> 自动发现、扫码/点选配对、双向高速传输。无需账号、无需外网、数据不出局域网。

基于 [LocalSend](https://github.com/localsend/localsend) fork(桌面/移动壳 + 上游互传能力),
自研协议层为两个纯 Dart 包,与上游 Rust 栈平行共存(见 `docs/adr/0002`)。

## 功能(v0.1.0 demo)

- **自动发现**:UDP 广播,两端打开即见「附近设备」,点一下连接(零配置)
- **安全配对**:自签 TLS + 证书指纹钉住(pin);身份/端口/配对表持久化,重启免配对自动重连
- **浏览**:对端文件树(虚拟路径,不泄露主机布局)+ 相册缩略图网格(DCIM/Pictures 等桶)
- **下载**:大文件自动 4 路并行 Range(实测 2.25×);打包流(小文件批量,skip 断点只补缺);断点续传
- **上传**:远端暂存 + 原子落名 + 断点;服务端回执 sha256 全量校验
- **传输队列**:进度/取消/失败自动退避重试
- **无头服务器** `mlf-serve`:单二进制把任意机器的一个目录变成共享端(NAS/Linux/Windows/macOS)

## 快速开始

下载 demo 三件套(Android APK / Windows 免安装包 / mlf-serve 单二进制)与 60 秒上手指南:
见 `demo/README-快速开始.md`(或项目外层 `F:\MyLanFiles\demo\`)。

源码构建:

```sh
# Android / Windows App
cd app && flutter build apk --release     # 需 android/key.properties(见 android/README 未含,参考 Flutter 文档)
cd app && flutter build windows --release

# 无头服务器(各自平台)
cd packages/mylanfiles_server && dart compile exe bin/serve.dart -o mlf-serve
```

## 架构

```
repo/
├─ app/                    # Flutter 应用(fork 自 LocalSend;自研页面在 lib/pages/mylanfiles*)
├─ packages/
│  ├─ mylanfiles_core/     # 纯 Dart:协议 DTO、VFS、PathGuard(路径安全生命线)、
│  │                       #   打包流编解码、设备发现
│  └─ mylanfiles_server/   # 纯 Dart:shelf + 自签 TLS、§4.1 全部端点、缩略图、
│                          #   双限速器、MlfClient(协议对端)、bin/serve.dart 无头服务器
└─ docs/                   # 协议、决策、风险、研究笔记、轮计划(status.md 是会话入口)
```

关键决策与文档:`docs/adr/0002`(与上游 Rust 平行的 Dart 包)、
`docs/MyLanFiles_开发交接文档.md`(协议 §4 / 安全 §7)、`docs/risks.md`(不确定性登记,
含实测数据)、`docs/research/transfer-optimization.md`(传输算法的数学依据与文献)。

## 协议(§4.1 摘要)

自签 HTTPS + `x-mlf-fingerprint` 指纹头;未配对 403 且双限速(业务/配对分离,扫码恢复永不锁死)。

```
POST /api/v1/pair                 GET  /api/v1/fs/list?path=
GET  /api/v1/fs/read?path=&offset=&length=      PUT /api/v1/fs/write?path=&offset=   (回执 sha256)
GET  /api/v1/fs/stat?path=        POST /api/v1/fs/op        {op: copy|move|delete|rename|mkdir}
GET  /api/v1/media/list?bucket=&type=&since=&limit=&offset=  (条目携带防枚举缩略图 token)
GET  /api/v1/thumb?token=&size=   POST /api/v1/pack          {items, skip} → 连续帧流
```

路径语义:`/`=共享根(虚拟路径);PathGuard 保证一切输入无法逃出共享根(穿越/UNC/盘符注入
均被结构化拦截,3 轮对抗测试)。

## 状态与质量

- 真机双向矩阵全绿(Xiaomi/Android 15 ↔ Windows 11,真实 Wi-Fi,sha256 全量校验)
- 单元/集成测试:core 49 + server 41 + app 10 = **100 全绿**
- 三轮独立 agent 对抗测试(协议健壮性/路径安全/限速语义),发现的问题全部修复并带回归测试
- 性能实测:64MB 并行 11.2MB/s(串行 5.0);打包流 vs 逐文件 2.95×;缩略图 0.46s/张

## 路线图(摘要)

正式签名与体积优化、iOS/macOS/Linux 官方构建、i18n 接入上游翻译、HEIC 缩略图、
原生解码缩略图(预期 10×+)、块级增量同步(FastCDC,已调研)、FTS5 搜索、QUIC 传输。

## 许可

遵循上游 LocalSend 的许可证(agpl-3.0,见 LICENSE);自研包同样 AGPL-3.0。
