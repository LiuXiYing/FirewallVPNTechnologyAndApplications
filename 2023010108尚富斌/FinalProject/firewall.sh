#!/bin/bash
# 清除可能存在的旧规则（避免重复）
sudo ip netns exec fw iptables -F FORWARD
sudo ip netns exec fw iptables -t nat -F

# 默认策略
sudo ip netns exec fw iptables -P FORWARD DROP

# 状态检测
sudo ip netns exec fw iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# office -> dmz:8080 允许
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz -s 10.20.0.0/24 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

# office -> dmz:22 拒绝+LOG
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz -s 10.20.0.0/24 -d 10.40.0.2 -p tcp --dport 22 -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz -s 10.20.0.0/24 -d 10.40.0.2 -p tcp --dport 22 -j REJECT

# guest -> office 拒绝+LOG
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-office -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-office -j REJECT

# guest -> dmz 拒绝+LOG
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-dmz -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "GUEST-TO-DMZ: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-dmz -j REJECT

# office 访问外网
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-inet -s 10.20.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# guest 访问外网
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-guest -o veth-fw-inet -s 10.30.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# dmz 访问外网
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-dmz -o veth-fw-inet -s 10.40.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# SNAT
sudo ip netns exec fw iptables -t nat -A POSTROUTING -s 10.20.0.0/24 -o veth-fw-inet -j MASQUERADE
sudo ip netns exec fw iptables -t nat -A POSTROUTING -s 10.30.0.0/24 -o veth-fw-inet -j MASQUERADE
sudo ip netns exec fw iptables -t nat -A POSTROUTING -s 10.40.0.0/24 -o veth-fw-inet -j MASQUERADE

# DNAT (外网访问 dmz:8080)
sudo ip netns exec fw iptables -t nat -A PREROUTING -i veth-fw-inet -p tcp --dport 8080 -j DNAT --to-destination 10.40.0.2:8080
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

# VPN 用户访问 office
sudo ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-office -s 10.10.10.2 -d 10.20.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# VPN 用户访问 dmz:8080
sudo ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

# VPN 用户禁止 dmz:22 (LOG+REJECT)
sudo ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 22 -j LOG --log-prefix "VPN-TO-DMZ-SSH: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD -i wg0 -o veth-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 22 -j REJECT

# VPN 其他流量拒绝+LOG
sudo ip netns exec fw iptables -A FORWARD -i wg0 -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "VPN-DENY: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD -i wg0 -j REJECT

# 改进方案：connlimit 限制 dmz:8080 并发连接数
sudo ip netns exec fw iptables -I FORWARD 1 -p tcp --dport 8080 -d 10.40.0.2 -m connlimit --connlimit-above 10 --connlimit-mask 32 -j REJECT --reject-with tcp-reset

echo "Firewall rules applied."
