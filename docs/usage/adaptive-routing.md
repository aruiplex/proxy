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
  "source": {"id": "my-kernel-release", "kind": "custom"},
  "version": "v1.19.32-adaptive-prototype.2",
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

先按照 `prototypes/adaptive-routing/README.md` 构建已验证版本。导出 manifest 时必须与保存的验证摘要一致，不能把任意同名文件冒充成已验证原型：

```bash
python3 prototypes/adaptive-routing/release_manifest.py \
  --binary /tmp/mihomo-adaptive --output /tmp/adaptive-release.json
cp templates/adaptive.example.json /tmp/my-adaptive.json
proxy auto prepare --preferences /tmp/my-adaptive.json \
  --output /tmp/adaptive-candidate.yaml
proxy kernel prepare --manifest /tmp/adaptive-release.json --switch-source \
  --config /tmp/adaptive-candidate.yaml --preferences /tmp/my-adaptive.json
proxy kernel status
```

候选输出路径必须是新文件。默认接管 MATCH 所用代理策略的 TCP；同策略的其他规则也在原位置增加 TCP 条件，原规则保留给 UDP。规则条件、明确 DIRECT/REJECT、未选中的其他策略组继续保持原意。需要接管其他组时，在偏好 `policies` 中明确列出已有策略组名称。

偏好默认尝试公开目标直连，失败后尝试代理；私网目标保持直连，日常配置仍应保留 LAN/明确直连规则。测试夹具可用 `direct_first:false` 路由回环目标；日常使用这种设置时必须已有完整的 LAN 直连规则。`region_patterns` 根据用户配置的名字匹配生成地区记录，不验证节点实际地理位置或服务支持范围；可以用 `regions` 精确指定。provider 运行时产生的新名称未匹配静态地区映射时地区未知，仍可选路。质量记录始终由内核在本机独立维护。

支持 JSON 和常见块式 YAML。对不能安全理解的 YAML 结构会拒绝生成；最终使用候选内核 `-t` 验证。配置引用的资源需要在本机状态目录中可用；状态目录内的资源绝对路径在校验副本中映射，原配置保持原路径。状态目录外的绝对路径或符号链接可能不符合临时副本的安全路径约束，会拒绝候选，不修改现有资源。

Linux 上若已安装用户级 `proxy-mihomo.service`，维护时由 systemd 管理进程：

```bash
systemctl --user stop proxy-mihomo.service
proxy kernel activate
systemctl --user start proxy-mihomo.service
```

不满意时先 `systemctl --user stop proxy-mihomo.service`，再 `proxy kernel rollback`、`systemctl --user start proxy-mihomo.service`。再次测试也必须先停该服务，避免端口冲突及监督进程重新拉起旧实例。其他环境应使用对应的长期进程监督器；普通交互终端的手动维护仍可用 `proxy stop`、`kernel activate/rollback`、`proxy start`，但 `nohup` 不保证进程能逃离执行工具的会话清理。

启动命令返回后，在**另一次调用**中验收，不能只检查启动时的 PID 和控制器：

```bash
python3 tests/integration/live_tls_acceptance.py \
  --root "$HOME/.config/mihomo" --proxy http://127.0.0.1:7890 \
  --expected-version v1.19.32-adaptive-prototype.2 \
  --url https://chatgpt.com/robots.txt --requests 3 --settle-seconds 10 \
  --report /tmp/proxy-live-tls-result.json
```

探测通过本机代理完成真实 ChatGPT HTTPS GET，校验证书、HTTP 200 和完整非空响应，并持续检查同一进程、代理端口和控制器。Linux 还核对两个监听端口属于该 PID，避免误把竞争实例的响应当作候选成功。网络、HTTP 状态或进程检查失败都会返回非零退出码；发生自动重启也不算同一次稳定运行。控制器须为本机回环地址，curl 需支持 `%{json}`。

默认 URL 为公开 `robots.txt`，不是登录后的 AI 业务；首页可能因访问策略返回 403，即使证书校验成功也不能计为 200。可用 `--url` 指定已知可用的公开 HTTPS 目标，禁止 URL 中携带凭据或查询参数。验收脚本不读取应用 Cookie/Token、不重启服务、不调整节点；登录后的 Codex/Antigravity 请求和长连接仍需要独立验收。当前实验构建未验证 TUN/QUIC/UDP 自适应；保留 UDP 原规则只保证配置策略不被改写，不等于已验证该业务。

2026-10-11 的[进程退出诊断记录](../research/kernel-exit-diagnosis.md)包含执行会话清理的官方/实验内核对照，以及启动健康后终止进程的失败验收。

## 查看质量与反馈

```bash
proxy quality
proxy quality --target 'example.com:443' --json
proxy feedback 'example.com:443' --reason timeout
```

存在多个 adaptive 组时用 `--group NAME`。反馈目标从 quality 返回的键选择，反馈该目标最近建立的线路；后续连接自动重新选择，不固定节点，不关闭健康连接。可以使用 timeout、disconnect、unusable 或 unknown。质量记录可能因容量淘汰或进程重启或组配置重载消失；建立成功不证明加密应用请求成功。

## 多机协作

`proxy sync export/import/push/pull` 包含共享的 `adaptive.json`，不包含内核目录、质量记录、cache.db、控制器认证信息或二进制路径。导入 portable 设置也会过滤不允许的键。配置包包含订阅信息，应当继续作为私密文件处理；导入只接受已知普通文件，拒绝路径穿越与链接。

偏好在下一次订阅/节点池刷新时重放，失败生成或校验不会替换运行配置。SSH push 需要远端已安装当前版本的 proxy，通过远端 CLI 完成验证和导入。不同架构机器各自选择兼容发行资产，不能复制当前机器的内核路径。

父仓库提供 `scripts proxy ...` 直接调用这些接口；`scripts install proxy ...` 安装，`scripts update` 更新代码及子模块提交，均不等同于内核升级。

## 已验证

- 22 个管理层行为测试：来源保持、明确切换、校验失败保留、配置变化保护、回退、异常中断恢复、运行保护、质量认证、同步隔离与不安全配置包拒绝。
- 真实官方内核与实验内核的校验、切换和回退通过。
- 完整命令流程验证 TLS 1.3 流：候选生成、启用、质量查询、反馈换线、建立故障恢复、健康流保留、订阅候选重放与官方回退。
- 真实内核接受生成的块式 YAML、TCP 条件规则与 no-resolve；父仓库命令参数（包括空格路径）及错误码透传验证通过。

重跑：`python3 -m unittest discover -s tests/unit -v`。完整隔离流程：

```bash
python3 tests/integration/managed_routing_probe.py \
  --kernel /path/to/validated-adaptive --official /path/to/official-v1.19.32
```
