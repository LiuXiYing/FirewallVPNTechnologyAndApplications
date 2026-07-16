#!/bin/bash
# 防火墙规则配置脚本

# 清空规则
sudo ip netns exec fw iptables -F
sudo ip netns exec fw iptables -t nat -F
sudo ip netns exec fw iptables -X 2>/dev/null || true
sudo ip netns exec fw iptables -t nat -X 2>/dev/null || true

# 默认策略
sudo ip netns exec fw iptables -P FORWARD DROP
sudo ip netns exec fw iptables -P INPUT ACCEPT
sudo ip netns exec fw iptables -P OUTPUT ACCEPT

# 状态检测（必须第一）
sudo ip netns exec fw iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# office 规则
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz \
    -s 10.20.0.0/24 -d 10.40.0.0/24 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

sudo ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz \
    -s 10.20.0.0/24 -d 10.40.0.0/24 -p tcp --dport 22 \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz \
    -s 10.20.0.0/24 -d 10.40.0.0/24 -p tcp --dport 22 -j REJECT

sudo ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-inet \
    -s 10.20.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# guest 规则
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-inet \
    -s 10.30.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

sudo ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-office \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-office -j REJECT

sudo ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-dmz \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "GUEST-TO-DMZ: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-dmz -j REJECT

# dmz 规则
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-dmz -o veth-fw-inet \
    -s 10.40.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# internet 规则
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz \
    -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

sudo ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz \
    -d 10.40.0.2 -p tcp --dport 22 \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "INET-TO-DMZ-SSH: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz \
    -d 10.40.0.2 -p tcp --dport 22 -j REJECT

sudo ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-office \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "INET-TO-OFFICE: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-office -j REJECT

sudo ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-guest \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "INET-TO-GUEST: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-guest -j REJECT

# VPN 规则
sudo ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-office \
    -s 10.10.10.2 -d 10.20.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

sudo ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-dmz \
    -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

sudo ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-dmz \
    -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 22 \
    -j LOG --log-prefix "VPN-TO-DMZ-SSH: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-dmz \
    -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 22 -j REJECT

sudo ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-guest \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "VPN-DENY: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-guest -j REJECT

sudo ip netns exec fw iptables -A FORWARD -i wg0 \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "VPN-DENY: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD -i wg0 -j REJECT

# NAT
sudo ip netns exec fw iptables -t nat -A POSTROUTING -s 10.20.0.0/24 -o veth-fw-inet -j MASQUERADE
sudo ip netns exec fw iptables -t nat -A POSTROUTING -s 10.30.0.0/24 -o veth-fw-inet -j MASQUERADE
sudo ip netns exec fw iptables -t nat -A POSTROUTING -s 10.40.0.0/24 -o veth-fw-inet -j MASQUERADE

sudo ip netns exec fw iptables -t nat -A PREROUTING -i veth-fw-inet \
    -p tcp --dport 8080 -j DNAT --to-destination 10.40.0.2:8080

echo "[+] 防火墙配置完成！"