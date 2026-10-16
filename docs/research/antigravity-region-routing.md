# Antigravity 地区错误 — 2026-10-16

任务：[proxy #12](https://github.com/aruiplex/proxy/issues/12)。[脱敏验收结果](antigravity-region-results.json)保留具体检查结果。

## 根因与证据

用户原生 Antigravity CLI 报 `FAILED_PRECONDITION: User location is not supported for the API use.`。现用配置只有两条明确直连、一条全 TCP 自动组规则和 MATCH；自动组包含 DIRECT。连接与质量记录确认 `daily-cloudcode-pa.googleapis.com:443` 最终经过 DIRECT，传输建立成功仍伴随业务地区错误。

原订阅保留 519 条规则，其中 Google 关键词明确走代理。节点池只抽取节点、沿用现有简化规则，自动配置又插入全 TCP 接管并允许 DIRECT，改变了原来的代理意图。默认地区正则没有匹配 `US06` 等节点名，实际地区表为空，也无法约束服务资格。这是本工具的配置整合错误，不能归因于提供商没写 Google 规则。

两家公开出口查询当时均把直连 IPv4 标为 HK；IPv6 查询超时。结果不能证明是大陆 IP，也不代表 Google 的内部分类。原生 agy 在原配置重复失败，经独立 CA 代理成功，恢复原配置再次失败，形成对照。Google 的[官方资格说明](https://antigravity.google/docs/faq)与可用地区应另行核对；公开 IP 分类不能替代原生业务验收。

## 实现约束

- 规则顺序及明确 DIRECT/REJECT 保留。自动组展开原代理策略中的可确定静态节点，多个策略各用自己的范围，不通过 include-all 扩到全局。无法确定的动态 provider 范围拒绝生成，避免猜测。
- 旧 direct_first 兼容读取但不再引入 DIRECT；候选耗尽为 REJECT，empty-fallback 同样为 REJECT。Mihomo 的[组配置](https://wiki.metacubex.one/en/config/proxy-groups/)默认空回退为 COMPATIBLE，因此只删除显式 DIRECT 还不够。
- 节点池以 pool_rules_source（默认 active_sub）保留唯一完整规则基准及缓存；补充订阅加节点，MATCH 策略接入节点池，专用策略保留自己的成员。基准缺失或组名冲突则失败，不生成简化规则。已有名称清理的错误 Unicode 范围同时修复，英文地区名能够保留并归一化。
- merge/region 先在候选中应用，之后才生成自动组，避免覆盖规则绕开资格约束或把已排除节点重新纳入。生成与校验失败保留现用文件。
- 地区提示用于偏好；服务允许地区先按本机核对的节点身份过滤。名称重编号保留身份，端点/凭据变化失效；格式变化可能保守失效。核对记录不自动过期，也不保证提供商背后的出口永久不变，新增/变化或业务报地区错误时重新核对。
- sync 导出服务意图并清除核对记录，导入保留接收端已有且仍被允许的记录。公开网络探测不等于应用资格，TLS 内的地区错误也不会自动被内核读取或重放请求。

当前资格约束只增加 TCP 条件；UDP/QUIC 保留原规则，未新增地区约束验收。新目标仍按规则与默认代理策略使用；未知服务的资格地区没有通用自动推断。操作字段见 [自动选路指南](../usage/adaptive-routing.md)。

## 验收与应用

- 隔离候选保留 519 条原订阅规则及两条本机前置规则，内核 -t 通过。
- 独立 CA 与 US 出口分别核对实际国家并完成原生 agy SUCCESS；两个额外 CA 候选无法连通，未使用。完整候选下 Google 推理连接进入专用自动组，再到已核对的出口。
- `policy_scope_probe.py` 在本地证书校验 TLS 夹具中验证：原策略范围、失败时不走未知地区/直连、空资格拒绝、允许地区间回退、重载和失败时健康流保留。
- `refresh_policy_probe.py` 通过真实 CLI 验证单订阅/节点池刷新、前置代理规则进入自动组、完整规则缓存和下载失败后的上次成功配置复用。
- 现用配置在独立 5 分钟 systemd 回退 timer 保护下热重载。重载前后的同一 ChatGPT TLS socket 都为 200。启动工具返回后，独立验收三次 ChatGPT HTTPS 200、同一 TLS socket、持续 PID/监听/控制器，以及原生 agy SUCCESS 和新 Google 推理连接的代理归属。
- 没有更新或重启内核；主 PID 和重启次数不变。微信 echo 服务未更改、未重启、未接入 agy 后端。验收后回退 timer 已解除，匹配备份保留，位置见 [交接](../maintenance-handoff.md)。

重跑管理测试和两个隔离夹具，不需要停止生产服务；夹具使用各自临时目录和端口：

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/unit -v
python3 tests/integration/policy_scope_probe.py --kernel /path/to/accepted-adaptive
python3 tests/integration/refresh_policy_probe.py --kernel /path/to/accepted-adaptive
```

内核源码与原有回退层保持原样。本轮只改管理和配置整合，不产生新的 Go 发行或改变 fork 的固定 CI 夹具 pin。
