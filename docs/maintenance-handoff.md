# 维护交接

## 2026-10-17：NAS / Stallion 统一 Linux TUN（已验收）

两机固定相同 scripts/proxy 提交，内核仍为 adaptive.3。实际应用运行在 Stallion 的 SSH 会话时不再依赖 agy-proxy；它保留为兼容入口。部署使用非 root 的 system unit `proxy-mihomo-1000.service`，旧用户 unit 已停止/禁用，新 unit 已配置开机启动及异常重启。维护流程见 [Linux TUN](usage/linux-tun.md)，具体 PID、模式和脱敏验收见 [部署结果](research/linux-tun-deployment-results.json)。

NAS 为 system 栈、auto-redirect=false 的 TUN 路由模式；Stallion 为 system 栈、auto-redirect=true。工具版本一致不要求私密节点或本机适配参数相同。两机清空代理环境后的原生 Antigravity、真实 GPT/TLS、IPv6 HTTPS、新 SSH/Tailscale 均通过；NAS 另有原生 Codex 完整最小回复。订阅/节点池重放及监听归属检查覆盖相应边界。实际重启整机、生产崩溃注入、全面 UDP/QUIC 不在本次验收范围；Maestro 原业务会议未恢复/重放。

首次候选 gvisor 因发行未编入而失败，NAS auto-redirect 又出现 netlink ENOENT；两次均在独立回退保护下恢复旧服务，再以兼容参数重试成功。不能以 -t 或控制器启动替代实际 TUN 状态与业务验收。带能力进程限制 /proc/PID/fd 访问时，监测使用 socket cgroup/UID 与唯一 PID 成员核对，不增加 root 读取权限。

当前匹配的私密恢复与验收：NAS `$HOME/.local/state/proxy-maintenance/tun-20261017-route`，Stallion `$HOME/.local/state/proxy-maintenance/tun-20261017`。成功后回退计时均解除；旧失败阶段材料保留为证据，不能重新启用旧计时器。需要恢复时使用当前匹配目录的 deployment.py rollback --force，先停止 system unit 再恢复旧配置/标记/用户监督器。接手先查实时状态、Git 和该目录 handoff.md，不用历史 PID 代替实测。

## 2026-10-16：Antigravity 地区错误

已复现并修复：自动组曾把 DIRECT 放入代理策略，节点池只留下极少兜底规则。Google 推理连接实际经过 DIRECT，原生 agy 返回地区不支持；当时直连出口的两个公开地理服务均显示 HK，不能据此断言是大陆 IP 或 Google 内部分类。独立 CA/US 出口与修复后现用配置均通过原生 agy 请求。

当前配置保留明确的订阅规则基准、原始策略范围与本机前置规则；Google AI TCP 仅使用已核对的节点身份，当前为 US/CA 两个出口。两个其他 CA 节点未通过连通性检查，未纳入。新节点先核对出口和原生应用，端点/凭据变化使旧身份失效；端点背后的出口也可能变化，地区错误重现时复查。管理层 62 项测试和两个隔离内核夹具的 15 项检查通过。详见 [诊断与维护](research/antigravity-region-routing.md)。

配置通过热重载应用，内核仍为 adaptive.3，主 PID 1118177、NRestarts=0；重载跨越同一 ChatGPT TLS socket，之后独立三次 HTTPS 200 和原生 Antigravity SUCCESS 均通过。微信 echo 服务 PID 3357787 保持不变，没有切换其后端。后续以实时查询为准。

私有配置、匹配备份、原生探测及恢复脚本保留在 `/tmp/proxy-policy-staging-20261016-cg5b39gb`（目录 700）；独立回退 timer 在验收后已停用。紧急恢复可明确运行该目录的 `rollback.py --force`，会恢复本轮之前配置，Google 地区故障也可能随之恢复。旧诊断 `/tmp/agy-region-diagnostic-20261016-c8ic91p9` 保留为对照。这些目录含本机证据/配置，不提交、不作为普通临时文件清理。

下面保留 2026-10-12 收尾基线；其“较稳定”是当时用户体验，不覆盖这次新发现的地区故障。

## 2026-10-12 基线

## 接手顺序

1. 阅读仓库 `AGENTS.md` 与 README。先检查 scripts、proxy 子模块和 mihomo fork 的 Git 状态，保留不属于本次任务的本地改动。
2. 只读核对 `proxy`、`systemctl --user show proxy-mihomo.service -p ActiveState -p MainPID -p NRestarts`、`proxy health status`。版本管理需要时使用 `proxy kernel status`；该命令可能处理未完成切换的恢复日志，先了解当前状态。
3. 按任务阅读 [自动选路与版本管理](usage/adaptive-routing.md)、[健康监测](usage/health.md) 或 [维护审计](research/maintenance-audit.md)。这份交接是历史快照，运行信息以本机查询为准。

## 用户已经确认的方向

- 日常入口是少量、容易记的 CLI：裸 `proxy`、`next 域名[:端口]`、`on/off`、短帮助；完整维护命令在 `help --all`。旧嵌套菜单已删除，历史 `menu` 入口只显示简短帮助。
- 自动选路以稳定建立和保持连接为主，延迟不是优先目标。同地区候选优先，必要时跨地区；目标及其节点证据保持隔离，未来目标也由默认策略承接。
- `next` 是节点反馈：自动定位唯一有该准确目标成功建立记录的 Adaptive 组，影响后续连接。它不关闭健康连接、不重放业务、不主动立即建立后继连接。未知目标、歧义或候选组不可读时零反馈并返回错误。
- 用户持续使用 Antigravity、macOS、TUN/UDP/QUIC，反馈目前较稳定；本轮按用户要求收尾，之后出现具体问题再复现和修复。此用户体验不改变受控自动选路验收为 Linux/amd64 TCP 的证据范围，也不产生待补“全平台验收”任务。
- 升级允许维护窗口短暂停机；无需复杂的无中断升级。质量持久化是已实现的可选功能，当前未启用。LAN/控制器监听和认证保持现有用途，不推断需要改变访问范围。

## 实现与源码权威

| 仓库 | 位置与职责 |
| --- | --- |
| scripts | `$HOME/scripts`；Shell 设置、转发、跨机部署及 proxy 固定子模块 |
| proxy | `$HOME/scripts/proxy`；Bash 命令/Shell 适配，Python `libexec/` 管理实现 |
| mihomo fork | `$HOME/projects/mihomo`，`aruiplex/mihomo` 的 `adaptive/stable`；Go 连接选路、质量记录与升级流水线 |

日常概览与目标归一化/组发现集中在 `libexec/quality.py`。域名默认端口 443，不创建应用别名、不扩展到子域、不比较不同组的 selection 序号。概要读取已有观测，不发业务探测；PID 查询用只读模式，公共加载过程仍有既有的隐私权限修复。

`proxy on/off` 依赖安装的 Shell 函数同步父终端。`scripts proxy on/off` 或直接执行脚本只能更新持久设置。普通订阅、规则、地区、手动选择、TUN 和安装模块仍有公开调用，保留 Bash 是有意的增量实现。

当前 kernel 验证源码为 `a08bf0d9900a19e0aa302bfcbb12b2eefad8a3d9`，已部署版本 `v1.19.32-adaptive.3`。上游比较使用 fork 的 `adaptive/baseline.json` 固定 tag/commit；`adaptive/base` 已包含补丁，不能作为纯上游。旧 `/tmp/proxy-mihomo-fork-20261012` 是兼容链接，不能把它当作可丢弃的独立副本。

fork 的 `adaptive/README.md`、`AGENTS.md`、`adaptive/maintenance.md` 以及 scripts 部分文档/配置已有其他未提交改动，本次原样保留，未夹带提交。这些本机文档是否已发布，应检查 Git，不假设新克隆可用。对 fork 文档中“base 是原始上游”的旧描述，以固定 baseline 为准。

## 验证与持续集成

- proxy `.github/workflows/management.yml` 在 PR/main 上验证当前管理代码、Shell 语法，使用 Python 3.12/3.14 与隔离控制器/服务夹具。独立 clone 中父仓库转发测试会跳过。
- scripts `.github/workflows/proxy-management.yml` 检出固定子模块，验证 CLI/Shell 入口与转发测试的语法、`tests/scripts-proxy.sh` 和 proxy 管理测试，包含真实父入口转发。`installation/` 等目录含旧安装备忘和占位命令，不属于本轮可执行 CLI 检查范围。
- 本轮本机 51 项管理测试、脚本转发、Shell 语法和文档链接检查通过；CLI 夹具包含真实 TTY、只读默认入口、目标端口/大小写、歧义/认证/超时零反馈及错误码透传。
- mihomo CI 使用 `adaptive/fixtures.json` 固定的 proxy 夹具提交验证内核；它与最新管理 CI 各自负责自己的范围。更新内核夹具 pin 是独立的受控变更。
- [adaptive.3 上线验收](research/candidate3-deployment-results.json) 记录真实 HTTPS、同一 TLS 空闲后继续使用、实际 Codex 完整响应和工具调用结束后的独立检查。长流、故障恢复、策略组重载、不重放等历史受控证据在 [稳定性结果](research/stability-results.json) 和 fork 验证材料中。公开探测成功不代表登录后 AI 业务成功。

本轮只更新 CLI、代码维护和 CI，主服务没有停止或重启。状态最后核对为 active、重启次数 0；不用这个日期快照替代今后的实测。

## 运行与恢复

主服务为用户级 `proxy-mihomo.service`，健康 timer 为 `proxy-health.timer`。低频探测只记录故障/恢复，不因偶发业务失败重启内核。普通测试使用临时根目录、端口和服务夹具；不要在生产代理上测试卸载、故障注入或反馈。

实际切换时先准备匹配候选与回退材料，并在工具会话之外建立独立恢复保护；停止匹配服务后启用，随后通过监督器启动。启动调用结束后再独立执行真实 TLS/HTTP 与应用验收。健康 PID/控制器只是启动证据，不能替代业务检查。

日常回退指向 prototype.2，原 1.19.29 匹配快照也保留。保留 `$HOME/.config/mihomo/kernels/` 中发行和回退文件、本机缓存/质量/日志、历史诊断归档以及 `/tmp/proxy-candidate3-cutover-22e95jn7` 的恢复/验收证据；这些不是清理目标，也不进入提交。

历史 prototype.2 进程消失的确切退出原因未知。官方/实验内核的会话清理对照和监督器验收已有 [诊断记录](research/kernel-exit-diagnosis.md)；不要把未知原因写成已证明的 kernel panic。

## 清理与后续任务

已删除旧嵌套菜单实现，保留短帮助兼容入口；清理生成的 Python 字节码缓存，测试/CI 使用 `PYTHONDONTWRITEBYTECODE=1`。历史补丁、构建复现脚本、测试和脱敏验收记录保留，分别承担复现与回归职责，不能因为 fork 是新权威就删除证据。

[proxy #9](https://github.com/aruiplex/proxy/issues/9) 保留完整服务卸载的后续整合：当前卸载仅移除入口，不统一禁用主服务和 timer。退役时先确认所有权、停止/禁用自有 unit，保留配置、回退和诊断；实现自动卸载时用临时 unit 测试，不操作现有服务。更多快照选择/磁盘清理和 prerelease 发布也尚无统一日常入口，本轮不扩展实现。

接下来按实际故障或维护需求工作，不重复已完成的自动选路、fork CI、监测/日志或 CLI 重构。
