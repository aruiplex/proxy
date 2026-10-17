# Linux：统一接入与受监督 TUN

TUN 在实际运行应用的机器上接管流量，解决非交互 SSH、GUI 或不读取代理环境的软件绕过本机代理的问题。无需为 agy、Codex 或每个新应用各自安装包装器。接管后仍按原规则直连、拒绝或代理；Google 服务的地区资格约束继续生效。

本机准备的默认范围是当前 UID 的应用；局域网、Tailscale 网段与其他 UID 不进入这次接管。Docker 容器的独立网络命名空间不在这一范围内。IPv4/IPv6 和 DNS 都需要验收，不能用 HTTP 端口正常代表透明流量可用。

默认使用内置的 `system` 栈。当前 adaptive.3 发行未包含 `with_gvisor`；`-t` 可能接受 gvisor 配置，但启动会禁用 TUN。设备与真实流量验收因此是必要步骤，不能以配置校验替代。

若本机 auto-redirect 的 nftables 初始化失败，可以在准备时加 `--no-auto-redirect`，继续使用 TUN 路由透明接入。两机工具提交保持一致，本机内核/防火墙适配参数允许不同；此模式仍须单独验证 DNS、域名识别及真实业务。

## 准备与一次管理员安装

```bash
proxy tun prepare --output "$HOME/.local/state/proxy-maintenance/tun-20261016"
```

该命令保留节点与规则原文，生成候选、`tun.json`、监督器身份、systemd unit 与 polkit 规则，并用当前内核 `-t` 校验。不会改变现用配置、停止服务或创建 TUN。目录含私密配置，保持 700，不提交或整包共享。

先审查输出中的 `proxy-mihomo-<UID>.service`、`49-proxy-mihomo-<UID>.rules`、`install-supervisor.sh`。管理员运行：

```bash
sudo bash "$HOME/.local/state/proxy-maintenance/tun-20261016/install-supervisor.sh"
```

安装器只安装、启用监督器文件；身份标记尚未应用时，unit 的 ConditionPathExists 会跳过启动，当前用户级服务继续工作。新服务使用应用用户运行，只有 CAP_NET_ADMIN/CAP_NET_RAW，限制能力集并设置 NoNewPrivileges。polkit 只允许该用户控制这一固定 unit 的 start/stop/restart，不授权修改 unit 文件，不增加执行用户可写程序的免密 root 规则。

## 首次迁移与验收

管理员安装不等于已启用 TUN。维护 Agent 应准备匹配当前配置、偏好、监督器标记及用户服务启用状态的快照，确认配置/内核摘要仍与 plan.json 相符。先建立工具会话之外的独立限时回退，再逐台迁移：

1. 停止匹配的用户级 proxy-mihomo.service，此时仍使用旧监督器身份。
2. 原子安装候选 config.yaml、本机 tun.json、supervisor.json。
3. 通过 systemctl 的 system scope 启动固定 unit，核对 PID、实际 TUN 设备、路由及控制器。新 unit 内部调用 CLI 时依据 cgroup 避免递归调用自身。
4. 禁用旧用户 unit，保留文件作为恢复材料。新 system unit 承担开机启动和异常重启。
5. 启动工具返回后，以独立调用验证真实 GPT/TLS、清空代理环境后的原生 AI 推理及其出站、DNS、IPv4/IPv6接入、全新 SSH/Tailscale 连接。实际业务已发送的数据不重放。
6. 验收通过才解除回退计时。失败则先停止 system unit，再恢复文件/标记及旧用户 unit 的启用状态，恢复旧监督器。需要管理员补救时使用安装 unit 的精确名字，避免停止另一配置的内核。

首次进程迁移会中断已有连接，应逐台执行。TUN 设备/路由验收需要实际网络权限；无权限的单元与隔离测试只证明准备、重放及失败恢复逻辑，不能宣称生产 TUN 已通过。

## 后续维护

完成首次迁移后，`proxy start/stop/restart` 使用本机 supervisor.json 选定的 system unit；监督器不可读、身份不符或操作失败均返回错误，避免启动第二实例。`proxy tun on/off` 通过已具备能力的进程重载配置，校验实际设备及控制器状态，失败恢复原配置，不切换为 sudo/nohup。

`tun.json` 是本机接入偏好，单订阅及节点池刷新在候选中重放；不参与共享偏好同步。保留现有 sniffer 设置，缺少时加入基本 HTTP/TLS 识别。局域网和 Tailscale 规则保留；新服务继续由默认规则与自动代理组承接，地区资格不能从加密的业务错误中自动推断。

同版本部署应固定 scripts 的 Git 提交和 proxy 子模块提交；两机节点、认证、出口核对及质量记录仍各自保留。修改源码或子模块 pin 不会自动升级内核或启用 TUN。
