# 目标级自动选路原型

对应 [proxy #3](https://github.com/aruiplex/proxy/issues/3)。这是隔离验证用的 mihomo 补丁，尚未接入日常 proxy 命令或替换运行中的内核。

## 已实现

新增 `adaptive` TCP 代理组，按目标地址维护临时失败记录。建立连接失败时在同一次调用中尝试其他候选，每个候选只尝试一次，受总耗时、单候选耗时与候选数上限约束。失败返回带 `Retryable() == false` 的错误，避免 tunnel 外层十次重试放大预算。

优先使用无近期故障证据的线路，然后参考节点健康状态和地区。默认沿用该目标最近成功线路的地区，先尝试同地区候选，再尝试其他地区。延迟不参与排序。失败和用户反馈只影响后续连接，不关闭已经建立的连接。

失败证据默认限定为目标与节点；只有至少三个不同主机近期失败才降低节点在其他目标上的优先级。同一主机的不同端口不算独立证据。冷却到期重新允许尝试，成功建立连接清除对应临时惩罚。历史只在当前进程内存中保存，记录数和事件数都有上限，不同步到其他机器。

目标来自连接原始元数据，在 hosts/DNS 规范化之前通过 context 保留域名；没有域名时使用 IP。目标键为 `host:port`，IPv6 使用方括号。不会自动把不同域名归为同一服务，避免反馈扩大范围。

保留现有规则匹配顺序。显式 `DIRECT` 规则直接绕过该组。配置 `DIRECT` 为第一个候选时，公开目标建立直连失败可尝试代理；私网、回环、链路本地、多播及本地域名不会从这个 DIRECT 优先池切到代理。未解析域名先在总预算内检查 DNS；包含私网地址或无法判定时保持 DIRECT-only。这是保守策略，未知 DNS 结果不会被当成公开目标。日常配置仍需保留 LAN/显式直连规则。

## 配置与反馈接口

在已有节点定义中引用节点名称；不要嵌套其他策略组。地区由配置指定，原型不从节点名称猜测地区，也不验证服务的地区支持范围。

```yaml
proxy-groups:
  - name: AUTO
    type: adaptive
    proxies: [sg-a, sg-b, us-a]
    preferred-region: SG
    regions: {sg-a: SG, sg-b: SG, us-a: US}
    max-attempts: 3
    dial-budget: 6000          # 毫秒，总预算
    attempt-timeout: 2000      # 毫秒，单候选预算
    failure-cooldown: 30000    # 毫秒
    max-records: 4096          # 目标/节点记录数上限
```

控制接口沿用 mihomo 的认证机制。隔离测试只绑定回环地址。

- `GET /proxies/AUTO/quality`：返回建立失败、建立成功、传输错误、关闭及反馈事件；关闭包含持续时间和观察到的收发字节。
- `POST /proxies/AUTO/feedback`：请求体为 `{"target":"example.com:443","reason":"timeout"}`。反馈该目标最近实际建立的线路，之后重新自动选择；不会指定或固定节点，也不关闭现有连接。
- `reason` 接受 `unknown`、`timeout`、`disconnect`、`unusable`。目标键应从 quality 返回值选择；未观察到或已被容量淘汰的目标返回 400。

`established` 表示出站 `DialContext` 及所需协议头写入完成。有些协议不确认远端目标连接，这个事件不代表目标一定已连通。加密业务请求是否成功仍为未知。EOF、主动关闭和调用方设置的超时不直接当作坏节点；已知传输错误会记录为目标/节点证据，但不推断根因。底层超时无法区分来源时只记录 `transport-timeout-unknown`。关闭观测是关闭调用时的累计值，不能作为完整审计日志；有限事件窗口可轮转。

## 可复现构建

基线固定为官方 [v1.19.32](https://github.com/MetaCubeX/mihomo/tree/v1.19.32)，提交 `88dcbf7f1614a67c3b36b848ee3592dfa92ada36`。源码包、补丁摘要和 Go 工具链见 `baseline.json`。构建不带 `with_gvisor`，仅验证 Linux/amd64。

需要 Python 3.12+、Git 和 Go launcher。脚本固定 `GOTOOLCHAIN=go1.27.2`；缺少该版本时 Go 可能下载工具链。首次构建也会下载锁定的 Go 模块依赖。

在 proxy 仓库运行：

```bash
python3 prototypes/adaptive-routing/build.py \
  --output /tmp/mihomo-adaptive \
  --work-dir /tmp/mihomo-adaptive-source
python3 tests/integration/routing_probe.py \
  --kernel /tmp/mihomo-adaptive --group adaptive --failure-scope target
python3 tests/integration/routing_probe.py \
  --kernel /tmp/mihomo-adaptive --group adaptive --failure-scope all
python3 tests/integration/adaptive_checks.py --kernel /tmp/mihomo-adaptive
```

输出二进制路径和保留源码目录必须不存在。可以用 `--source-archive /path/to/source.tar.gz` 复用本地源码包，仍会核对摘要。脚本先检查 `git apply --check`，运行新增策略的 race 测试及相关包回归，再构建，最后原子创建新二进制，拒绝覆盖已有文件。`--skip-tests` 仅用于构建，不代表验证通过。

这组命令只产生实验二进制；日常内核激活与来源保留由 [proxy #4](https://github.com/aruiplex/proxy/issues/4) 后续处理。

## 验证结果与限制

2026-10-10 至 2026-10-11 在隔离环境完成：

- 14 个 Go 行为测试通过 `-race`，覆盖目标隔离、地区优先、冷却恢复、独立主机证据、反馈保留连接、事件轮转、容量、并发、传输重置、主动取消、DIRECT 约束和延迟握手保护。
- 真实内核的目标故障、整节点故障各运行两次，每次 11 项检查全部通过：坏节点 1 次、备用节点 1 次；反馈和短暂空闲均保留健康流。
- 三候选地区、立即拒绝和握手停滞场景各运行两次：先同地区，必要时跨区；最多两个候选；250 毫秒总预算下握手停滞约 251 毫秒返回，外层没有重复尝试；原有流保留。
- 新目录重建及补丁摘要校验通过；关闭 VCS 自动元数据后，两次干净构建的二进制 SHA-256 一致。结果保存在 `results.json`。
- 上游 `go test ./... -timeout 90s` 在清除 `HTTP_PROXY/HTTPS_PROXY/ALL_PROXY` 及其小写形式，并设置 `SKIP_INTEROP_TEST=true SKIP_CONCURRENT_TEST=true` 后通过。首次继承代理环境时 Sudoku HTTPMask 测试返回 502，未打补丁的原版同样复现；清除代理变量后该测试通过。互操作及压力测试未宣称通过。

延迟握手现在会在同一个候选预算内执行 `Write(nil)`，只发送协议头，不传入应用数据；用 context 取消与临时 deadline 限制它的耗时，完成后清除临时 deadline。仍不能完成握手的连接记录为 `unsupported`，不会将协议不支持当作线路失败。已发送业务数据后，不会在内核中重复请求。原型也不读取返回内容来判断加密业务是否成功。

当前固定构建版本为 `v1.19.32-adaptive-prototype.2`。SS aes-128-gcm、VMess TCP/TLS、VLESS TCP/TLS、Trojan TLS、VMess/VLESS WebSocket early-data 共 8 种组合通过双内核夹具。VLESS 明文传输仅限回环测试，并显式设置 `allow-insecure`；每种组合内承载的业务流均使用证书验证的 TLS 1.3。Trojan、VMess TLS 和 VLESS TLS 的代理 TLS 层也验证了测试证书摘要。

12 次协议运行（8 个连接拒绝场景，以及两种 WebSocket 的握手拒绝场景各两次）检查：建立故障换线、已有 TLS 流保留、目标反馈不关闭其他健康流、响应丢失后业务操作只提交一次。POST 同时覆盖 TLS 中已建立的连接，以及与 CONNECT 合并发送、提前进入首次 peek 缓冲区的明文请求。服务端先记录操作再丢弃响应，避免把“从未发出请求”误判成“不重放”。稳定结果见 `protocol-results.json`。

协议复验需要同样固定的官方服务端内核，以及 OpenSSL CLI 用来生成一次性测试证书；不使用真实凭据和订阅。服务端规则只允许回环目标的三个夹具端口，其余目标 REJECT。

```bash
python3 tests/integration/protocol_probe.py \
  --kernel /tmp/mihomo-adaptive --server-kernel /path/to/official-v1.19.32 \
  --protocol trojan
python3 tests/integration/protocol_probe.py \
  --kernel /tmp/mihomo-adaptive --server-kernel /path/to/official-v1.19.32 \
  --protocol vmess-ws-early --failure-mode ws-reject
```

UDP、QUIC、TUN、长时间空闲、Reality/Vision、其他插件/多路复用组合、跨机器状态、历史持久化及真实 Codex/Antigravity 业务尚未验证。部分协议没有目标连接确认，因此响应期失败仍可能需要应用重新建立连接；不能承诺将已中断的连接无缝迁移或重复请求。这些限制与待完成的内核来源管理意味着原型仍不能直接替换日常内核。

## 之后如何同步上游

当前补丁触及 7 个文件：新策略实现、行为测试、配置解析、类型枚举、原始目标 context key、控制接口和 tunnel 的重试终止检查。保留源包和补丁的分离，使修改范围可以审核；这并不证明未来升级没有冲突。

升级流程是选择新的官方版本，核对并记录源码摘要，将补丁移植到新源码，处理编译/接口差异，重新运行行为测试、相同内核夹具和相关上游回归，最后再产生新发行物。源包摘要或补丁不匹配时构建会失败，不会自动漂移到 latest。增加出站协议支持之前，还需要验证握手阶段、业务数据写入边界和协议错误分类。
