# 收尾维护审计 — 2026-10-12

本次检查使用代码图、公开命令入口及相关模块源码；未重启生产代理或执行卸载/TUN。它是针对管理层收尾的静态审计，不是所有旧命令的完整回归或安全审计。运行状态最后核对仍为 adaptive.3，systemd active、NRestarts=0。

## Bash 的实际状态

本轮是增量整合：`proxy` 与 `lib/*.sh` 仍负责命令分发、Shell 环境/登录钩子、订阅、规则、地区、手动节点、交互与外部命令协调；这些入口仍被使用。新增的六个 `libexec/*.py` 模块处理候选配置、固定版本/回退、质量 API、监督器识别和监测。Go 内核源码在独立 fork 中。

旧 Bash 中仍有内嵌 Python，配置处理、输出和系统命令尚未全部模块化。之后按有测试的职责边界逐块迁移即可；按扩展名批量删除或整体改语言会扩大回归范围，不能直接解决线路故障。本轮没有承诺完整迁移。

## 已确认的整合缺口

跟踪任务：[proxy #9](https://github.com/aruiplex/proxy/issues/9)。

| 项目 | 源码证据 | 状态与影响 |
| --- | --- | --- |
| 日常 CLI | 默认入口改为只读简短状态与近期目标；`next` 归一化目标并查找唯一成功建立的 Adaptive 组；短帮助及 `help --all` 分流 | 已整合；TTY/非 TTY、单目标反馈、歧义/失败零反馈和父仓库转发有隔离验收。旧菜单实现删除，历史入口返回短帮助 |
| 健康命令补全 | `lib/complete.sh:_proxy_complete` 列出 health 及其子命令；空前缀仅提示日常命令，输入维护命令前缀仍可补全 | 已整合 |
| 完整服务卸载 | `lib/install.sh:proxy_uninstall` 移除钩子/自有软链，未处理健康 timer 或自有主 unit | 当前保留服务与状态；退役前须单独协调监督器，不能当作完整卸载 |
| 管理层 CI | proxy 的 management 工作流测试 Python 3.12/3.14；scripts 检出固定子模块并测试转发及管理行为 | 已建立独立 PR/默认分支 CI；fork 的固定夹具继续验证内核 |

后续明确卸载所有权与验收。卸载测试使用临时 unit，不操作现有生产服务。

日常入口按用户明确的“命令少、容易记的 CLI”收敛，默认不进入菜单。状态读取不会修复/清理 PID 文件、启停或刷新；已有隐私权限修复仍沿用公共加载逻辑。`next` 是目标级节点反馈，不承诺立即替换已建立连接。`on/off` 提示区分持久设置与安装的 Shell 函数同步，外部脚本不能直接修改父 Shell。

清理删除了旧嵌套菜单与生成的 Python 字节码缓存，保留仍有公开调用的管理模块、历史补丁/复现脚本、回归测试、验收和恢复证据。完整接手顺序及保留清单见 [维护交接](../maintenance-handoff.md)。

## 覆盖边界与尚未采纳的配置

- 现有长流、空闲、故障恢复、组重载、协议不重放和持久化夹具通过，不代表全部 Bash 功能已验收。
- 受控部署验证覆盖 Linux/amd64 TCP；用户持续使用 Antigravity、macOS、TUN/UDP/QUIC 并反馈较稳定，要求后续按实际问题修复。本轮不新增平台验收任务；其他组合及跨机器 SSH 部署没有受控验收记录。
- `lib/tun.sh:_tun_start_privileged` 仍通过特权 nohup 启动，不能把普通用户 systemd 的成功验收用于这个路径。
- 质量持久化已实现并测试，当前仍未启用；这属于可选运行偏好。LAN 与控制器监听保持现状和认证，收紧范围需依据实际客户端用途。
- 公开 HTTPS 与实际 Codex 完整响应都有证据，但 Codex 后端 socket 未独立归属，也没有“所有线路永远不中断”的证明。Antigravity 的持续使用反馈见维护交接，与专门的应用验收分别记录。
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
