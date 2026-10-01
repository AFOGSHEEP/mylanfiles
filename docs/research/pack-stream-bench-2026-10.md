# 研究笔记：打包流实测 + 同类协议调研（2026-10-01）

> 动机：决策人要求"研究已弄好的东西，看效果、找同类、吸收优化"。
> 方法：本机 Windows 实测基准（tool/bench_pack.dart）+ 网络同类协议调研。

## 一、实测数据（本机，loopback http，bench_pack.dart 可复现）

负载：300×8KB（截图/微信图片档）+ 10×1MB，共 12.3MB。

| 模式 | 耗时 | 吞吐 | 判读 |
|------|------|------|------|
| A 逐文件 fs/read（无 RTT） | 432 ms | 28.6 MB/s | loopback 零往返时逐文件不慢 |
| B 逐文件 + 模拟 3ms RTT | 4803 ms | **2.6 MB/s** | **RTT 主导小文件传输——§16.3 模型成立** |
| C 打包流 pack（单请求） | 519 ms | **23.7 MB/s** | 同 RTT 条件下 **≈9.2×**（M1 是 29×，因其 300 文件全 512KB 且 RTT 建模不同；混合大文件稀释了比值，方向一致） |
| D 大文件单流 256MB | 994 ms | **257 MB/s** | dart:io+shelf 非瓶颈；Wi-Fi 空口上限（12-50 MB/s）远在此之下，§9.10 成立 |

### 结论与推论

1. **打包流的存在价值再次实证**：真实热点 RTT 下小文件场景差出一个数量级。
2. **C 比 A(无RTT) 慢 ~17%**：来自两遍读（先哈希后传输）+ 帧头。空口 20-40 MB/s 时磁盘两遍读（257 MB/s）仍可忽略——**维持两遍法**，不值得为此改帧格式。
3. 单遍流式变体（帧格式改为 sha 后置 `[name][size][data][sha]`，边传边哈希尾部校验）可省一遍读——**列 P2 可选优化**（§2 授权 AI 调帧格式细节，但当前实测无收益，不动）。

## 二、同类协议调研（网络上怎么做批量/断点/打包传输）

| 先例 | 机制 | 对 MyLanFiles 的启示 |
|------|------|---------------------|
| **tus**（resumable upload 开放协议，tus.io） | create 会话 → PATCH 按字节偏移续传 → HEAD 查询已传偏移 | 我们 fs/write?offset= 已是同思路；补一个「查询偏移」端点（基于已有 stat 即可，P2 小活） |
| **S3 Multipart** | 分部件编号+ETag，按件重试 | 无需采用（P2P 无存储商约束），但"部件级重试"精神 = 我们的文件粒度 skip |
| **Syncthing BEP**（docs.syncthing.net/specs/bep-v1） | 固定块（128KB-16MB）SHA-256，Index 交换后只请求缺失块 | 文件内增量能力是我们的空白；**CDC（内容定义分块）是 P3+ 候选**，MVP 不做（整机迁移/相册场景文件粒度够用） |
| **restic/kopia 备份流** | tar 流 + CDC + `--rsyncable`（保持去重友好的 tar） | 佐证"流式批量"路线正确；CDC 同上后置 |
| **tar 流互操作**（restic 社区长期诉求） | 标准 tar 可被 tar/7zip/curl 直接消费 | **可选项记入 P3**：pack 端点加 `?format=tar` 变体，第三方工具零成本接入（自定义帧 20B/帧 vs tar 512B 块，效率换互操作，做成可选而非替换） |
| **HTTP chunked encoding** | 未知长度流的终止语义 | 我们已依赖 ✓（响应流无 content-length） |
| **zstd seekable / zstd --rsyncable** | 可随机访问的分帧压缩 | §4.2 本就预留"边压缩可选"——P2 落地时优先 seekable 变体（保持按帧解压能力） |

## 三、行动项（按优先级）

1. **P2**：pack 客户端多选接线 + 进度 UI（下一会话主任务不变）
2. **P2**：压缩可选：zstd seekable（§4.2 预留）；压测后再定默认值
3. **P2**：上传断点查询端点（tus 思路，fs/stat 包装）
4. **P3**：`format=tar` 互操作变体；CDC 文件内增量（eval FastCDC）
5. **不做**：S3 multipart 式部件协议（形态不符）；本轮不改帧格式（实测两遍读无损空口吞吐）

## 参考

- [BEP v1 spec](https://docs.syncthing.net/specs/bep-v1.html) · [tus.io](https://tus.io/)
- [restic tar-stream 讨论](https://forum.restic.net/t/restoring-files-directly-into-a-single-compressed-archive/968) · [restic #2226 stdin tar](https://github.com/restic/restic/issues/2226) · [tar --rsyncable 与去重](https://forum.restic.net/t/using-restic-for-daily-backups-of-tar-files/6647)
- [Intro to Content Defined Chunking](https://lobste.rs/s/l3xdnr/intro_content_defined_chunking)
