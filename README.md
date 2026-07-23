# proxy — 便携式 mihomo (Clash.Meta) 管理 CLI

一个自包含的 bash 工具，从 GitHub 克隆 `~/scripts/proxy/` 后即可在全新机器上完整管理
mihomo 内核：检测/下载二进制、引导配置、启停、节点切换、订阅刷新、规则合并、TUN、
代理环境变量注入。**所有代码只在 `~/scripts/proxy/`**；`~/.bashrc` 仅追加一行指回脚本的
钩子（非代码），运行时状态写在 `~/.config/mihomo/`。

设计原则：**不盲猜**——mihomo 没下就分级下载；没 sudo 就把 TUN 降级提示；无配置就从
模板引导；订阅链接首次交互询问；控制器异常时自动诊断根因而非甩一句"重启"。

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
| `proxy start \| stop \| restart` | 启停（nohup 直连二进制；brew 感知：先 `brew services stop`，清掉外来实例，精确匹配不误杀） |
| `proxy status` | 进程/端口/控制器/出口节点/活跃连接；**控制器 ↓ 时自动诊断**（见下） |
| `proxy log [-f]` | 实时日志 |
| `proxy env on \| off \| show` | 代理环境变量开关（.bashrc 钩子注入；`show` 供 `eval`） |
| `proxy node list \| test [GROUP] \| use [<#\|子串>]` | 节点管理：`list` 带序号并过滤机场信息节点；`use` 支持序号/子串(唯一则切，多义弹菜单)/无参交互(fzf 或序号菜单) |
| `proxy merge list \| add '<RULE>' \| rm '<PAT>' \| diff \| apply` | 前置规则管理（安全） |
| `proxy sub add <name> <URL>` | 添加/更新命名订阅 |
| `proxy sub rm <name> \| list \| show [name]` | 删除 / 列出（活跃标记，token 脱敏）/ 查看 |
| `proxy sub use <name> [--no-refresh]` | 切换活跃订阅并立即拉取应用 |
| `proxy sub refresh [name]` | 刷新活跃（或指定）订阅；自动重新前置 merge |
| `proxy sub set <URL>` | 旧用法：存为 default + 激活 + 拉取 |
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

改 `config.yaml` 前：备份 `.bak` → `mihomo -t` 校验 → 通过才替换 → 应用。**校验失败（400）
绝不杀进程**（运行中的 mihomo 继续用旧配置）。

应用阶段（`sub refresh` / `merge apply`）走控制器热重载 `PUT /configs`；若控制器不可达（000，
即运行实例没开 `external-controller`），**自动 stop+start** 把新配置真正加载上去——否则会
出现"sub use 看似成功、实则没生效"（配置在磁盘、运行实例还在用旧的）。因配置已先过
`mihomo -t`，此重启是安全的。`proxy sub refresh` 会校验后自动重新前置 merge 规则。
`tun --setup-nopasswd` 写入的 sudoers 片段**仅限单条** mihomo 启动命令，并经 `visudo -c` 校验。

## 故障排查

**`proxy status` 显示 `控制器 ↓`**：监听端口里有 `7890` 没有 `9090` = 运行中的 mihomo
没开 `external-controller`。此时 `proxy status` 会自动诊断那个进程：它的 `-f` 配置是不是
本工具的、有没有 `external-controller` 字段，并给出精确修法。常见原因：

- **残留/外来实例**（如之前手动起的、或 brew 装好时附带的默认配置跑起来的）占着 7890、
  没开 9090 → `proxy restart` 会停掉它并用本工具配置重起（brew 感知：先 `brew services stop`）。
- **配置缺 `external-controller` 字段** → 按诊断提示补：
  `printf '\nexternal-controller: 127.0.0.1:9090\n' >> ~/.config/mihomo/config.yaml && proxy restart`
- **9090 端口被占** → `ss -ltnp | grep 9090` 查谁占了。
- **`secret` 不匹配** → `proxy.conf` 的 `secret` 与 `config.yaml` 的 `secret:` 不一致；
  清掉 `proxy.conf` 里的 `secret=` 行或两边对齐。

**`proxy sub use` 看似成功但没生效**：旧版热重载失败只提示"下次 start 生效"；现版本会
自动重启应用配置。若仍异常，`proxy status` 看控制器是否 ↑。

**`proxy node list` 报"未找到节点组"**：先确认控制器 ↑（`proxy status`）；控制器 ↓ 时会
明确报"控制器不可达"而非误报无组。控制器 ↑ 后仍无组，说明订阅 `proxy-groups` 为空
或非 Selector/URLTest 类型 → 查 `config.yaml` 的 `proxy-groups:`。

## 文件布局

```
~/scripts/proxy/                 # 全部代码（仅此目录）
  proxy                          # 主入口（子命令分发）
  lib/{common,detect,install,service,env,merge,node,sub,tun,check}.sh
  templates/{config.minimal.yaml,merge.yaml}
  README.md
~/.config/mihomo/                # 运行时状态（非代码）
  config.yaml / config.yaml.bak  # mihomo 配置 + 备份
  proxy.conf                     # 本工具设置 (mode 600): bin/install_method/controller/secret/active_sub/...
  subs.conf                      # 多订阅 (mode 600, name<TAB>url, 含机场 token)
  merge.yaml                     # 前置规则
  env.state                      # on/off
  mihomo.log
~/.local/bin/proxy -> ~/scripts/proxy/proxy   # PATH 软链
~/.bashrc                        # +1 行钩子块
```

## 依赖

- 必需：`bash` 4+、`curl`、`awk`、`sed`、`grep`。
- JSON 解析（status/node/sub）：`python3`（近通用）；缺则相应命令提示安装。
- 安装可选：`brew`（tier-2）、`jq`（加速 JSON，可选）、`fzf`（`proxy node use` 交互模糊选择，可选；无则用序号菜单）。
- TUN：`sudo` + `python3`；无 sudo 时 `tun` 命令降级提示。
