# 业务健康证据与日志维护

`proxy health check` 探测 ChatGPT、Google、Gemini 的公开 robots.txt：证书有效、HTTP 200、非空完整响应，每个目标 10 秒总预算。不读取应用登录信息、保存正文、重放业务请求、切换节点或重启内核。`proxy health status` 只读取最近结果。

`proxy health install` 安装用户级 timer，每 5 分钟运行。进程消失立即记异常；控制器、探测自身及业务目标连续失败 3 次确认异常，连续正常 2 次记录恢复。只在确认状态改变时通过 journal 和可用的本机桌面通知发消息。同一目标的失败计数不因其他目标间歇失败而重置。报告 systemd 退出状态/信号、重启次数及重启限流事件（不同 systemd 版本的 Result 可能仍为 exit-code）；现有 systemd 负责进程退出重启，监测没有自动重启逻辑。

所有目标失败且两个独立公网 TCP 控制均不可达时分类为 network_or_all_routes_failure，仍不能据此断定全球断网。单目标失败可能来自服务、出口或链路。质量事件按类型/原因汇总，包含匿名事件摘要用于关联；单节点证据来自内核事件，不能仅凭 HTTPS 超时确定节点是根因。目标和节点标签不写入监测报告。

本机状态在 CONF_DIR/health/，目录 700、文件 600，原子替换、串行加锁。事件到 10 MiB 后保留一份上一段日志。`proxy health uninstall` 禁用 timer，保留证据。程序执行异常分类 monitor_error，与内核故障区分。

```bash
proxy health check
proxy health status
proxy health install
proxy health record --app codex --outcome complete
proxy health record --app antigravity --outcome timeout
```

业务反馈只记应用、时间、完整响应/超时/断流，不保存 token、内容或请求标识。2026-10-12 持续 Codex 对话已记录为用户观察到的业务使用；不证明同一 TCP/TLS socket 复用，也未独立追踪模型后端路径。Antigravity 暂无独立完成验收。

`check --rotate`：日志达到 50 MiB 使用 copytruncate，最多保留 8 份、7 天；首次大于 500 MiB 的历史日志存为 logs/historical.log，不受常规清理影响。不降低日志级别、发送信号或重启。复制失败不截断；原追加 fd 继续写入同一 inode。与 logrotate copytruncate 一样，复制与截断之间存在极短的并发日志丢失窗口，业务连接不受影响。历史日志含敏感访问信息，不应上传。

隔离 stability_probe.py 覆盖 60 秒证书验证 TLS 流、60 秒空闲和恢复、同地区/跨区、全部候选故障有限尝试、恢复、组重载/节点删除时保留健康流。已有 protocol_probe 覆盖响应丢失后 POST 不重放。这里模拟新连接路径中断，不能证明物理断线后的 TCP 迁移；TUN/UDP/QUIC 尚未验证。

真实监测夹具还验证了：进程/控制器正常而 TLS 请求持续超时、恢复、探测程序不可用、独立 systemd 服务退出码 23/重启限流、SIGKILL 信号 9。见 [监测结果](../research/health-results.json)。journal 只提取 systemd 的结构化退出/限流事件，不写入原始消息。
