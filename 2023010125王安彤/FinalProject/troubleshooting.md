## 一、报告说明
本文档记录实验过程中 3 类典型网络故障，包含故障现象、复现步骤、分层排查流程、根因定位、修复方案、原理总结，覆盖 DNAT 端口映射、WireGuard VPN、TCP 状态跟踪三大核心模块，适用于企业边界网络运维故障排查参考。

## 二、故障场景 1：DNAT 规则配置完成，外网无法访问 DMZ 8080
2.1 故障现象
iptables nat 表可查询到完整 DNAT 端口映射规则；
DMZ 主机正常启动 python 8080 Web 服务，本地访问正常；
外网 internet 主机执行curl http://203.0.113.1:8080持续超时，无页面返回；
无相关访问日志输出。

2.2 分层排查步骤
核查 nat 表 PREROUTING DNAT 规则：确认端口、目标 IP 书写无误；
在 fw 公网 veth-fw-inet 接口抓包：确认外网请求数据包抵达防火墙；
查询 conntrack 连接跟踪表：无 DNAT 转换后的会话记录；
核查 FORWARD 链：缺少外网访问 DMZ 8080 的放行规则；
手动添加对应 FORWARD 规则后访问恢复正常。

2.3 故障根本原因
DNAT 仅修改数据包目的地址，转发动作依赖 FORWARD 链放行规则；缺少放行策略时，数据包完成地址转换后被 FORWARD 默认 DROP 策略丢弃。

2.4 修复命令
```bash
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
```

2.5 排查总结
配置端口映射 DNAT 时，必须配套对应网段、端口的 FORWARD 放行规则，双向流量才可正常通行。
## 三、故障场景 2：WireGuard 隧道握手成功，但 VPN 无法访问内网业务
3.1 故障现象
执行wg show查看隧道，latest handshake 存在有效时间戳，收发数据包存在传输计数；
remote 客户端 ping 办公网段 10.20.0.1、DMZ 10.40.0.2 全部超时；
内核无 VPN-DENY 拦截日志输出。
3.2 多维度排查方向
检查 remote 客户端 wg0.conf 中 AllowedIPs 字段，是否包含目标内网网段；
核查 fw 防火墙是否配置 wg0 入站流量的 FORWARD 放行规则；
确认办公 / DMZ 主机默认网关是否正确指向防火墙 10.20.0.1/10.40.0.1；
检查 fw 内核 ipv4 转发开关net.ipv4.ip_forward=1是否开启。
3.3 高频故障根因
AllowedIPs 配置错误，未添加 10.20.0.0/24、10.40.0.0/24，内网流量未走隧道；
防火墙未添加 VPN 访问办公 / DMZ 的专用放行规则，数据包被默认 DROP；
3.4 修复示例（补充 VPN 放行规则）
```bash
# 允许VPN访问办公区
sudo ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-office -s 10.10.10.2 -d 10.20.0.0/24 -m conntrack --ctstate NEW -j ACCEPT
# 允许VPN访问DMZ 8080
sudo ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
```
3.5 排查总结
WireGuard 握手仅代表加密通道连通，业务访问依赖路由配置、防火墙权限、内核转发三层配置，隧道正常不代表业务可达。
## 四、故障场景 3：删除 ESTABLISHED/RELATED 规则后所有 TCP 访问失效
4.1 故障现象
客户端 SYN 握手包可成功发送抵达服务器；
服务器回复 SYN-ACK 回程报文被防火墙丢弃；
curl、ping 等 TCP 应用长时间超时，无任何响应。
4.2 抓包验证
在 fw 内网接口抓包：可观测客户端 SYN 入站，服务器 SYN-ACK 出站报文被丢弃，无回程流量返回客户端。
4.3 故障根本原理
TCP 为双向有状态通信，ESTABLISHED/RELATED 规则自动放行会话回程响应报文；删除该规则后，防火墙仅放行手动配置 NEW 新建连接，服务器回包无匹配规则，直接 DROP，完整 TCP 三次握手无法完成。
4.4 修复规则
```bash
sudo ip netns exec fw iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```
4.5 排查总结
状态跟踪规则是 iptables 防火墙基础必备规则，删除后所有 TCP 业务完全中断，所有业务场景必须优先配置。
## 五、实验过程其他常见故障汇总
5.1 重复执行 setup.sh 出现 IP 地址冲突
现象：veth 网卡 IP 重复，跨网段 ping 不通；
根因：旧 namespace、虚拟网卡未清理残留；
解决：脚本开头增加批量删除 namespace、veth 设备命令，每次实验重置环境。
5.2 iptables 日志无任何输出
现象：违规访问正常阻断，但 journalctl 无对应日志；
根因：LOG 规则写在 REJECT/DROP 规则之后，数据包丢弃前未触发日志打印；
解决：调整规则顺序，所有日志规则放置阻断规则前置。
5.3 内网主机无法访问外网（SNAT 失效）
现象：内网 ping 公网超时，外网无应答；
根因：MASQUERADE SNAT 规则网段书写错误，内网流量未做源地址转换；
解决：为 office、guest、DMZ 分别配置独立 POSTROUTING 转换规则。
## 六、故障排查通用方法论总结
分层定位：物理链路→IP 路由→防火墙规则→NAT 转换→应用服务；
工具定位：ping 连通性、tcpdump 抓包、iptables 规则计数、conntrack 连接跟踪、journalctl 日志；
复现验证：修改单一项配置测试，缩小故障范围；
日志优先：内核审计日志可快速定位数据包丢弃节点与拦截规则；
最小配置复现：简化规则、网段，排除冗余配置带来的冲突问题。
企业网络故障遵循从底层网络层向上逐层排查思路，优先确认连通性与路由，再校验访问控制策略。