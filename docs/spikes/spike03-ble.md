# Spike 3 NOTES — Windows BLE 扫描 PoC（雷区 3）

日期：2026-09-30 · 结果：⚠️ 部分（调研+依赖解析+analyze ✅；运行验证被 VS BuildTools 阻塞）

## 调研结论（2026-09 实查）

| 项 | 结论 |
|----|------|
| flutter_blue_plus 本体 | 只覆盖 Android/iOS/macOS，**不含 Windows** |
| **官方 Windows 路径** | [flutter_blue_plus_windows](https://pub.dev/packages/flutter_blue_plus_windows)（v1.26.1，基于 win_ble，MIT）——维护者在 [issue #6](https://github.com/chipweinberger/flutter_blue_plus/issues/6) 明确："flutter_blue_plus_windows is now the official package for windows support" |
| 用法 | **零 API 改动**：`import 'package:flutter_blue_plus/flutter_blue_plus.dart' hide FlutterBluePlus;` + `import 'package:flutter_blue_plus_windows/...';`，其余 FBP 代码原样跑（README 模式，无额外初始化） |
| 备选 | flutter_blue_ultra（dotintent，更广桌面覆盖）；flutter_reactive_ble 的 Windows 支持仍是 open issue |

## 实证

1. **依赖解析成功**：`flutter_blue_plus 1.34.5 + flutter_blue_plus_windows 1.26.1 + win_ble` 在 Dart 3.13.4 / Flutter 3.47.5 下无版本冲突（pub get 一次通过）。
   —— 消解了"wrapper 停更 19 个月可能与新 FBP 不兼容"的疑虑（1.34.5 比 wrapper 发布时间新，仍解析通过）。
2. **analyze 通过**：扫描/连接/服务发现/notify 订阅/20 字节写入的完整代码路径编译无误。唯一 info 是"FBP 本体 import 冗余"——侧面证明 **wrapper 完整 re-export 了 FBP 全部 API**（覆盖度证据）。
   注：新版 FBP 的 `ScanResult` 上 `platformName`/`remoteId` 需经 `r.device.xxx` 访问（API 微调，非 Windows 特有）。
3. **未验证**（等 VS C++ BuildTools + 本机蓝牙适配器 + 一台 BLE 外设/手机）：
   - Windows 上真实扫描出广播包
   - 连接后 20 字节 notify/write 收发

## 对 B 级决策的影响

- **无动摇，且降险**：雷区 3 原担忧"flutter_blue_plus 等对 Windows central 支持不完整"→ 实查存在官方 endorsed 的 Windows 封装，API 零改动。
- 魔连（MagicLink）BLE 引导层的技术选型可以落在 **flutter_blue_plus + flutter_blue_plus_windows 组合**；备选路线（纯二维码降级）保留但预期无需启用。
- P2 实现时的两个注意点：wrapper 停更 19 个月（若 FBP 大版本破坏性升级需 fork wrapper 或锁版本）；Windows 蓝牙栈要求适配器支持 LE（现代机器基本满足，真机清单实测时顺带记录）。

## 复现

```
cd F:\MyLanFiles\spikes\spike03-ble\ble_scan
dart pub get && dart analyze   # 预期：仅 1 个 unnecessary_import info
flutter run -d windows         # 需 VS C++ BuildTools（待装）+ 蓝牙适配器
```
