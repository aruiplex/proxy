# proxy — 便携式 mihomo (Clash.Meta) 管理 CLI

一个自包含的 **bash** 命令行工具。从 GitHub 克隆 `~/scripts/proxy/` 后，在**全新机器**上即可
完整管理 mihomo 内核：检测/下载二进制、引导配置、启停、节点切换、多订阅管理、订阅刷新、
规则合并、TUN 透明代理、代理环境变量注入。**所有代码只在 `~/scripts/proxy/`**；`~/.bashrc`
或 `~/.zshrc` 只追加指回脚本的钩子函数（非代码），运行时状态写在 `~/.config/mihomo/`。

设计原则：**不盲猜**——mihomo 没下就分级下载；没 sudo 就把 TUN 降级提示；无配置就从模板
引导；订阅链接首次交互询问；控制器异常时自动诊断根因而非甩一句"重启"。

---

## Quick Start（从零开始）

刚 clone 完这个 repo，按下面顺序走即可。前提：`bash` 4+、`curl`（绝大多数 Linux/macOS 自带）。

### 1. 克隆

```bash
git clone <repo> ~/scripts/proxy
```

（把 `<repo>` 换成你的仓库地址；或直接把这个目录放到 `~/scripts/proxy/`。）

### 2. 安装（检测/下载 mihomo + 引导配置 + 装钩子）

```bash
~/scripts/proxy/proxy install
```

这一步会自动：

- **找 mihomo 二进制**——按顺序：① PATH 与常见路径里已有的 mihomo；② **GitHub release**
  下载（按 `uname -m` + CPU 微架构自动选 `amd64-v3`/`compatible`/`arm64` 资源），解压到 `~/.local/bin/mihomo`；③ `brew`（若已安装 brew 且 homebrew-core 有 `mihomo` formula，则 `brew install mihomo`）。
  想指定来源：`proxy install --via github|brew|gz:FILE` 或 `--bin /path/to/mihomo`。
- **引导配置**——首次无 `config.yaml` 时从模板复制（`mixed-port: 7890`、`external-controller`、
  TUN 块、fake-ip DNS、空规则）。交互终端会提示粘贴订阅链接（可留空跳过）。
- **登记到 `proxy.conf`**、软链 `~/.local/bin/proxy` → 本脚本（之后直接敲 `proxy`）、往 `~/.bashrc`
  及 `~/.zshrc` 追加 Shell 函数包装 + 登录自启 + 0ms 启动优化钩子、`mihomo -t` 校验。
- 如果你粘了订阅链接，会**顺手拉取并启动**（`sub refresh` 会校验→替换→重新前置 merge→热重载，
  mihomo 没跑就自动起）。

> 没有订阅链接？跳过提示，之后用：
> ```bash
> proxy sub add default <URL>   # 存一个命名订阅
> proxy sub refresh             # 拉取并应用(会自动启动 mihomo)
> ```

### 3. 让当前 shell 走代理 + 验证

```bash
proxy env on      # 开启代理环境变量（当前 shell 及之后所有新开终端瞬间无感生效！）
proxy check       # 测: 系统代理状态 + 外网连通 + 出口 IP
proxy status      # 看: 进程/端口/控制器/出口节点
```

`proxy env on` 把开关写入 `~/.config/mihomo/env.state`。通过自动注入的 Shell 包装函数，**当前 Shell 及未来新建终端无需手敲 `eval`，直接无感生效**；当代理关闭时，新开终端具备 0ms 开销快路，绝不拖慢终端启动。

### 4. 选个出口节点

```bash
proxy node list          # 带序号, 机场信息节点已过滤
proxy node use 5         # 按序号切
proxy node use "japan 03"  # 按子串(唯一则直接切; 多义弹菜单)
proxy node use           # 无参: 装了 fzf 模糊搜, 没装就序号菜单
```

### 完成。日常速查

```bash
proxy status                                     # 看状态
proxy node use                                   # 换节点
proxy env off                                    # 关代理(当前 shell 及新 shell 自动清除)
proxy sub refresh                                # 更新订阅(刷新后 merge 规则自动重新前置)
proxy merge add direct google.com                # 快捷加一条直连规则 (或加 'DOMAIN-SUFFIX,foo.com,DIRECT')
proxy region preset                              # 一键加载预设地区分组 (HK, SG, JP, US) 与排除规则
proxy log -f                                     # 实时看日志
proxy doctor                                     # 环境体检
```

---

## 安装方式

`proxy install` 自动选级；也可显式指定：

| 命令 | 含义 |
|------|------|
| `proxy install` | 自动：已有 mihomo → GitHub Release → brew |
| `proxy install --via github` | 强制从 GitHub release 下载（arch 自适应） |
| `proxy install --via brew` | 强制 `brew install mihomo` |
| `proxy install --via gz:/path/mihomo.gz` | 用你已有的 gz 包解压安装 |
| `proxy install --bin /path/mihomo` | 接管一个已存在的二进制，不下载 |

GitHub 下载按 CPU 选 asset：amd64 先看是否支持 AVX2（v3 微架构），不支持则用 `compatible`
（兼容更广）；arm64/armv7 选对应资源。

---

## 命令一览

| 命令 | 说明 |
|------|------|
| `proxy install [--bin PATH] [--via github\|brew\|gz:FILE]` | 分级安装/接管 + 初始化 |
| `proxy init` | 仅初始化配置 + 钩子（已有二进制） |
| `proxy start \| stop \| restart` | 启停（nohup 直连二进制；brew 感知：先 `brew services stop`，清外来实例，精确匹配不误杀） |
| `proxy status` | 运行状态/版本/运行时长/出口节点/活跃连接/累计流量/端口/TUN/代理环境；**控制器 ↓ 时自动诊断**（见故障排查） |
| `proxy log [-f]` | 日志（`-f` 跟随） |
| `proxy env on \| off \| show` | 代理环境变量开关（当前 Shell 及新 Shell 自动无感生效，带 0ms 启动开销优化） |
| `proxy node list \| test [GROUP] \| use [<#\|子串>]` | 节点：`list` 带序号过滤信息节点；`test` 测全部节点延迟排序后可选号直切；`use` 支持序号/子串(唯一则切，多义弹菜单)/无参交互(fzf 或序号菜单) |
| `proxy merge list \| add '<RULE>' \| add direct\|proxy\|reject <domain> \| rm '<PAT>' \| diff \| apply` | 前置规则管理（安全，支持快捷语法） |
| `proxy region list \| apply \| preset \| add <name> ['<regex>'] \| rm \| set` | 地区自动组（支持快捷别名如 HK/SG/US/JP、一键预设与快捷排除） |
| `proxy sub add <name> <URL>` | 添加/更新命名订阅 |
| `proxy sub rm <name> \| list \| show [name]` | 删除 / 列出（活跃标记，token 脱敏）/ 查看 |
| `proxy sub use <name> [--no-refresh]` | 切换活跃订阅并立即拉取应用 |
| `proxy sub refresh [name]` | 刷新活跃（或指定）订阅；自动重新前置 merge |
| `proxy sub set <URL>` | 旧用法：存为 default + 激活 + 拉取 |
| `proxy tun on \| off \| --setup-nopasswd` | 透明 TUN（需 root） |
| `proxy route <URL> [--json]` | URL 路由检测：分别通过代理和直连访问目标 URL，对比连通性与延迟；`--json` 输出机器可读结果 |
| `proxy monitor [--interval <秒>] [--sort down\|up\|name] [--once]` | 实时流量监控：持续显示速率/累计流量/活动连接表（主机、规则、链路、上下行），Ctrl-C 退出；`--once` 单帧输出供脚本使用 |
| `proxy ui [--secret [VALUE]] \| off \| status` | Web 仪表盘 (metacubexd)：默认无密码改绑 `0.0.0.0`，局域网任意机器访问 `http://<IP>:9090/ui/`；`--secret` 设密码（无值=随机生成）；`off` 撤回为仅本机；`status` 查看当前状态 |
| `proxy check` | 系统代理状态 + 外网连通性 |
| `proxy doctor` | 环境体检 |
| `proxy upgrade` | 按 install_method 升级 mihomo |
| `proxy uninstall` | 移除钩子/软链（配置保留） |

---

## 代理环境变量注入

子进程无法直接改父 shell 的环境变量。本工具在 `~/.bashrc` 及 `~/.zshrc` 注入 `proxy()` Shell 函数包装以及极速开销检测：

- **无感实时生效**：执行 `proxy env on` 或 `off` 时，Shell 函数会在当前 Shell 内直接更新 `http_proxy`/`https_proxy`/`all_proxy`（+ 大写变体及 `no_proxy`），无需手动复制执行 `eval`！
- **0 毫秒启动开销**：当代理开关关闭或未初始化时，新打开的终端会直接跳过后台子进程检测，零延迟。
- 地址取自 `proxy.conf` 的 `proxy_addr`，否则解析 `config.yaml` 的 `mixed-port`，默认 `127.0.0.1:7890`。

**Tab 补全**（bash）：钩子块同时注册 `_proxy_complete`——命令树 + 子命令 + 动态候选
（`node use/test` 的节点名走控制器、`sub` 的订阅名读 `subs.conf`、`merge rm` 的规则读 `merge.yaml`；
节点/规则为子串匹配，兼容 emoji 旗帜前缀）。zsh 无 `complete` 内建命令，守卫自动跳过
（启用 `bashcompinit` 后可复用）。

---

## 多订阅管理

订阅存为 `name<TAB>url` 于 `subs.conf`（权限 600，含机场 token）。一个为"活跃"，`use`/`refresh`
拉取→校验→替换 config→重新前置 merge→应用。

```bash
proxy sub add airportA <URL>     # 添加
proxy sub add airportB <URL>     # 多个订阅
proxy sub list                   # 列出, 活跃标 *, token 脱敏
proxy sub use airportB          # 切到 B 并立即拉取应用
proxy sub refresh airportA      # 只刷新指定订阅(不切换活跃)
proxy sub show airportA         # 看完整 URL(需用时)
proxy sub rm airportB           # 删除
```

旧用法 `proxy sub set <URL>` 等同于存为 `default` + 激活 + 拉取。

---

## 规则合并（merge）

把自定义规则**幂等地前置**到 `config.yaml` 的 `rules:` 顶部，先于订阅规则命中。订阅刷新覆盖
config 后，`proxy sub refresh` 会自动重新前置。

```bash
# 支持快捷域名规则语法：
proxy merge add direct google.com         # 自动扩展为 DOMAIN-SUFFIX,google.com,DIRECT
proxy merge add proxy github.com          # 自动扩展为 DOMAIN-SUFFIX,github.com,PROXIES
proxy merge add reject ads.com            # 自动扩展为 DOMAIN-SUFFIX,ads.com,REJECT

# 也支持完整 Clash 规则语法：
proxy merge add 'DOMAIN-SUFFIX,hf-mirror.com,DIRECT'

proxy merge list            # 查 merge.yaml 里的规则
proxy merge diff            # 对比 merge.yaml 与 config 已注入块
proxy merge apply           # 手动重新注入+校验+重载
proxy merge rm 'google.com'  # 按子串删行
```

安全：注入前自动探测原 `rules:` 缩进、写入临时文件、`mihomo -t` 校验通过才替换，失败还原、
绝不杀进程。详见下「安全模式」。

---

## 地区自动组（region）

在订阅的大列表之上生成**按地区自动故障转移**的组。支持内置快捷别名（无需手写 Regex）与一键预设：

```bash
# 方式 1：一键预设（推荐，自动生成 HK, SG, JP, US 组及默认排除规则）
proxy region preset

# 方式 2：使用内置快捷别名添加（无需手写复杂的正则表达式）
proxy region add SG                       # 自动匹配新加坡节点
proxy region add US                       # 自动匹配美国节点
proxy region add HK                       # 自动匹配香港节点
proxy region add JP                       # 自动匹配日本节点
proxy region add TW / KR / UK             # 支持台湾、韩国、英国等预设

# 方式 3：自定义正则（面向特殊需求）
proxy region add 自定义组 '(?i)(custom|regex)'

# 极简排除规则设置 (exclude)
proxy region set exclude default          # 一键排除 HK 及机场流量/官网提示节点
proxy region set exclude hk               # 排除 HK 节点
proxy region set exclude clear            # 清空排除规则

proxy node use '🚀 自动'                  # 把选择组切到地区链
proxy region list                         # 查看地区、设置、各组实时状态
```

实现要点：地区组用 `include-all: true` + `filter` 正则，**不枚举节点名**，订阅刷新改名/增删
节点都自动适应；`sub refresh` 会自动重放（与 merge 同钩子）。地区定义在
`~/.config/mihomo/regions.conf`（`name<TAB>regex` 每行一个），设置存 `proxy.conf` 的
`region_interval` / `region_url` / `region_exclude`。

---

## TUN 透明代理（可选）

TUN 让所有流量（不止配了代理变量的程序）透明走 mihomo，需 root（`cap_net_admin` + 路由）。

```bash
proxy tun on               # 写 tun.enable=true, sudo 启动(交互输密码)
proxy tun off              # 关 TUN, 普通用户重启
proxy tun --setup-nopasswd  # 写 /etc/sudoers.d/proxy-mihomo(仅限单条 mihomo 启动命令),
                            # 经 visudo -c 校验; 之后 tun on/off 免密
```

无 sudo 时 `tun` 降级提示。TUN 开启后环境变量注入可省（全局透明），但开关仍兼容。

---

## 安全模式

贯穿所有改 `config.yaml` 的操作（`sub refresh` / `merge apply` / `tun on`）：

1. **备份** → `config.yaml.bak`；
2. 写临时文件 → **`mihomo -t` 校验**；
3. 通过才替换，**校验失败（400）绝不杀进程**（运行中的 mihomo 继续用旧配置）；
4. 应用：控制器热重载 `PUT /configs`；若控制器不可达（000，即运行实例没开
   `external-controller`），**自动 stop+start** 把新配置真正加载——否则会出现"看似成功、
   实则没生效"（配置在磁盘、运行实例还用旧的）。因配置已先过 `mihomo -t`，此重启是安全的。
5. `tun --setup-nopasswd` 写的 sudoers 片段**仅限单条**命令，并 `visudo -c` 校验。

---

## 故障排查

**`proxy status` 显示 `控制器 ↓`**：监听端口里有 `7890` 没有 `9090` = 运行中的 mihomo 没开
`external-controller`。此时 `proxy status` 会自动诊断那个进程：它的 `-f` 配置是不是本工具的、
有没有 `external-controller` 字段，并给精确修法。常见原因：

- **残留/外来实例**（之前手动起的、或 brew 装好时附带的默认配置跑起来的）占 7890、没开 9090
  → `proxy restart` 会停掉它并用本工具配置重起（brew 感知：先 `brew services stop`）。
- **配置缺 `external-controller` 字段** → 按诊断提示补：
  `printf '\nexternal-controller: 127.0.0.1:9090\n' >> ~/.config/mihomo/config.yaml && proxy restart`
- **9090 被占** → `ss -ltnp | grep 9090` 查谁占了。
- **`secret` 不匹配** → `proxy.conf` 的 `secret` 与 `config.yaml` 的 `secret:` 不一致；清掉
  `proxy.conf` 里 `secret=` 行或两边对齐。

**`proxy sub use` 看似成功但没生效**：旧版热重载失败只提示"下次 start 生效"；现版自动重启应用。
仍异常 → `proxy status` 看控制器是否 ↑。

**`proxy node list` 报"未找到节点组"**：先确认控制器 ↑（`proxy status`）；控制器 ↓ 时会明确
报"控制器不可达"而非误报无组。控制器 ↑ 后仍无组 → 订阅 `proxy-groups` 为空或非
Selector/URLTest 类型，查 `config.yaml`。

**机器重启后代理没了**：mihomo 不开机自启靠 `systemd --user`（多数服务器无）；本工具用
`~/.bashrc` / `~/.zshrc` 登录钩子——登录首个交互式 shell 时若 mihomo 没跑会静默自启。

---

## 文件布局

```
~/scripts/proxy/                 # 全部代码（仅此目录）
  proxy                          # 主入口（子命令分发）
  lib/{common,detect,install,service,env,merge,node,sub,tun,check,region,route,monitor,ui}.sh
  templates/{config.minimal.yaml,merge.yaml}
  README.md
~/.config/mihomo/                # 运行时状态(非代码)
  config.yaml / config.yaml.bak  # mihomo 配置 + 备份
  proxy.conf                     # 本工具设置 (mode 600): bin/install_method/controller/secret/active_sub/...
  subs.conf                      # 多订阅 (mode 600, name<TAB>url, 含机场 token)
  merge.yaml                     # 前置规则
  env.state                      # on/off
  mihomo.log
~/.local/bin/proxy -> ~/scripts/proxy/proxy   # PATH 软链
~/.bashrc / ~/.zshrc             # +钩子函数块 (proxy 函数包装 + 0ms 启动检测)
```

---

## 依赖

- 必需：`bash` 4+、`curl`、`awk`、`sed`、`grep`。
- JSON 解析（`status`/`node`/`sub`）：`python3`（近通用）；缺则相应命令提示安装。
- 安装可选：`brew`（tier-3 安装）、`jq`（加速 JSON，可选）、`fzf`（`proxy node use` 交互模糊选择，可选；无则用序号菜单）。
- TUN：`sudo` + `python3`；无 sudo 时 `tun` 命令降级提示。

---

## 卸载

```bash
proxy uninstall          # 移除 .bashrc/.zshrc 钩子 + 软链; 配置目录保留(会问是否同时删二进制)
```

手动：`rm -rf ~/scripts/proxy ~/.local/bin/proxy`；保留或删 `~/.config/mihomo/` 视需要。
