# proxy — 便携式 mihomo (Clash.Meta) 管理 CLI

一个自包含的 bash 工具，从 GitHub 克隆 `~/scripts/proxy/` 后即可在全新机器上完整管理
mihomo 内核：检测/下载二进制、引导配置、启停、节点切换、订阅刷新、规则合并、TUN、
代理环境变量注入。**所有代码只在 `~/scripts/proxy/`**；`~/.bashrc` 仅追加一行指回脚本的
钩子（非代码），运行时状态写在 `~/.config/mihomo/`。

设计原则：**不盲猜**——mihomo 没下就分级下载；没 sudo 就把 TUN 降级提示；无配置就从
模板引导；订阅链接首次交互询问。

## 快速开始

```bash
git clone <repo> ~/scripts/proxy          # 或直接把本目录放到 ~/scripts/proxy/
~/scripts/proxy/proxy install             # 检测已有 mihomo → brew → GitHub 下载, 并初始化
proxy start                               # 启动 (软链 ~/.local/bin/proxy 已就绪)
proxy env on && eval "$(proxy env show)"  # 当前 shell 走代理; 之后新 shell 自动生效
```

安装分级顺序（`proxy install` 自动选择，也可 `--via brew|github|gz:FILE` 或 `--bin PATH`）：

1. **检测已有** mihomo（PATH 与常见路径）→ 直接接管。
2. **brew**：`command -v brew` 且 homebrew-core 有 `mihomo` formula → `brew install mihomo`。
3. **GitHub**：按 `uname -m` + CPU 微架构（amd64 是否支持 v3，否则 `compatible`）选 asset 下载解压到 `~/.local/bin/mihomo`。

## 命令一览

| 命令 | 说明 |
|------|------|
| `proxy install [--bin PATH] [--via brew\|github\|gz:FILE]` | 分级安装/接管 + 初始化 |
| `proxy init` | 仅初始化配置 + 钩子（已有二进制） |
| `proxy start \| stop \| restart` | 启停（直连二进制 + nohup，精确 pkill，不误杀） |
| `proxy status` | 进程/端口/控制器/出口节点/活跃连接 |
| `proxy log [-f]` | 实时日志 |
| `proxy env on \| off \| show` | 代理环境变量开关（.bashrc 钩子注入；`show` 供 `eval`） |
| `proxy node list \| test [GROUP] \| use <NAME>` | 节点管理（控制器 API） |
| `proxy merge list \| add '<RULE>' \| rm '<PAT>' \| diff \| apply` | 前置规则管理（安全） |
| `proxy sub set <URL> \| refresh` | 订阅管理（刷新后自动重新 merge） |
| `proxy tun on \| off \| --setup-nopasswd` | 透明 TUN（需 root） |
| `proxy check` | 系统代理状态及外网连通性测试 |
| `proxy doctor` | 环境体检 |
| `proxy upgrade` | 按 install_method 升级 mihomo |
| `proxy uninstall` | 移除钩子/软链（配置保留） |

## 代理环境变量注入

子进程无法直接改父 shell 的环境变量。本工具在 `~/.bashrc` 注入一行钩子，每个交互式
shell 启动时 `eval "$(proxy _login 2>/dev/null)"`：若 mihomo 未运行则静默自启，再按
`~/.config/mihomo/env.state`（`on`/`off`）`export`/`unset` 代理变量。因此：

- `proxy env on` / `off` 翻转开关，**新 shell 自动生效**。
- 当前 shell 立即生效：`eval "$(proxy env show)"`。

## 安全模式（贯穿所有改配置操作）

改 `config.yaml` 前：备份 `.bak` → `mihomo -t` 校验 → 通过才替换 → 控制器 API 热重载；
**校验失败绝不杀进程**（运行中的 mihomo 继续用旧配置）。`proxy sub refresh` 会校验后自动
重新前置 merge 规则。`tun --setup-nopasswd` 写入的 sudoers 片段**仅限单条** mihomo 启动
命令，并经 `visudo -c` 校验。

## 文件布局

```
~/scripts/proxy/                 # 全部代码（仅此目录）
  proxy                          # 主入口（子命令分发）
  lib/{common,detect,install,service,env,merge,node,sub,tun}.sh
  templates/{config.minimal.yaml,merge.yaml}
  README.md
~/.config/mihomo/                # 运行时状态（非代码）
  config.yaml / config.yaml.bak  # mihomo 配置 + 备份
  proxy.conf                     # 本工具设置 (mode 600, 含订阅 token)
  merge.yaml                     # 前置规则
  env.state                      # on/off
  mihomo.log
~/.local/bin/proxy -> ~/scripts/proxy/proxy   # PATH 软链
~/.bashrc                        # +1 行钩子块
```

## 依赖

- 必需：`bash` 4+、`curl`、`awk`、`sed`、`grep`。
- JSON 解析（status/node/sub）：`python3`（近通用）；缺则相应命令提示安装。
- 安装可选：`brew`（tier-2）、`jq`（加速 JSON，可选）。
- TUN：`sudo` + `python3`；无 sudo 时 `tun` 命令降级提示。
