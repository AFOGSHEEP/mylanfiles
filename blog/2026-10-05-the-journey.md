# 从 fork 到多端 Demo:MyLanFiles 六天开发实录

> **EN abstract** — This post documents the six-day build of MyLanFiles: a LAN file/photo browser
> and transfer tool forked from LocalSend, with a parallel pure-Dart protocol stack alongside
> the upstream Rust core. It covers the architecture bet that made the fork mergeable, a
> math-driven transport optimization (Mathis equation → 4-stream parallel download, measured
> 2.25×), a multi-agent testing methodology that caught real vulnerabilities, and the
> headless single-binary server that makes it deployable anywhere. 101 tests, three
> adversarial rounds, everything verified on real devices over real Wi-Fi.

六天,49 个提交,一个能跑的多端 Demo。这篇文章记录全过程——包括踩过的雷、
做对的赌注、以及一套被验证有效的「AI 代理开发方法论」。

## 为什么造这个轮子

需求很简单:电脑想看手机里的照片和文件,想快速拉过来。现有方案要么走云
(慢、隐私焦虑),要么是 filebrowser 这类网页文件管理器(逐文件下载、没有相册、
移动端体验差)。LocalSend 解决了「互传」但解决不了「浏览」——它没有文件树、
没有相册、没有断点续传。

所以目标定为:**局域网内的文件/相册互览互传,无账号、无云端、可多端部署**。

## 第一个赌注:平行架构,不做侵入

fork 下来第一周就发现一个文档没预料到的事实:上游 LocalSend 的协议层已经
**全面 Rust 化**(packages/core 是 75 个 .rs 文件的 crate,经 flutter_rust_bridge
调用)。交接文档假设的「新代码写进 packages/core(Dart/shelf)」已不成立。

两个选项:跟着写 Rust(放弃 Dart 生态的全部既有设计,学习成本高),或者
**平行共存**——新建 `mylanfiles_core`/`mylanfiles_server` 两个纯 Dart 包,
与上游 Rust 互不依赖,各自服务各自的功能。

选了后者(ADR-0002)。六天后回看,这个决定的价值远超预期:
- fork 卫生:新代码 100% 在新目录,与上游 merge 的冲突面缩到 20 个文件的接线级改动
- 自由度:Dart 生态的 shelf/crypto/image 直接用,不需要桥接层
- 附赠红利:协议层是纯 Dart,意味着可以 `dart compile exe` 出**单二进制无头服务器**
  ——后来成了多端部署的关键件

## 垂直切片:每周打通一条端到端路径

不横向铺功能,每轮只打通最细一条链路:

1. **第 1-2 轮**:PathGuard(路径安全生命线,17 个表驱动测试)→ shelf 服务器 →
   6 个端点 → 浏览页。同机自连跑通的那一刻,项目从「想法」变成「东西」。
2. **第 3 轮**:TLS 真接(自签证书 + 指纹 pin)+ 二维码配对 + 打包流 + 传输队列。
   这里踩了第一个大雷:flutter_rust_bridge 版本漂移让上游互传静默瘫痪——
   冒烟测试抓到的,不是功能测试。
3. **真机轮**:Android 构建链从零打通(NDK + Rust 三 ABI 交叉编译),真机全矩阵
   绿:配对/浏览/64MB 下载/断点/打包流/skip。
4. **双向轮**:上传通道(原子落名 + 断点 + sha256 回执)、反向主场景
   (PC 当客户端连手机)、协议虚拟路径语义修正。
5. **体验轮**:入口正名、记忆化配对(重启零操作重连)、相册网格 + 缩略图。
6. **demo 轮**:release 三件套 + 无头服务器 + 完备性审计。

## 传输优化:数学说了算

用户问「传输算法还能不能优化」时,我们先去查了文献而不是先写代码。

**单流为什么慢?** Mathis 方程:T ≈ (MSS/RTT)·(1.22/√p)。Wi-Fi 的非拥塞丢包
(干扰、衰落)被 TCP 误判为拥塞而降窗——单流吞吐被 RTT×√p 乘积锁死。
实测单流 5MB/s,不是带宽不够,是数学惩罚。

**解法**:4 路并行 Range GET。每条连接独立拥塞窗口,聚合吞吐≈k×单流直到空口
饱和(Microsoft 2005 年的并行 TCP 模型、Alrshah 2016 实测都支持)。服务端
offset+length 零改动,客户端 60 行。

**交错 A/B 实测**:并行均值 11.2MB/s vs 串行 5.0MB/s = **2.25×**,五轮全部
sha256 校验。低于理论 4× 恰恰符合模型——空口竞争饱和,增益递减。

小文件批量走另一条路:打包流(单流连续帧)对逐文件请求 **2.95×**——每请求
54ms 的 RTT 开销被摊销为零。为什么不用 HTTP/2 多路复用?shelf 没有原生 H2,
而且 H2 单连接在丢包链路上仍受单流限制——并行分块是数学上更直接的解。

## 方法论:多 agent 独立测试

这是整个项目最反直觉有效的实践:**测试阶段由多个独立 agent 执行多轮独立测试**。

对抗测试三轮,每轮都能抓到真问题:
- 第一轮:12/12 过,但发现了协议路径语义不一致(R-013)
- 第二轮:9/10——**畸形 JSON 打 /pair 会返回 500 且完全绕过限速**,一个现成的
  DoS 面;rename 穿越名字被静默消毒;负数分页 500
- 第三轮:7/8——thumb size 越界静默回退、write offset 契约违背、token 编码
  非单射

关键是判读纪律:相册 agent 报「缩略图 6/20 后停止」——查下来是 GridView
懒加载的正常语义,不是 bug。**区分「缺陷」与「正常语义下的观察局限」**,
这条元教训写进了 risks.md。

另一个被验证有效的设计:**无人值守 E2E 设施**。真机测试不依赖任何人点屏幕:
配对 JSON 进 logcat,下载清单用文件触发,`[MLF]` 日志面包屑当验收通道。
凌晨三点也能跑回归。

## 结果

- **101 个测试全绿**;真机双端全矩阵(sha256 端到端校验)
- 64MB 并行 11.2MB/s(2.25×);打包流 2.95×;缩略图 0.46s/张
- 多端三件套:Android APK(签名 release)/ Windows 免安装包 / **mlf-serve
  单二进制无头服务器**(10MB,任意 NAS/Linux/Win/macOS)
- 三份审计(全新克隆构建/发布就绪/git 卫生)后确认可上传

## 写在最后

六天能做完这些,本质上是三件事:**架构上赌对了平行共存**、**每轮只打通一条
垂直切片**、**把测试交给独立的、不受实现者盲区影响的 agent**。

接下来:正式签名、i18n、原生缩略图解码(预期 10×+)、块级增量同步
(FastCDC 已调研)。协议和全部设计文档都在 repo 的 docs/ 里,欢迎拆解。

— 2026-10-05,MyLanFiles v0.1.0
