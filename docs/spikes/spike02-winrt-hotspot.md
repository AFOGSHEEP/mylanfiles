# Spike 2 NOTES — Dart FFI 调 WinRT 热点 API（雷区 2）

日期：2026-09-30 · 结果：✅ 主路径可行

## 实测数据

| 项 | 结果 |
|----|------|
| PowerShell 直调 WinRT（备选路线） | ✅ 普通权限即达，读出 `TetheringOperationalState=Off`、`SSID=DESKTOP-BM3R9EH 4432`、`Band=Auto` |
| Dart FFI（主路径，win32 5.15.0） | ✅ 同样结果：`TetheringOperationalState = 2 (Off)`、`SSID = DESKTOP-BM3R9EH 4432` |
| 管理员权限 | 不需要 |
| 代码量 | bin/hotspot.dart ~130 行（含 GUID 常量/工具函数） |

## 方法论（可复用于任何 WinRT API）

1. **接口 GUID 与 vtable 槽位从系统自带的 winmd 解析**：
   `C:\Windows\System32\WinMetadata\Windows.Networking.winmd`
   用 Python `dnfile`（pip 清华镜像可装）解析 TypeDef / CustomAttribute / MethodList。
   本 spike 提取的常量：

   | 接口 | GUID | 关键槽位（IUnknown3+IInspectable3 之后） |
   |------|------|------|
   | INetworkInformationStatics | 5074F851-950D-4165-9C15-365619481EEA | 6=GetConnectionProfiles, 7=GetInternetConnectionProfile |
   | INetworkOperatorTetheringManagerStatics2 | 5B235412-35F0-49E7-9B08-16D278FBAA42 | 7=CreateFromConnectionProfile |
   | INetworkOperatorTetheringManager | D45A8DA0-0E86-4D98-8BA4-DD70D4B764D3 | 6=get_MaxClientCount, 7=get_ClientCount, 8=get_TetheringOperationalState, 9=GetCurrentAccessPointConfiguration, 10=ConfigureAccessPointAsync, 11=StartTetheringAsync, 12=StopTetheringAsync |
   | INetworkOperatorTetheringAccessPointConfiguration | 0BCC0284-412E-403D-ACC6-B757E34774A4 | 6=get_Ssid, 7=put_Ssid, 8=get_Passphrase, 9=put_Passphrase |

   `TetheringOperationalState` 枚举：0=Unknown, 1=On, 2=Off, 3=InTransition

2. **win32 包 COMObject 约定**（踩坑后确认，5.15.0）：
   - `ptr.ref.lpVtbl` = 接口对象指针（this，方法首参数传它）
   - `ptr.ref.vtable` = 函数指针数组基址
   - 取槽：`(obj.ref.vtable + n).cast<Pointer<NativeFunction<Sig>>>().value.asFunction<DartSig>()`
   - `RoGetActivationFactory(hstring.value, iid, obj.cast())` —— 第一参数传句柄**值**不是指针
   - **教训**：cast/asFunction 的泛型必须静态写死，不能通过辅助函数传 `NativeFunction` 实例；泛型参数跨行书写会引发解析歧义，win32 包同款单行写法最稳

## 对 B 级决策的影响

- 无动摇。雷区 2 的疑虑（"Dart 无直接 WinRT 绑定"）被实证为**可解**：win32 包基础层 + winmd 自动提取 GUID/槽位即可覆盖，不需要外挂 PowerShell/C# helper（备选路线保留为应急）。
- P2 MagicLink 实现时需补两块：**StartAsync 的 IAsyncOperation 等待**（接 Completed 回调或轮询 IAsyncInfo，预估 0.5–1 天）与 **ConfigureAccessPointAsync**（自定义 SSID/密码/频段，槽位已探明）。

## 复现

```
cd F:\MyLanFiles\spikes\spike02-winrt-hotspot
dart pub get && dart run bin/hotspot.dart   # 需有活动网络连接（GetInternetConnectionProfile 非 null）
```
