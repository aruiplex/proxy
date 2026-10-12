# proxy — mihomo 管理与自动选路

`proxy` 管理 mihomo 的安装、配置、订阅、生命周期和本机质量反馈，也可以通过父仓库的 `scripts proxy ...` 调用。自动选路以连接稳定性为首要目标：按目标记录线路表现，优先同地区候选，必要时跨地区；反馈影响后续连接，已经正常传输的连接继续保持。

## 实现分工

本轮增加了管理模块和内核能力，保留了仍在使用的 Shell 功能，没有进行整个 CLI 的语言重写。

| 层 | 实现与位置 | 职责 |
| --- | --- | --- |
| 命令和 Shell 集成 | Bash：`proxy`、`lib/*.sh` | 命令分发、环境变量与登录钩子、交互界面、订阅/规则/地区管理，以及系统命令协调 |
| 管理模块 | Python 标准库：`libexec/*.py` | 固定内核来源与版本、配置候选生成、质量 API 客户端、监督器对接、HTTPS 监测与日志轮转 |
| 连接内核 | Go：[aruiplex/mihomo](https://github.com/aruiplex/mihomo/tree/adaptive/stable) | 逐连接选路、建立阶段有界重试、质量观测与可选持久化 |
| 父仓库 | [aruiplex/scripts](https://github.com/aruiplex/scripts) | 统一调用、代码更新与固定 proxy 子模块 |

Bash 模块是当前实现的一部分，不能直接作为“重构残留”删除。部分旧模块还嵌有 Python 片段；复杂配置和状态逻辑后续可以按模块迁入 `libexec/`，保持公开命令与 Shell 环境行为兼容。连接选路的改动直接维护在 Go fork 中。

## 安装与首次使用

需要 Bash 4+、Python 3.8+、curl，以及 awk/sed/grep 等常见工具；macOS 系统自带 Bash 可能需要升级。fzf 与 Homebrew 为可选依赖。实验内核的构建和平台要求见 fork 文档。

```bash
git clone https://github.com/aruiplex/proxy.git ~/scripts/proxy
~/scripts/proxy/proxy install
```

已有 scripts 仓库时可以使用：

```bash
scripts install proxy
```

普通安装依次寻找已有 mihomo、官方 GitHub 发行、Homebrew，初始化配置及 Shell 钩子。它不会自动安装带 adaptive 策略的 fork。已存在的受管理安装使用 `kernel prepare/activate` 更换版本。

| 安装入口 | 行为 |
| --- | --- |
| `proxy install --via github` | 首次安装官方发行，优先兼容的 amd64 资产 |
| `proxy install --via brew` | 首次使用 Homebrew mihomo |
| `proxy install --bin /path/to/mihomo` | 校验并保存受管理的本地二进制副本 |
| `proxy install --via gz:/path/to/mihomo.gz` | 校验并保存压缩资产 |
| `proxy install --manifest /path/to/manifest.local.json` | 按明确的来源、版本和摘要安装候选 |

无订阅时先添加并刷新；订阅 URL 包含私密信息，应保存在本机配置中：

```bash
proxy sub add default <URL>
proxy sub refresh
proxy on
proxy
```

`proxy on/off` 通过已安装的 Shell 包装函数更新当前及后续终端的代理环境。仅执行外部脚本无法改变父 Shell 环境；新装钩子后需要重新加载 Shell 配置或打开终端。

## 自动模式的日常入口

日常只需记住：

```bash
proxy                     # 简短状态与近期目标，直接退出
proxy next example.com    # 该目标线路不好用，让后续连接重新选路
proxy on                  # 开启终端代理
proxy off                 # 关闭终端代理
proxy help                # 简短帮助；help --all 查看维护命令
```

裸 `proxy` 在终端和脚本中都显示状态，不进入菜单、不等待输入、不启动服务或主动探测业务。近期目标最多列出五项，表示各组最近成功建立的线路，不代表加密业务成功或当前所有连接共用该节点。控制器不可达时保留本机进程与代理设置的信息。

先按 [自动选路与内核管理](docs/usage/adaptive-routing.md) 准备受支持的 fork 和候选配置。`next` 接受准确的域名或 `域名:端口`，默认端口 443；IPv6 用 `[地址]:端口`。程序查找有该目标成功建立记录的唯一 Adaptive 组，并提交节点反馈；它影响该目标的后续连接，已有健康连接继续保持，不会立即替换正在使用的会话，也不保证某个特定后继节点。其他目标继续按原策略选路。

未知目标、多个组有相同目标或质量记录读取失败时，命令返回非零，不猜测或进入互动。先从裸命令显示的近期目标选择准确域名与端口；同一目标确实经过多个组时使用 `proxy next example.com --group NAME`。可加 `--reason timeout|disconnect|unusable|unknown`，默认 `unusable`。没有 Codex/ChatGPT 等硬编码别名，域名反馈也不扩展到相关子域。

`scripts proxy` 和 `scripts proxy next example.com` 转发相同功能。`on/off` 需要已安装的 `proxy` Shell 函数同步当前终端；`scripts proxy on/off` 仅修改持久设置，子进程无法修改父 Shell。质量记录描述可观测的建立/传输故障，无法直接确定 AI 请求的语义结果或根因。

候选默认接管 MATCH 所用代理策略的 TCP；其他策略在偏好 `policies` 中显式列出。原规则条件和明确 DIRECT/REJECT 保留，UDP 使用原配置策略。新目标由默认策略承接，无需为每个服务创建独立代码。实际覆盖送往代理的连接，不等于已经接管整机所有流量。

`node use/test` 和地区 fallback 组保留用于普通配置兼容。旧嵌套菜单已删除，历史 `proxy menu` 入口只显示简短帮助。主动 URL 测速不代表 AI 服务稳定性；日常自动模式使用上面的简短 CLI。

## 升级、监督与回退

- `scripts update` 更新脚本代码和固定子模块提交。
- `proxy update` 刷新订阅并重放已启用的选路偏好。
- `proxy upgrade --manifest FILE` 只准备同来源的固定版本；官方来源也可用 `--version VERSION`。
- Homebrew 更新官方二进制，当前受管理的 fork 副本不会随之更换。
- fork CI 构建/验证、发布候选与本机启用分别执行。尚未发布的 CI 资产使用同目录的 `manifest.local.json`。

准备不会重启运行中的内核。核对当前状态、准备兼容配置与独立恢复保护后，在维护窗口执行：

```bash
proxy stop
proxy kernel activate
proxy start
```

验收失败时执行 `proxy stop` → `proxy kernel rollback` → `proxy start`。回退恢复上一版匹配的二进制、配置、偏好和缓存；它只有一层当前回退指针，发行目录中的更早快照不会自动轮流成为回退版本。

Linux 已有且 PIDFile 匹配当前配置目录的 `proxy-mihomo.service` 时，启停命令复用该用户服务。没有匹配服务时仍使用独立进程方式。工具会话中的普通 nohup 可能随会话清理结束；登录钩子也不能代替长期监督器。普通安装不会自动创建 mihomo 主服务；`health install` 安装的是监测 timer。

启动命令返回后须在另一次调用中验证真实 TLS/HTTP、持续 PID、监听端口所有权及控制器，不能仅凭启动成功宣布可用。切换会中断现有连接，允许应用重新连接。完整验收流程见使用说明。

## 监测、质量记录与同步

```bash
proxy health install
proxy health check
proxy health record --app codex --outcome complete
proxy health uninstall
proxy sync export /path/to/private-settings.tar.gz
```

监测每五分钟探测三个公开 HTTPS 目标，记录确认的故障/恢复、结构化退出与匿名线路证据。偶发公开探测失败不会重启内核。日志按大小与期限轮转，历史诊断归档单独保留。详见 [健康监测](docs/usage/health.md)。

质量持久化为可选配置，默认未启用；新 fork 支持 TTL、容量、原子写入、节点身份变化失效与坏文件冷启动。共享的是选路偏好和订阅配置，质量记录、缓存、内核路径及控制器认证各机器独立。同步包仍含订阅信息，应私密保存。

`proxy uninstall` 当前主要移除 Shell 钩子与自有软链，并保留配置；它不是完整的服务卸载。需要退役部署时，先核对所有权，单独禁用监测 timer 和自有主服务，保留诊断及回退证据。不要直接删掉仍被 unit 引用的源码目录。

## 兼容命令

`proxy help --all`（或 `proxy --help --all`）是完整命令索引；`proxy status` 保留详细诊断，`quality/feedback` 保留准确目标键的低层操作。现有入口包括：

- 节点与订阅：`node`、`region`、`sub`、`pool`。
- 配置与应用接入：`merge`、`env`、`lan`、`docker`、`ui`。
- 诊断：`status`、`log`、`check`、`route`、`monitor`、`doctor`。
- 透明代理：`tun` 需要特权；当前自动选路验收没有覆盖 TUN/UDP/QUIC，特权启动也仍需单独验证监督与恢复。

配置修改一般先备份、运行 `mihomo -t`，再热重载；控制器不可达时部分兼容命令会重启，因此会影响现有连接。语法校验成功不等于业务验收成功。

## 验证与维护边界

2026-10-12 本机已切换到 `v1.19.32-adaptive.3`，完成真实公开 HTTPS、同一 TLS socket 空闲后续用、本机 Codex 完整响应和执行任务结束后的独立检查；详见 [上线证据](docs/research/candidate3-deployment-results.json)。这是一份有日期的验收记录，当前运行状态应重新查询。

受控验证覆盖 Linux/amd64 TCP。公开探测不是登录后的 AI 请求，Codex 后端 socket 未独立归属；物理断线后的 TCP 无法迁移。用户持续使用 Antigravity、macOS、TUN/UDP/QUIC 并反馈目前较稳定，本轮按其要求不扩大验收；发现具体问题后再针对性修复。该使用反馈与受控验证范围分别记录，实际跨机器部署仍无验收记录。

日常 CLI、健康命令补全和 proxy/scripts 管理层 CI 已整合，内核矩阵继续由 fork 承担。完整服务卸载仍由 [proxy #9](https://github.com/aruiplex/proxy/issues/9) 跟踪。接手维护或清理前阅读 [维护交接](docs/maintenance-handoff.md)，事实与剩余范围见 [维护审计](docs/research/maintenance-audit.md)。

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/unit -v
# 在 scripts 父仓库：
bash tests/scripts-proxy.sh
```

内核 race、协议/不重放、长流/空闲与持久化矩阵由 fork CI 运行，使用 `adaptive/fixtures.json` 固定的夹具提交，不会自动验证当前全部管理 CLI。

## 文件布局

```text
proxy                          命令分发
lib/                           Bash 功能模块，部分含 Python 片段
libexec/                       Python 管理模块
templates/                     初始配置和偏好示例
tests/unit/                    管理层行为测试
tests/integration/             隔离内核/监测夹具及显式运行的真实 TLS 验收
docs/usage/                    操作流程
docs/research/                 有日期的诊断、验收和维护记录
prototypes/adaptive-routing/    冻结的 prototype.2 补丁与复现证据
AGENTS.md                      维护 agent 的入口
```

运行时状态默认在 `$HOME/.config/mihomo`，可用 `CONF_DIR` 指定：配置/订阅、`kernels/`、`health/`、`logs/` 及可选 `adaptive-quality/`。这些状态含私密信息，保存在本机。当前内核源码以独立 mihomo fork 为权威，原型目录的旧补丁保持冻结。
