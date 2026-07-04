#!/bin/bash
set -euo pipefail
FW_EXEC="sudo ip netns exec fw"

echo "[1] 清空fw命名空间原有filter、nat规则"
$FW_EXEC iptables -F
$FW_EXEC iptables -F -t nat
$FW_EXEC iptables -X
$FW_EXEC iptables -X -t nat
$FW_EXEC iptables -P FORWARD ACCEPT

echo "[2] 配置连接状态放行规则"
$FW_EXEC iptables -P FORWARD DROP
$FW_EXEC iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

echo "[3] 配置Office区域访问控制"
$FW_EXEC iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz \
    -s 10.20.0.0/24 -d 10.40.0.0/24 -p tcp --dport 8080 \
    -m conntrack --ctstate NEW -j ACCEPT
$FW_EXEC iptables -A FORWARD -i veth-fw-office -o veth-fw-inet \
    -m conntrack --ctstate NEW -j ACCEPT
$FW_EXEC iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz \
    -s 10.20.0.0/24 -d 10.40.0.0/24 -p tcp --dport 22 \
    -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: " --log-level 4
$FW_EXEC iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz \
    -s 10.20.0.0/24 -d 10.40.0.0/24 -p tcp --dport 22 \
    -j REJECT --reject-with tcp-reset

echo "[4] 配置Guest区域隔离策略"
$FW_EXEC iptables -A FORWARD -i veth-fw-guest -o veth-fw-inet \
    -m conntrack --ctstate NEW -j ACCEPT
$FW_EXEC iptables -A FORWARD -i veth-fw-guest -o veth-fw-office \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4
$FW_EXEC iptables -A FORWARD -i veth-fw-guest -o veth-fw-office -j REJECT
$FW_EXEC iptables -A FORWARD -i veth-fw-guest -o veth-fw-dmz \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "GUEST-TO-DMZ: " --log-level 4
$FW_EXEC iptables -A FORWARD -i veth-fw-guest -o veth-fw-dmz -j REJECT

echo "[4.5] 配置DMZ访问外网规则"
$FW_EXEC iptables -A FORWARD -i veth-fw-dmz -o veth-fw-inet \
    -m conntrack --ctstate NEW -j ACCEPT

echo "[5] 配置VPN远程访问控制"
$FW_EXEC iptables -A FORWARD -i fw -o veth-fw-office \
    -s 10.10.10.2 -d 10.20.0.0/24 -m conntrack --ctstate NEW -j ACCEPT
$FW_EXEC iptables -A FORWARD -i fw -o veth-fw-dmz \
    -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
$FW_EXEC iptables -A FORWARD -i fw -o veth-fw-dmz \
    -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 22 \
    -j LOG --log-prefix "VPN-TO-DMZ-SSH: " --log-level 4
$FW_EXEC iptables -A FORWARD -i fw -o veth-fw-dmz \
    -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 22 \
    -j REJECT --reject-with tcp-reset
$FW_EXEC iptables -A FORWARD -i fw \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "VPN-DENY: " --log-level 4
$FW_EXEC iptables -A FORWARD -i fw -j REJECT

echo "[6] 配置SNAT、DNAT地址转换规则"
$FW_EXEC iptables -t nat -A POSTROUTING -s 10.20.0.0/24 -o veth-fw-inet -j MASQUERADE
$FW_EXEC iptables -t nat -A POSTROUTING -s 10.30.0.0/24 -o veth-fw-inet -j MASQUERADE
$FW_EXEC iptables -t nat -A POSTROUTING -s 10.40.0.0/24 -o veth-fw-inet -j MASQUERADE
$FW_EXEC iptables -t nat -A PREROUTING -i veth-fw-inet -p tcp --dport 8080 \
    -j DNAT --to-destination 10.40.0.2:8080
$FW_EXEC iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz \
    -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

echo "[7] 拦截外网非法访问内网区域"
$FW_EXEC iptables -A FORWARD -i veth-fw-inet -o veth-fw-office \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "INET-TO-OFFICE: " --log-level 4
$FW_EXEC iptables -A FORWARD -i veth-fw-inet -o veth-fw-office -j REJECT
$FW_EXEC iptables -A FORWARD -i veth-fw-inet -o veth-fw-guest \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "INET-TO-GUEST: " --log-level 4
$FW_EXEC iptables -A FORWARD -i veth-fw-inet -o veth-fw-guest -j REJECT
$FW_EXEC iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz \
    -d 10.40.0.2 -p tcp --dport 22 \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "INET-TO-DMZ-SSH: " --log-level 4
$FW_EXEC iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz \
    -d 10.40.0.2 -p tcp --dport 22 -j REJECT --reject-with tcp-reset

echo -e "\n==================== 防火墙规则加载完成 ===================="
echo "---------------- FORWARD 转发规则 ----------------"
$FW_EXEC iptables -L FORWARD -n -v --line-numbers
echo -e "\n---------------- NAT 地址转换规则 ----------------"
$FW_EXEC iptables -t nat -L -n -v --line-numbers