# 连接稳定性优先的内核路线验证

验证日期：2026-10-10。对应 [proxy #1](https://github.com/aruiplex/proxy/issues/1)，集成需求见 [scripts #1](https://github.com/aruiplex/scripts/issues/1)。

## 结论

推荐以官方正式版本为基线，设计独立的目标级自适应选路能力，并保留健康连接。当前官方策略组不满足全部需求；所检查的 Smart 分支也不能直接用于此场景。

这不是某个真实 Codex 或 Antigravity 超时的根因诊断。它验证的是实际内核在本地可控出站发生故障时的行为。尚未替换用户运行中的内核。

## 基准与隔离方式

| 项目 | 官方 | Smart |
| --- | --- | --- |
| 源码基准 | MetaCubeX/mihomo v1.19.32 | vernesong/mihomo 319f30245950e34bc66e65d8a933591b1ebbe08d |
| 实际二进制版本 | v1.19.32 / go1.26.8 | alpha-smart-319f302 / go1.26.8 |
| 资产 | mihomo-linux-amd64-compatible-v1.19.32.gz | mihomo-linux-amd64-compatible-alpha-smart-319f302.gz |
| 下载包 SHA-256 | ba3ce607747a07f948fc35780e108a4a7c7f552a38b9bd4d115f313ebcb89c20 | 4ca5b691841a3a8fc32cd0e4c264eec9270f5d06c52635e9a1d2e876746d2545 |

摘要与 GitHub Release API 中公布的 digest 比对通过。Smart 的发行标签会移动，复验时必须核对提交及摘要，不能只按标签名称下载。

测试使用独立内核进程、临时配置/状态目录、回环控制接口和代理端口，关闭 TUN。两个 HTTP CONNECT 出站夹具只允许转发到本地目标与健康检查夹具；其他探测被拒绝并记录。测试没有读取真实订阅、凭据、用户配置或业务流量。

夹具将“节点拒绝所有新连接”和“节点仅拒绝业务目标，健康检查仍成功”分开。目标与健康检查使用不同端口，因此即使内核将域名解析为同一个回环 IP，故障注入也能准确区分二者。已经建立的夹具连接继续传输，模拟新连接失败而旧连接仍健康的情况。

## 实测结果

最终固定夹具对以下五个场景各运行两次，表中结果在两次运行中一致：

| 场景 | 当前新连接 | 原健康流 | 后续连接/反馈 |
| --- | --- | --- | --- |
| 官方 select：切换节点 | 新连接走另一个节点 | 保留 | 短暂空闲后恢复传输；显式关闭负对照能检测中断 |
| 官方 fallback：节点整体失败，max-failed-times=5 | 同一坏节点尝试 10 次后失败，备用节点 0 次 | 保留 | 主动健康检查后恢复 |
| 官方 fallback：节点整体失败，max-failed-times=1 | 两次重复均未恢复，同一坏节点尝试 10 次 | 保留 | 主动健康检查后恢复 |
| 官方 fallback：仅目标失败，max-failed-times=1 | 同一坏节点尝试 10 次后失败，备用节点 0 次 | 保留 | 测速仍成功，后续连接仍失败 |
| Smart：仅目标失败 | 坏节点 2 次、备用节点 1 次后恢复 | 被关闭 | 对一个连接提交反馈后，同目标另一个健康连接也关闭 |

降低失败阈值的早期探索运行曾恢复当前连接，但最终固定夹具重复未恢复，不能把该配置当作恢复保证。核心结论是：健康检查成功并不代表特定业务目标可用；仅调整阈值无法补足目标级故障处理。

退出码 1 表示至少一个要求未满足，并不是夹具启动失败。脚本要求确认故障注入实际被触发，避免没有经过坏线路的运行被当作恢复成功。原始运行结果的稳定字段保存在 `routing-kernel-results.json`。

## 源码与维护成本

官方 [Fallback.DialContext](https://github.com/MetaCubeX/mihomo/blob/v1.19.32/adapter/outboundgroup/fallback.go#L34) 每次选择健康检查认为可用的节点；失败触发健康检查机制。它没有在该函数内维护当前目标的失败候选集合。这与“健康检查正常时持续重试原节点”的实测相符。

Smart 的 [adoptUnwrapWinner](https://github.com/vernesong/mihomo/blob/319f30245950e34bc66e65d8a933591b1ebbe08d/adapter/outboundgroup/smart.go#L471) 及 [closeSameConnection](https://github.com/vernesong/mihomo/blob/319f30245950e34bc66e65d8a933591b1ebbe08d/adapter/outboundgroup/smart.go#L1945) 包含主动关闭同目标其他连接的路径。实测表明它与保留健康流的要求冲突。

GitHub 对固定 Smart 提交与官方 v1.19.32 的比较包含 72 个文件、12,920 行新增；其中 `adapter/outboundgroup/smart.go` 和 `component/smart/` 合计新增 10,739 行。该比较也可能包含正式版本之后的上游变化，不能将全部差异都归为 Smart 功能，但足以说明这不是一个仅修改几行选路逻辑的候选方案。[固定基准比较](https://github.com/vernesong/mihomo/compare/MetaCubeX:v1.19.32...319f30245950e34bc66e65d8a933591b1ebbe08d)

因此，直接采用该分支还需要审查和修改连接关闭、目标归并、评分与反馈路径，验证状态格式和升级兼容性，不能只删除一个 Close 调用后就宣布完成。

## 后续实施边界

1. 官方基线上的目标级策略：建立连接阶段有界尝试候选，记录目标与节点的失败证据；默认不关闭健康连接。先以本报告的失败场景作为验收，再扩展同地区优先、冷却恢复等能力。
2. 观测接口：能够记录建立失败及连接生命周期；正常关闭、空闲和业务失败需要区分，不声称代理层能判断全部加密请求的语义结果。
3. proxy 管理层：目标反馈、本机质量记录、解释和地区偏好；提供内核来源、版本锁定、兼容配置和回退。
4. scripts 集成：在 proxy 接口明确后同步共同配置与偏好，质量记录保持本地。

未验证真实 TLS/QUIC、UDP、TUN、服务支持地区、长时间空闲、跨地区策略、历史持久化、评分误判率或真实 AI 请求成功率。上述事项仍需后续实现和验证；本报告没有承诺已经解决它们。

## 复验

只依赖 Python 标准库和准备好的内核二进制：

```bash
python3 tests/integration/routing_probe.py --kernel /path/to/official-mihomo --group select
python3 tests/integration/routing_probe.py --kernel /path/to/official-mihomo --group fallback
python3 tests/integration/routing_probe.py --kernel /path/to/official-mihomo --group fallback --max-failed-times 1
python3 tests/integration/routing_probe.py --kernel /path/to/official-mihomo --group fallback --max-failed-times 1 --failure-scope target
python3 tests/integration/routing_probe.py --kernel /path/to/smart-mihomo --group smart --failure-scope target
```

通过 `--output /tmp/result.json` 保存结果。`--keep-dir` 必须指向不存在的目录，用于保留夹具配置与内核日志；否则临时目录自动删除，所有测试进程及夹具在退出时清理。
