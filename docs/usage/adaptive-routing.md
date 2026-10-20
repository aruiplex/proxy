# 自动选路试用与内核版本管理

实现任务：[内核管理 #4](https://github.com/aruiplex/proxy/issues/4) 与 [命令及配置集成 #6](https://github.com/aruiplex/proxy/issues/6)。目前自动选路仍是实验功能；下面的命令没有自动重启或切换来源的隐含步骤。

## 职责与状态

- `proxy update` 更新订阅，重放已经启用的选路偏好。
- `proxy upgrade --manifest FILE` 准备同来源的固定版本；官方来源可以用 `--version vX.Y.Z`。不接受隐含 latest 升级，也不自动启用。
- `proxy kernel prepare` 下载或复制、校验资产摘要、实际版本与当前系统可执行性，在临时状态副本中运行配置校验。
- `proxy kernel activate` 在内核停止后启用候选版本，保存上一版二进制、兼容配置、proxy.conf、adaptive.json 和 cache.db。
- `proxy kernel rollback` 在停机后恢复匹配的版本、配置和缓存。
- `proxy kernel status` 查看当前、待启用和可回退版本；`--json` 用于程序调用。

发行目录与状态位于 `$CONF_DIR/kernels`，不修改 Homebrew 的二进制或其他工具安装的文件。启动和版本切换使用同一个锁；切换时检查该配置目录的运行进程。异常中断留下的恢复日志会阻止普通内核解析；停机后运行 `proxy kernel status` 恢复原状态。

`config.yaml` 仍使用原路径，订阅和现有命令可以继续管理它。准备后如果配置、proxy.conf 或选路偏好改变，启用会拒绝旧候选，需要重新 prepare。回退快照取自实际启用前的配置，不是首次安装模板。发行目录保留供审计，目前没有自动清理命令。

## 发行 manifest

```json
{
  "schema": 1,
  "source": {"id": "aruiplex/proxy-adaptive", "kind": "custom"},
  "version": "v1.19.32-adaptive.3",
  "platform": {"os": "linux", "arch": "amd64"},
  "asset": {
    "path": "/path/to/mihomo",
    "sha256": "<64 位 SHA-256>",
    "compression": "none"
  }
}
```

`asset.path` 可相对 manifest 所在目录；或指定 HTTPS `url`，两者不能混用。`compression` 为 `none` 或 `gzip`。来源由 `id` 与 `kind` 标识，同来源升级不能悄悄变成官方版。明确切换来源使用 `kernel prepare --switch-source`，启用仍是独立操作。

官方资产从指定 tag 的发行数据取得摘要；匿名 API 不可达时可以复用已登录的 gh，仍失败则提供本地 manifest。优先使用 amd64-compatible。缺少发行摘要则拒绝下载，不跳过校验。手动入口 `proxy install --bin PATH` 和 `--via gz:FILE` 保留，但现在保存受管理的副本，不原地覆盖源文件。Brew/existing 首次入口也保存副本；其后用相同来源的 manifest 准备更新。`proxy init` 单独使用时仍可服务已有外部二进制；旧安装首次纳入管理后才支持版本回退。Python 管理模块使用标准库，需要 Python 3.8+；实验内核构建另需 Python 3.12+ 与固定 Go 工具链。

## 准备自动选路

日常版本使用 [mihomo fork](https://github.com/aruiplex/mihomo) 已通过验收的 CI 资产，下载同目录的二进制、manifest.local.json、validation.json 和 SHA256SUMS，并验证摘要及通过状态。发行 URL 只有发布后才有效；未发布的 CI 资产使用本地 manifest。原型目录仅用于复现冻结的 prototype.2，不是后续发行来源。

```bash
cp templates/adaptive.example.json /tmp/my-adaptive.json
proxy auto prepare --preferences /tmp/my-adaptive.json \
  --output /tmp/adaptive-candidate.yaml
proxy kernel prepare --manifest /path/to/accepted-candidate/manifest.local.json \
  --config /tmp/adaptive-candidate.yaml --preferences /tmp/my-adaptive.json
proxy kernel status
```

候选输出路径必须是新文件。首次从其他来源迁入 fork 时明确增加 `--switch-source`；已有相同来源时不需要。默认接管 MATCH 所用代理策略的 TCP；同策略的其他规则也在原位置增加 TCP 条件，原规则保留给 UDP。规则条件、明确 DIRECT/REJECT、未选中的其他策略组继续保持原意。需要接管其他组时，在偏好 `policies` 中明确列出已有策略组名称。

自动组只在所选原策略的代理节点范围内重试，原组中嵌套组会展开；多个被选策略各有自己的候选组。明确的 DIRECT/REJECT 与规则顺序保持。旧 `direct_first` 字段兼容读取，但不再允许它向代理策略添加 DIRECT；无候选时明确 REJECT，连 `empty-fallback` 也设置为 REJECT。私网直连仍由原始 LAN 规则决定，部署前保留完整 LAN 规则。

`region_patterns` 和节点池生成的 `x-proxy-node-regions` 是节点名称推断的地区提示，只用于同地区偏好；它们不证明实际出口或业务可用。示例正则同时匹配 `US01` 等归一化名称。现阶段需要在节点池中展开静态节点；所选策略引用运行时 proxy-provider 时拒绝候选，避免把未知范围展开为全局所有节点。

服务地区约束放在偏好 `services` 中，例如：

```json
{
  "google-ai": {
    "domains": ["googleapis.com", "googleusercontent.com", "antigravity-unleash.goog"],
    "allowed_regions": ["CA", "US", "JP", "SG"],
    "verified_regions": {}
  }
}
```

`verified_regions` 是本机实际核对过的节点 SHA-256 身份到地区代码的映射。维护者使用 `routing_profile.node_identity` 对候选中的节点条目取指纹，先在独立端口核对真实出口和原生应用请求，再填写。指纹不包含节点名字：重编号继续有效，端点/凭据变化会失效；格式变化也可能保守失效。空映射或无匹配候选会拒绝该服务的新 TCP 连接，不按名称猜测放行。服务规则在原代理规则的位置增加域名条件，不覆盖更早的明确直连/拒绝规则；非 TCP 继续使用原规则。这不是对任意新服务支持地区的自动识别，也不会读取 TLS 内的业务错误。

核对代表当时出口；提供商可在端点不变时更换真实出口。业务再出现地区错误时重新核对并移除失效证据，不能把旧记录当永久地理保证。新增节点先核对，再进入受地区约束的候选；同一允许地区优先，必要时跨允许地区。

含 `dialer-proxy` 的节点使用 `route_dependencies.NodeGraph` 计算包含传递依赖的身份；父节点端点或凭据变化使子线路旧资格失效。独立探测复制完整依赖链，支持确定的单成员静态拨号策略；多成员或动态策略不按临时默认选择猜测准入，保留导入并单独报告不可验证，不暂停其他候选。

### 节点池的规则来源

`proxy pool refresh` 用 `proxy.conf` 的 `pool_rules_source` 指定唯一规则基准；未设置时使用 `active_sub`。每次成功抓取保存完整 `.profile` 与节点缓存，失败可复用上次成功版本；旧缓存只有 `.prox` 时可从对应 `config.<订阅名>.yaml` 恢复基准。基准缺失、组名冲突或不可安全理解时，刷新失败并保留现用配置，不生成简化 MATCH 规则。

节点导入支持顶格或缩进的 YAML 列表、任意根字段顺序、行内和块式映射；流量/到期等提示项会从节点定义和组引用一起删除。URI 订阅支持 AnyTLS，包括百分号编码密码、默认 443 端口、IPv6、SNI 和显式 insecure 参数。节点池状态使用同一解析器计数，`x-proxy-node-sources` 保存归一化节点到订阅名的对应关系。

订阅由完整配置改为只返回节点列表时，刷新节点仍保留该订阅上次保存的路由规则基准；转换器的简单 MATCH 模板不会覆盖已有规则。合成节点池组遇到订阅同名组时使用唯一前缀，原策略组与规则保持原名。

节点池开启时，普通 `proxy update` 与 `proxy pool refresh` 都刷新全部订阅。刷新发布、服务资格写入与对应回退共享跨进程配置锁；刷新进程持有锁描述符，启动器中断不会使其与另一个写入者并发发布，长期运行内核启动前解除继承。外部配置更新后的旧资格事务，只能在当前配置/偏好一致且控制器已重新核对后标记为过期，不能恢复旧快照覆盖新节点。

保留基准的规则顺序、专用策略组及 rule-providers。只有基准 MATCH 所用策略增加节点池入口，以接纳其他订阅的节点；专用组继续使用自己的节点。补充订阅的完整规则不参与混合。本机 merge 前置规则仍在重建后应用；临时直接编辑生成的 config.yaml 不能作为长期覆盖，应记录到 merge.yaml。普通刷新不等于内核升级。

支持 JSON 和常见块式 YAML。对不能安全理解的 YAML 结构会拒绝生成；最终使用候选内核 `-t` 验证。配置引用的资源需要在本机状态目录中可用；状态目录内的资源绝对路径在校验副本中映射，原配置保持原路径。状态目录外的绝对路径或符号链接可能不符合临时副本的安全路径约束，会拒绝候选，不修改现有资源。

Linux 上若已安装用户级 `proxy-mihomo.service`，且该服务的 PIDFile 指向当前配置目录，`proxy start/stop/restart` 自动交给 systemd。[受监督 TUN](linux-tun.md) 迁移后由本机 supervisor.json 选择固定的 system unit，并验证 UID、PIDFile 与 cgroup。服务内部的启动仍使用内核锁，不递归调用自身；监督器失败不会绕过它启动第二个实例。未选择监督器且没有匹配用户服务时保留原来的独立进程方式。

维护时可以直接执行：

```bash
proxy stop
proxy kernel activate
proxy start
```

不满意时先 `proxy stop`，再 `proxy kernel rollback`、`proxy start`；也可显式调用 `systemctl --user stop/start proxy-mihomo.service`。再次测试也必须先停该服务，避免端口冲突及监督进程重新拉起旧实例。其他环境应使用对应的长期进程监督器；`nohup` 不保证进程能逃离执行工具的会话清理。

启动命令返回后，在**另一次调用**中验收，不能只检查启动时的 PID 和控制器：

```bash
python3 tests/integration/live_tls_acceptance.py \
  --root "$HOME/.config/mihomo" --proxy http://127.0.0.1:7890 \
  --expected-version v1.19.32-adaptive.3 \
  --url https://chatgpt.com/robots.txt --requests 3 --settle-seconds 10 \
  --report /tmp/proxy-live-tls-result.json
```

探测通过本机代理完成真实 ChatGPT HTTPS GET，校验证书、HTTP 200 和完整非空响应，并持续检查同一进程、代理端口和控制器。Linux 还核对两个监听端口属于该 PID，避免误把竞争实例的响应当作候选成功。网络、HTTP 状态或进程检查失败都会返回非零退出码；发生自动重启也不算同一次稳定运行。控制器须为本机回环地址，curl 需支持 `%{json}`。

需要验证同一条连接在空闲后继续可用时，增加 `--keepalive --idle-seconds 10 --requests 4`。此模式使用 Python 标准库通过 CONNECT 建立经证书校验的 TLS，四次请求复用同一 socket，避免重连掩盖断流；核对响应完整性和连接仍然保留。远端主动关闭 HTTP keepalive 也会失败，须结合基线判断，不能直接归因于代理。该检查不等同于长时间 SSE/AI 响应验证。

默认 URL 为公开 `robots.txt`，不是登录后的 AI 业务；首页可能因访问策略返回 403，即使证书校验成功也不能计为 200。可用 `--url` 指定已知可用的公开 HTTPS 目标，禁止 URL 中携带凭据或查询参数。验收脚本不读取应用 Cookie/Token、不重启服务、不调整节点；AI 客户端完整响应需另行验收。2026-10-12 阶段本机 Codex 请求已完成，当时 Antigravity 按用户要求暂不纳入；2026-10-16 的[地区故障修复](../research/antigravity-region-routing.md)已增加原生应用验收。当前实验构建未验证 TUN/QUIC/UDP 自适应；保留 UDP 原规则只保证配置策略不被改写，不等于已验证该业务。

2026-10-11 的[进程退出诊断记录](../research/kernel-exit-diagnosis.md)包含执行会话清理的官方/实验内核对照，以及启动健康后终止进程的失败验收。

## 查看质量与反馈

日常使用无需进入菜单或记住组名：

```bash
proxy
proxy next example.com
proxy help
```

裸命令显示简短状态与最多五项近期目标，直接退出。`next` 将裸域名补为 `:443`，域名转小写；显式端口保持，IPv6 使用 `[地址]:端口`。程序查询各 Adaptive 组，只有一个组具有该准确目标的成功建立记录时才反馈。未知目标或任何候选组不可读时返回非零；多组歧义使用 `--group NAME` 明确指定，不用组内序号推断跨组的“最近”。反馈只影响该目标的后续连接，不关闭现有健康连接、不主动建立下一条连接或扩展到子域。

需要完整质量记录、明确目标键与维护命令时：

```bash
proxy quality
proxy quality --target 'example.com:443' --json
proxy feedback 'example.com:443' --reason timeout
proxy help --all
```

存在多个 adaptive 组时用 `--group NAME`。反馈目标从 quality 返回的键选择，反馈该目标最近建立的线路；后续连接自动重新选择，不固定节点，不关闭健康连接。可以使用 timeout、disconnect、unusable 或 unknown。质量记录可能因容量淘汰或进程重启或组配置重载消失；建立成功不证明加密应用请求成功。

## 多机协作

`proxy sync export/import/push/pull` 包含共享的 `adaptive.json`（含服务域名和允许地区），但导出清除 `verified_regions`，导入仅保留接收机器已有且仍被允许的出口核对证据。不包含内核目录、质量记录、cache.db、控制器认证信息或二进制路径。导入 portable 设置也会过滤不允许的键。配置包包含订阅信息，应当继续作为私密文件处理；导入只接受已知普通文件，拒绝路径穿越与链接。

偏好在下一次订阅/节点池刷新时重放，失败生成或校验不会替换运行配置。SSH push 需要远端已安装当前版本的 proxy，通过远端 CLI 完成验证和导入。不同架构机器各自选择兼容发行资产，不能复制当前机器的内核路径。

父仓库提供 `scripts proxy ...` 直接调用这些接口；`scripts install proxy ...` 安装，`scripts update` 更新代码及子模块提交，均不等同于内核升级。

## 已验证

- 管理层行为测试：来源保持、明确切换、校验失败保留、配置变化保护、回退、异常中断恢复、运行保护、质量认证、同步隔离与不安全配置包拒绝。
- 真实官方内核与实验内核的校验、切换和回退通过。
- 完整命令流程验证 TLS 1.3 流：候选生成、启用、质量查询、反馈换线、建立故障恢复、健康流保留、订阅候选重放与官方回退。
- 真实内核接受生成的块式 YAML、TCP 条件规则与 no-resolve；父仓库命令参数（包括空格路径）及错误码透传验证通过。

重跑：`python3 -m unittest discover -s tests/unit -v`。完整隔离流程：

```bash
python3 tests/integration/managed_routing_probe.py \
  --kernel /path/to/validated-adaptive --official /path/to/official-v1.19.32
```

## 稳定性与后续发行

持续 Codex 对话已计入用户观察到的业务使用，不代表同一 socket 复用。60 秒 TLS 流、60 秒空闲、故障恢复、组重载/节点删除验证见 [结果](../research/stability-results.json)。原有结果没有 Antigravity 原生验收；2026-10-16 地区故障已有独立应用验收。TUN/UDP/QUIC 不在当前 TCP 自动选路的验收范围内。

低频业务探测、日志轮转与反馈记录见 [健康监测](health.md)。后续内核源码与稳定版升级流水线以 [aruiplex/mihomo](https://github.com/aruiplex/mihomo) 为唯一权威；本仓库冻结原型补丁以便复现旧结果。CI 候选只在隔离夹具中验证，准备版本与本机启用分开。

新 fork 候选支持共享偏好字段 `quality_persistence:true` 和 `quality_ttl:86400`，分别生成组配置 quality-persistence/quality-ttl；默认不启用持久化。旧 prototype.2 不支持这些字段，不应在旧版本上认为已经保存历史。新内核用私有文件、24 小时 TTL、容量限制、节点配置/凭据/订阅身份变更失效和坏文件冷启动维护本机历史。它不属于 sync 导出的质量数据；同步的是启用意图，接收端需要支持的新内核。当前本机仍使用内存记录。

`v1.19.32-adaptive.3` 已通过 [fork CI](https://github.com/aruiplex/mihomo/actions/runs/38164329436)，15 份夹具报告共 141 项检查，下载摘要与离线 manifest prepare 已验证；见 [发行证据](../research/fork-candidate-results.json)。CI 离线资产中的 manifest.local.json 使用相对文件名，可与同目录二进制一起下载后 prepare；manifest.json 的发行 URL 只在明确发布候选后有效。

2026-10-12 已在独立 systemd 恢复保护下完成本机切换。三个公开目标各两次 HTTPS 请求、同一 ChatGPT TLS socket 的四次请求及十秒空闲、本机 Codex 完整响应，以及执行进程结束后的独立 TLS 检查通过；新内核 PID 未变、重启次数为 0。见 [上线验收](../research/candidate3-deployment-results.json)。Codex 继承本机代理环境，但未独立归属其模型后端 socket，不把公开探测视为 AI 语义成功的证明。当前仍使用内存质量记录；`kernel rollback` 指向 prototype.2 的匹配快照，原 1.19.29 快照也保留在本机发行目录。版本切换不迁移已有 TCP 连接，维护期间应用需要重连。
