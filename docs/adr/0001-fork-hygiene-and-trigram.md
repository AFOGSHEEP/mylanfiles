# ADR-0001：fork 卫生规则与 FTS5 trigram 决策

- 状态：已接受（fork 卫生原则、trigram）；**部分挂起**（新代码包位置——见 ⚠）
- 日期：2026-09-30（P0）
- 决策人：项目所有者（依据：交接文档 §2 B 级决策表、§9 工作约定）

## 背景

MyLanFiles 以 fork LocalSend（Apache-2.0）为底座起步。为控制 fork 长期漂移成本（雷区 10），
必须在写第一行业务代码前定下"上游文件改多少、新代码放哪里"的规则。
搜索侧：通用 Dart 引擎使用 SQLite FTS5，分词器选择决定中文子串搜索的成败。

## 决策

### 1. fork 卫生规则

1. **新代码进新文件/新包**，禁止在大范围内修改上游文件。上游 `app/` 内的改动按三类对待：
   - 期望改动量 ≈0 的：`packages/*`（全部自建包）、新增页面文件；
   - 允许微改（±10 行级）的：接线入口（按钮/import）、`pubspec.yaml`、CI 配置；
   - 原则上不碰的：上游的状态管理、传输引擎、协议实现。
2. remote 布局：`origin` = 自己的仓库，`upstream` = localsend/localsend；
   **每月例行 `git merge upstream/main`** 吃安全修复（日历提醒）。
3. 提交纪律：Conventional Commits；短命分支 + PR + squash；`main` 永远可发布。
4. 每次改上游文件，PR 描述里列明"动了上游哪些文件、为什么无可避免"。

### ⚠ 挂起项：新代码包位置

交接文档原定"新代码只进 `packages/core`、`packages/server`"。
**P0 Spike 1 发现上游 `packages/core` 已是 Rust crate**（协议/HTTP/crypto 全在 Rust，Dart 仅 UI），
该假设失效。三个候选路线（新建 Dart 包并列 / 跟随 Rust / 自建壳）已在
`docs/risks.md` R-002 登记，**待决策人拍板后以 ADR-0002 补记**。
在拍板前，不向任何 `packages/*` 写入业务代码。

### 2. SQLite FTS5 trigram 分词

- **决策**：通用搜索引擎的 `files` 虚表使用 `tokenize='trigram'`（SQLite ≥3.34，经
  `sqlite3_flutter_libs` 自带的 3.4x 保证）。
- **理由**：默认分词器对中文整串成 token，`MATCH '旅行'` 无法命中"旅行照片"；
  trigram 提供子串语义，是跨语言（中英混合文件名）唯一无需外部分词依赖的方案。
- **代价**：索引体积约 3 倍文本（10 万文件 ≈30–60MB，可接受）；<3 字符查询走 LIKE 降级。
- **实测义务**（雷区 4，P1/P2 验收）：10 万文件真机建索引进度/体积/内存峰值；
  不达标则降级 `LIKE + 普通索引` + MediaStore 快路径（备选已定）。
- **适用范围**：引擎宿主语言（Dart 或 Rust）不影响本决策——FTS5 是 SQLite 层能力。

## 后果

- CI（待仓库初始化后上线）加入"上游文件改动清单"检查的可行性，暂列为 P1 待办。
- trigram 与雷区 4 的实测绑定：若实测失败，本节决策按 §2.5 协议走"AI 可调参数级"降级并记录。
