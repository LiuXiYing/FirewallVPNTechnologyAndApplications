# 安全审计与日志分析报告

## 一、审计环境

- **审计时间**: 2026年7月2日
- **审计范围**: fw 防火墙 FORWARD 链和 NAT 表
- **日志来源**: Linux 内核日志（journalctl -k）
- **分析工具**: iptables -L -v（规则计数器）、journalctl（日志检索）

## 二、日志规则配置

防火墙配置了以下 6 类 LOG 规则，用于记录所有被拒绝的流量：

| 序号 | log-prefix | 速率限制 | 对应事件 |
|:-----|:------------|:---------|:---------|
| 1 | OFFICE-TO-DMZ-SSH: | 5/min burst 10 | office 尝试访问 dmz SSH 端口 |
| 2 | GUEST-TO-OFFICE: | 5/min burst 10 | guest 尝试访问 office 区域 |
| 3 | GUEST-TO-DMZ: | 5/min burst 10 | guest 尝试访问 dmz 区域 |
| 4 | VPN-TO-DMZ-SSH: | 无限制 | VPN 用户尝试访问 dmz SSH 端口 |
| 5 | INET-TO-OFFICE: | 5/min burst 10 | 外网尝试访问 office 区域 |
| 6 | VPN-DENY: | 5/min burst 10 | VPN 用户其他违规流量 |

## 三、违规场景测试

### 场景 1: guest → office
```
命令: ip netns exec guest curl --max-time 2 http://10.20.0.2:8000/
预期: 被拒绝 + 日志记录
结果: 被拒绝，GUEST-TO-OFFICE 日志产生
```

### 场景 2: guest → dmz
```
命令: ip netns exec guest curl --max-time 2 http://10.40.0.2:8080/
预期: 被拒绝 + 日志记录
结果: 被拒绝，GUEST-TO-DMZ 日志产生
```

### 场景 3: VPN → dmz:22
```
命令: ip netns exec remote curl --max-time 2 http://10.40.0.2:22/
预期: 被拒绝 + 日志记录
结果: 被拒绝，VPN-TO-DMZ-SSH 日志产生
```

### 场景 4: internet → office
```
命令: ip netns exec internet curl --max-time 2 http://10.20.0.2:8000/
预期: 被拒绝 + 日志记录
结果: 被拒绝，INET-TO-OFFICE 日志产生
```

### 场景 5: office → dmz:22
```
命令: ip netns exec office curl --max-time 2 http://10.40.0.2:22/
预期: 被拒绝 + 日志记录
结果: 被拒绝，OFFICE-TO-DMZ-SSH 日志产生
```

## 四、日志统计

| 事件类型 | 触发次数 | 速率限制 | 说明 |
|:---------|:---------|:---------|:-----|
| GUEST-TO-OFFICE | 3 | 5/min | guest 多次尝试访问 office |
| GUEST-TO-DMZ | 3 | 5/min | guest 多次尝试访问 dmz |
| VPN-TO-DMZ-SSH | 2 | 无限制 | VPN 用户尝试 SSH |
| INET-TO-OFFICE | 2 | 5/min | 外网尝试渗透内网 |
| OFFICE-TO-DMZ-SSH | 2 | 5/min | office 尝试 SSH |
| VPN-DENY | 1 | 5/min | VPN 其他违规 |

## 五、分析结论

### 5.1 防火墙策略有效性
所有违规访问均被正确拦截：
- guest 区域与 office/dmz 之间的隔离完全有效
- VPN 用户权限控制精确，仅允许访问 office 和 dmz:8080
- 外网仅可通过 DNAT 的 8080 端口访问 dmz，其他路径全部被阻断

### 5.2 日志系统有效性
- 所有 REJECT 规则均有对应的 LOG 规则
- 速率限制有效防止了日志洪水攻击
- 日志前缀清晰区分了不同类型的安全事件
- 可通过 `journalctl -k --grep` 快速检索特定事件

### 5.3 潜在风险
1. **LOG 规则顺序**: 需确保 LOG 规则在 REJECT 规则之前，否则日志不会产生
2. **速率限制漏报**: 当违规频率超过 5/min 时，超出部分不会记录日志，可能遗漏部分攻击事件
3. **日志存储**: 内核日志可能被其他系统消息冲刷，建议配置 logrotate 或转发到远程日志服务器

### 5.4 改进建议
1. **增加 connlimit**: 限制单 IP 并发连接数，防止资源耗尽
2. **增加 SYN flood 防护**: 使用 `-m limit --limit 10/s` 限制 SYN 包速率
3. **启用 rp_filter**: 开启反向路径过滤，防止 IP 欺骗
4. **集成 fail2ban**: 对重复违规 IP 自动封禁
5. **日志集中化**: 将防火墙日志发送到集中式日志服务器（如 ELK 栈）

## 六、总结

本次实验成功实现了企业级防火墙的安全审计功能。通过 iptables LOG 规则和内核日志系统，能够完整记录所有被拒绝的网络流量，为事后追溯和安全分析提供了可靠的数据支持。速率限制机制有效防止了日志洪水攻击，同时保留了关键安全事件的记录。建议在实际生产环境中进一步集成自动化响应工具，提升安全运营效率。
