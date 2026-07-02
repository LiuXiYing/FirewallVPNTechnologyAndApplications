#!/bin/bash
# firewall.sh - 企业级防火墙规则（完整版）

ip netns exec fw iptables -F
ip netns exec fw iptables -t nat -F
ip netns exec fw iptables -X
ip netns exec fw iptables -t nat -X

ip netns exec fw iptables -P FORWARD DROP
ip netns exec fw iptables -P INPUT ACCEPT
ip netns exec fw iptables -P OUTPUT ACCEPT

# ========== 状态检测（必须第一条） ==========
ip netns exec fw iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# ========== Office 区域 ==========
# office → dmz:8080 允许
ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz -s 10.20.0.0/24 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

# office → dmz:22 拒绝+LOG
ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz -s 10.20.0.0/24 -d 10.40.0.2 -p tcp --dport 22 -m limit --limit 5/min -j LOG --log-prefix "OFFICE-DMZ-SSH: "
ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz -s 10.20.0.0/24 -d 10.40.0.2 -p tcp --dport 22 -j REJECT

# office → internet 允许
ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-inet -s 10.20.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# ========== Guest 区域（隔离） ==========
# guest → office 拒绝+LOG
ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-office -m limit --limit 5/min -j LOG --log-prefix "GUEST-TO-OFFICE: "
ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-office -j REJECT

# guest → dmz 拒绝+LOG
ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-dmz -m limit --limit 5/min -j LOG --log-prefix "GUEST-TO-DMZ: "
ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-dmz -j REJECT

# guest → internet 允许
ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-inet -s 10.30.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# ========== DMZ 区域 ==========
# dmz → internet 允许
ip netns exec fw iptables -A FORWARD -i veth-fw-dmz -o veth-fw-inet -s 10.40.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# ========== Internet 外网 ==========
# internet → dmz:8080 允许（配合DNAT）
ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

# internet → office 拒绝+LOG
ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-office -m limit --limit 5/min -j LOG --log-prefix "INET-TO-OFFICE: "
ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-office -j REJECT

# internet → guest 拒绝+LOG
ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-guest -m limit --limit 5/min -j LOG --log-prefix "INET-TO-GUEST: "
ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-guest -j REJECT

# internet → dmz:22 拒绝+LOG
ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 22 -m limit --limit 5/min -j LOG --log-prefix "INET-TO-DMZ-SSH: "
ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 22 -j REJECT

# ========== VPN 远程接入（wg0） ==========
# VPN → office 允许
ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-office -s 10.10.10.2 -d 10.20.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# VPN → dmz:8080 允许
ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

# VPN → dmz:22 拒绝+LOG
ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 22 -j LOG --log-prefix "VPN-TO-DMZ-SSH: "
ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 22 -j REJECT

# VPN 其他流量 拒绝+LOG
ip netns exec fw iptables -A FORWARD -i wg0 -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "VPN-DENY: "
ip netns exec fw iptables -A FORWARD -i wg0 -j REJECT
# 兜底全局拒绝规则
ip netns exec fw iptables -A FORWARD -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "FORWARD-DENY: "
ip netns exec fw iptables -A FORWARD -j REJECT --reject-with icmp-port-unreachable

# ========== NAT 规则 ==========
# SNAT：内网访问外网
ip netns exec fw iptables -t nat -A POSTROUTING -s 10.20.0.0/24 -o veth-fw-inet -j MASQUERADE
ip netns exec fw iptables -t nat -A POSTROUTING -s 10.30.0.0/24 -o veth-fw-inet -j MASQUERADE
ip netns exec fw iptables -t nat -A POSTROUTING -s 10.40.0.0/24 -o veth-fw-inet -j MASQUERADE

# DNAT：外网访问DMZ Web服务
ip netns exec fw iptables -t nat -A PREROUTING -i veth-fw-inet -p tcp --dport 8080 -j DNAT --to-destination 10.40.0.2:8080

echo "✅ 防火墙规则加载完成！"