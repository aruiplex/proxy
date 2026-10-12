# 收尾维护审计 — 2026-10-12

本次检查使用代码图、公开命令入口及相关模块源码；未重启生产代理或执行卸载/TUN。它是针对管理层收尾的静态审计，不是所有旧命令的完整回归或安全审计。运行状态最后核对仍为 adaptive.3，systemd active、NRestarts=0。

## Bash 的实际状态

本轮是增量整合：`proxy` 与 `lib/*.sh` 仍负责命令分发、Shell 环境/登录钩子、订阅、规则、地区、手动节点、交互与外部命令协调；这些入口仍被使用。新增的六个 `libexec/*.py` 模块处理候选配置、固定版本/回退、质量 API、监督器识别和监测。Go 内核源码在独立 fork 中。

旧 Bash 中仍有内嵌 Python，配置处理、输出和系统命令尚未全部模块化。之后按有测试的职责边界逐块迁移即可；按扩展名批量删除或整体改语言会扩大回归范围，不能直接解决线路故障。本轮没有承诺完整迁移。

## 已确认的整合缺口

跟踪任务：[proxy #9](https://github.com/aruiplex/proxy/issues/9)。

| 项目 | 源码证据 | 状态与影响 |
| --- | --- | --- |
| 自动模式菜单 | `lib/menu.sh:proxy_menu` 列出手动节点、延迟测速、订阅和启停，没有质量/反馈/版本/健康入口 | 命令可用，但在旧菜单中不可发现；尚未整合 |
| 健康命令补全 | `lib/complete.sh:_proxy_complete` 未列出 health 或其子命令 | CLI 可用，Tab 补全遗漏 |
| 完整服务卸载 | `lib/install.sh:proxy_uninstall` 移除钩子/自有软链，未处理健康 timer 或自有主 unit | 当前保留服务与状态；退役前须单独协调监督器，不能当作完整卸载 |
| 管理层 CI | proxy/scripts 没有跟踪的 `.github` 工作流；fork CI 固定夹具提交 | 管理测试已本机运行，当前 CLI 新提交缺少自动门禁；fork CI 不是全部管理命令的 CI |

建议先建立管理层 CI，再补自动模式入口和补全，然后明确卸载所有权与验收。卸载测试使用临时 unit，不操作现有生产服务。

## 覆盖边界与尚未采纳的配置

- 现有长流、空闲、故障恢复、组重载、协议不重放和持久化夹具通过，不代表全部 Bash 功能已验收。
- 当前部署验证 Linux/amd64 TCP；macOS 新管理流程、TUN/UDP/QUIC、其他协议/插件组合和实际跨机器 SSH 部署尚未验收。
- `lib/tun.sh:_tun_start_privileged` 仍通过特权 nohup 启动，不能把普通用户 systemd 的成功验收用于这个路径。
- 质量持久化已实现并测试，当前仍未启用；这属于可选运行偏好。LAN 与控制器监听保持现状和认证，收紧范围需依据实际客户端用途。
- 公开 HTTPS 与实际 Codex 完整响应都有证据，但 Codex 后端 socket 未独立归属，也没有“所有线路永远不中断”的证明。Antigravity 已按用户要求暂不验收。
- 当前一层 rollback 指向 prototype.2；1.19.29 匹配快照保留在发行目录。更早快照的选择和磁盘清理尚无统一 CLI；维护时保留现有审计/回退材料，不直接删目录。
- fork 只提供已验证 CI 资产，当前未发布 prerelease；在线发行 manifest 的 URL 只有发布后才可使用。继续使用已下载且校验的本地 manifest，不把未发布 URL 当作可用升级入口。

## 权威来源与维护记录

当前内核源码维护分支为 fork 的 `adaptive/stable`。PR #1 已合入 `adaptive/base`，因此该分支也含补丁；纯上游比较使用 `adaptive/baseline.json` 指定的官方 tag/commit。检查旧维护材料中“base 就是纯上游”的说法时，以 Git 历史和固定 pin 为准。

本机独立源码目录为 `$HOME/projects/mihomo`，旧 /tmp 路径为兼容链接。该 checkout 及 scripts 父仓库已有未提交的维护说明，本次保留其原内容；这些本机材料是否可在其他机器使用，应核对各自 Git/PR 状态，不能假设它们已发布。

更新 README 与 agent 入口时引用现有操作文档、固定验收记录和待办，避免把状态快照写成长期部署约束：

- [自动选路、版本及回退](../usage/adaptive-routing.md)
- [监测和日志](../usage/health.md)
- [adaptive.3 上线证据](candidate3-deployment-results.json)
- [fork 候选来源与验证](fork-candidate-results.json)
