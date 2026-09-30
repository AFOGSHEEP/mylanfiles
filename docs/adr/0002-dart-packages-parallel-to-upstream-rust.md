# ADR-0002：新代码走 Dart 包（mylanfiles_core/server），与上游 Rust 平行

- 状态：已接受
- 日期：2026-09-30
- 决策人：项目所有者（对 risks.md R-002 三个选项的拍板：**选 A**）

## 背景

P0 Spike 1 发现上游 LocalSend 的协议层已全部 Rust 化：`packages/core` 是 Rust crate
（crypto/discovery/http/multicast/webrtc），Dart 侧仅剩 UI/provider，经
`packages/localsend_isolates`（flutter_rust_bridge + cargokit）调用。
交接文档"新代码只进 packages/core、packages/server（Dart/shelf）"的路径假设失效。

## 决策（选项 A）

1. 新建 **`packages/mylanfiles_core`**（纯 Dart：协议 DTO、VFS、PathGuard、SearchService、
   通用 FTS5 索引器）与 **`packages/mylanfiles_server`**（shelf + 自签 TLS + §4.1 端点）。
   命名避开上游占用的 `packages/core`。
2. 与上游 Rust 栈**平行共存，互不依赖**：上游 Rust 只服务原互传功能；MyLanFiles 的浏览/
   搜索/传输闭环全部在新 Dart 包内自研。新增页面对接新包，不碰上游 Rust 桥。
3. 依赖方向：`app` → `mylanfiles_server` → `mylanfiles_core`。对上游文件的改动
   遵循 ADR-0001 的微改白名单（root pubspec workspace 列表 + 页面接线）。

## 理由

- 交接文档的全部生态设计（shelf TLS、FTS5 trigram、Everything HTTP、win32 FFI、
  MediaStore 通道、打包流）都是 Dart 侧资产，选 A 零重设计；Spike 2 已实证 Dart FFI
  可覆盖 Windows 原生缺口。
- §16 实测：Dart IO/TLS/SHA 性能远超 Wi-Fi 空口，协议层无需 Rust。
- fork 卫生最佳：新代码 100% 在新目录，upstream merge 冲突面最小。
- 代价（已知悉）：构建产物同时携带 Flutter runtime 与上游 Rust 动态库（体积 +几十 MB）；
  本机需维护 Rust 工具链（P0 已装好，1.97.1 + stable，rsproxy 镜像）。

## 后果

- P1 起步顺序不变（协议 DTO → VFS/PathGuard → server 端点），但落地包名换为
  `mylanfiles_core`/`mylanfiles_server`。
- 上游互传能力与新浏览能力的互通（未来"浏览页直接调上游发送"）走 app 层 provider 组合，
  不建立包级依赖。
- ADR-0001 的挂起项就此关闭。
