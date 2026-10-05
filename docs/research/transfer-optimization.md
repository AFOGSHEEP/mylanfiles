# 传输算法优化研究笔记（2026-10-04,R7 轮）

> 决策人要求:从数学与工程角度深度思考传输算法,检索学术文献(英文)。
> 本文记录理论依据 → 实测基线 → 已实施优化 → 后续方向。检索于 2026-10-04。

## 一、实测基线（真机,PC↔Xiaomi Android 15,同一 Wi-Fi,自签 TLS）

| 场景 | 结果 | 推算 |
|---|---|---|
| 单文件 64MB（单 TCP 流） | 24.6s ≈ **2.7 MB/s**（21.9 Mbps） | 单流吞吐上限 |
| 100×50KB 打包流（单流连续帧） | 2790ms,27.9ms/文件,1.84 MB/s | 每文件均摊低于逐文件 3 倍 |
| 100×50KB 逐文件（100 个独立 GET） | 8216ms,82.2ms/文件 | **每请求开销 ≈54ms** |
| 缩略图（1600×1200 JPEG→320px） | 0.54s/张（同步解码,2 并发预取） | 服务端单 isolate 事件循环被 CPU 解码串行化 |

## 二、理论依据

### 1. 单流瓶颈:Mathis 方程
TCP 吞吐上限 T ≈ (MSS/RTT)·(C/√p),C≈1.22,p 为丢包率
（[Mathis et al. 1997 模型;PS8 求解确认](https://www.cliffsnotes.com)、
[WLAN 丢包-RTT 相互作用仿真](https://dl.ifip.org)）。
Wi-Fi 的非拥塞丢包（干扰/衰落,见 [802.11 实测丢包率](https://cs.uwaterloo.ca)）被
TCP 误判为拥塞而降窗——单流 2.7MB/s 正是 RTT×√p 的乘积惩罚,与链路物理能力无关。

### 2. 多流叠加:并行 TCP 连接
每条连接独立拥塞窗口、独立丢包恢复,聚合吞吐≈k×单流直至空口饱和
（[Microsoft: Parallel TCP Sockets — Simple Model, Throughput and Fairness (2005)](https://www.microsoft.com)、
[Fu 2007 TCP Parallelisation](https://www.sciencedirect.com)、
[Alrshah 2016 testbed 对比](https://arxiv.org)）。
工程代价:对其它流量公平性下降（同上文献讨论）——局域网单用户场景可接受。

### 3. 协议路线选择:并行分块 vs HTTP/2 多路复用
- shelf 无原生 HTTP/2（[dart-lang/shelf issue #50](https://github.com/dart-lang/shelf/issues/50),PoC 级适配器）;[http2 包](https://pub.dev/packages/http2) 可做但需自写 TLS+ALPN 适配层,改动大、收益不确定（H2 单连接多路复用在丢包链路上仍受单流 Mathis 限制!H2 的流控是连接级的）。
- **决策:4 路并行 Range GET**。服务端 offset+length 早已支持;客户端改动 ~60 行;数学上直接绕开单流平方根惩罚。H2/QUIC 留作 P3-4 评估（交接文档已有 iroh/QUIC 选项）。

### 4. 每请求 54ms 开销的构成
TLS 会话已复用（keep-alive）,54ms ≈ 1×RTT（Wi-Fi 省电模式小包延迟 ~20-40ms）
+ 请求调度。打包流已把它摊销为帧间 0 开销——2.95× 实测增益与 54/28≈1.9+
带宽利用提升的复合一致。结论:**打包流方向正确,29× 假设的条件(热点 3ms RTT)在本网络不成立,但 3× 已稳**。

### 5. 增量同步的理论上限:内容定义分块（CDC）
当前 skip 是文件级(rsync-lite)。块级去重需 CDC:
[FastCDC (USENIX ATC'16)](https://www.usenix.org/system/files/conference/atc16/atc16-paper-xia.pdf)、
[The Design of FastCDC (TPDS 2020)](https://csyhua.github.io/csyhua/hua-tpdis2020-dedup.pdf)。
注意 [CDC 安全性:chunking attacks (2025)](https://www.daemonology.net/blog/chunking-attacks.pdf)。
照片场景去重率低(每张唯一),**文档/备份同步场景才有价值——P2 评估**。

## 三、已实施优化（本轮）

| 优化 | 理论依据 | 实现 | 预期 |
|---|---|---|---|
| O1 并行分块下载 | §2 多流叠加 | ≥8MB 全新下载 4 路 Range GET 并发写入预分配 .part;任一块失败删整重来(洞),重试回退串行断点路径 | 单文件 2-4× |
| O2 缩略图 isolate 解码 | 事件循环阻塞 | 解码/缩放/编码移入 Isolate.run;服务端事件循环不再被 JPEG 解码串行化 | 缩略图吞吐 ×核数,预取不再卡服务 |
| O3 每请求开销 | §4 | 打包流(R5 已有)保持小文件主路径 | 已有 2.95× |

## 四、后续方向（按性价比排序）

1. **并行度自适应**:按实测 RTT/吞吐动态调 k(1-8),空口饱和即回落(公平性)。
2. **上传对称优化**:上传目前单流;同样可 4 路 .mlfpart 分块并行(服务端 write 已支持 offset)。
3. **TCP 缓冲区调优**:Dart HttpClient 未暴露 SO_RCVBUF;大 BDP 场景或需平台通道。
4. **缩略图原生解码**:纯 Dart JPEG 解码 ~0.3s/张;Android BitmapFactory 约束采样解码 ~10ms 级,差 30×——平台通道(值得做,列 P2)。
5. **QUIC/多路径**(P3-4,iroh 选项已在交接文档)。
6. **CDC 增量同步**(P2,文档/备份场景)。

## 五、实测结果(2026-10-05,交错 A/B,同文件 64MB,PC↔手机 Wi-Fi,全部 sha256 校验通过)

| 轮 | 模式 | 耗时 | 吞吐 |
|---|---|---|---|
| 1 | 并行 4 流 | 7155ms | 9.4 MB/s |
| 2 | 串行 | 12824ms | 5.2 MB/s |
| 3 | 并行 4 流 | 5744ms | 11.7 MB/s |
| 4 | 串行 | 14070ms | 4.8 MB/s |
| 5 | 并行 4 流(紧随轮4) | 5035ms | 13.3 MB/s |

**并行均值 11.2 MB/s vs 串行 5.0 MB/s = 2.25×;交错设计控制了 Wi-Fi 时变**(注:当日串行基线 5.0MB/s 高于昨日 2.7MB/s,信道负载不同;交错同条件对比为准)。与 Mathis 多流模型的定性预测一致;2.25×<4× 是空口竞争饱和的表现,符合理论(并行连接在空口饱和后增益递减)。

上传(单流,64MB):与下载串行同量级 ✓ 对称。

缩略图 isolate 解码:0.54→0.46 s/张(**1.17×**)——解码占比低于预估,网络+编码+调度摊薄了 isolate 收益;**原生解码(Android BitmapFactory 约束采样)仍是 P2 的主方向**(预期 10-30×)。

## 六、测量方法备忘

- 真机计时一律走 logcat/stdout 的 `[MLF]` 面包屑(误差 <10ms);`parallel done/serial done in Xms` 内建计时。
- A/B 开关:`MLF_PARALLEL=0` 强制单流(对照组)。
- 踩雷记录:①`RandomAccessFile.writeFrom(buf, pos)` 第二参是缓冲区下标而非文件偏移,必须 setPosition+write 且并发交错需串行化锁;②Wi-Fi 时变要求交错 A/B;③手机拔 USB 后 MIUI 杀后台,服务/宣告随之消失(预期内)。
