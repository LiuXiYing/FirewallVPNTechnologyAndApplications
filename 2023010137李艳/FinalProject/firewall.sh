#!/bin/bash
FW_CMD="sudo ip netns exec fw"

# 清空原有规则，初始化
echo "清空旧防火墙规则与NAT规则"
$FW_CMD iptables -F FORWARD
$FW_CMD iptables -t nat -F
$FW_CMD iptables -P FORWARD ACCEPT

# 全局默认策略：FORWARD最终默认拒绝所有转发
$FW_CMD iptables -P FORWARD DROP

# 状态检测：允许已建立、关联的回程流量
$FW_CMD iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# ========== Office区域规则 ==========
# 允许office 10.20.0.0/24 访问 dmz 10.40.0.2 的8080端口
$FW_CMD iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz -s 10.20.0.0/24 -d 10.40.0.2 -p tcp --dport 8080 -j ACCEPT
# 拒绝Office访问DMZ的22端口，先记录日志，再REJECT
$FW_CMD iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz -s 10.20.0.0/24 -d 10.40.0.2 -p tcp --dport 22 -j LOG --log-prefix "OFFICE_DENY_SSH:"
$FW_CMD iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz -s 10.20.0.0/24 -d 10.40.0.2 -p tcp --dport 22 -j REJECT

# ========== Guest访客隔离规则 ==========
# Guest禁止访问Office内网
$FW_CMD iptables -A FORWARD -i veth-fw-guest -o veth-fw-office -j LOG --log-prefix "GUEST_DENY_OFFICE:"
$FW_CMD iptables -A FORWARD -i veth-fw-guest -o veth-fw-office -j REJECT

# Guest禁止访问DMZ服务区
$FW_CMD iptables -A FORWARD -i veth-fw-guest -o veth-fw-dmz -j LOG --log-prefix "GUEST_DENY_DMZ:"
$FW_CMD iptables -A FORWARD -i veth-fw-guest -o veth-fw-dmz -j REJECT

# ========== 内网 NAT配置 SNAT+DNAT ==========
# SNAT：三个内网上网地址伪装访问外网internet
$FW_CMD iptables -t nat -A POSTROUTING -s 10.20.0.0/24 -o veth-fw-inet -j MASQUERADE
$FW_CMD iptables -t nat -A POSTROUTING -s 10.30.0.0/24 -o veth-fw-inet -j MASQUERADE

# DNAT：外网8080端口映射dmz服务器
$FW_CMD iptables -t nat -A PREROUTING -i veth-fw-inet -p tcp --dport 8080 -j DNAT --to 10.40.0.2:8080
$FW_CMD iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -j ACCEPT

# 外网禁止访问office内网
$FW_CMD iptables -A FORWARD -i veth-fw-inet -o veth-fw-office -j REJECT
# 外网禁止访问DMZ的22端口
$FW_CMD iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 22 -j REJECT

echo "带LOG日志防火墙规则部署完成！"
echo "查看转发规则：sudo ip netns exec fw iptables -L FORWARD -n --line-numbers"
echo "查看系统日志：sudo ip netns exec fw dmesg | grep DENY"