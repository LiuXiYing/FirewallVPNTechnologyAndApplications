#!/bin/bash

echo "========== 第二部分：防火墙策略实现（修复版）=========="

echo "[1/6] 清空规则..."
sudo ip netns exec fw iptables -F
sudo ip netns exec fw iptables -X
sudo ip netns exec fw iptables -t nat -F
sudo ip netns exec fw iptables -t nat -X

echo "[2/6] 默认策略..."
sudo ip netns exec fw iptables -P INPUT DROP
sudo ip netns exec fw iptables -P FORWARD DROP
sudo ip netns exec fw iptables -P OUTPUT ACCEPT

echo "[3/6] 允许本地和已建立连接..."
sudo ip netns exec fw iptables -A INPUT -i lo -j ACCEPT
sudo ip netns exec fw iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo ip netns exec fw iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

echo "[4/6] office规则..."
sudo ip netns exec fw iptables -A FORWARD -i v-fw-off -o v-fw-dmz -s 10.20.0.0/24 -d 10.40.0.0/24 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
sudo ip netns exec fw iptables -A FORWARD -i v-fw-off -o v-fw-dmz -s 10.20.0.0/24 -d 10.40.0.0/24 -p tcp --dport 22 -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD -i v-fw-off -o v-fw-dmz -s 10.20.0.0/24 -d 10.40.0.0/24 -p tcp --dport 22 -j REJECT
sudo ip netns exec fw iptables -A FORWARD -i v-fw-off -o v-fw-inet -s 10.20.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

echo "[5/6] guest规则..."
sudo ip netns exec fw iptables -A FORWARD -i v-fw-gst -o v-fw-inet -s 10.30.0.0/24 -m conntrack --ctstate NEW -j ACCEPT
sudo ip netns exec fw iptables -A FORWARD -i v-fw-gst -o v-fw-off -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD -i v-fw-gst -o v-fw-off -j REJECT
sudo ip netns exec fw iptables -A FORWARD -i v-fw-gst -o v-fw-dmz -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "GUEST-TO-DMZ: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD -i v-fw-gst -o v-fw-dmz -j REJECT

echo "[6/7] NAT和internet规则..."
sudo ip netns exec fw iptables -t nat -A POSTROUTING -s 10.20.0.0/24 -o v-fw-inet -j MASQUERADE
sudo ip netns exec fw iptables -t nat -A POSTROUTING -s 10.30.0.0/24 -o v-fw-inet -j MASQUERADE
sudo ip netns exec fw iptables -t nat -A POSTROUTING -s 10.40.0.0/24 -o v-fw-inet -j MASQUERADE

sudo ip netns exec fw iptables -t nat -A PREROUTING -i v-fw-inet -p tcp --dport 8080 -j DNAT --to-destination 10.40.0.2:8080
sudo ip netns exec fw iptables -A FORWARD -i v-fw-inet -o v-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

sudo ip netns exec fw iptables -A FORWARD -i v-fw-inet -o v-fw-dmz -d 10.40.0.2 -p tcp --dport 22 -j LOG --log-prefix "INET-TO-DMZ-SSH: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD -i v-fw-inet -o v-fw-dmz -d 10.40.0.2 -p tcp --dport 22 -j REJECT

sudo ip netns exec fw iptables -A FORWARD -i v-fw-inet -o v-fw-off -d 10.20.0.0/24 -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "INET-TO-OFFICE: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD -i v-fw-inet -o v-fw-off -d 10.20.0.0/24 -j REJECT

sudo ip netns exec fw iptables -A FORWARD -i v-fw-inet -o v-fw-gst -d 10.30.0.0/24 -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "INET-TO-GUEST: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD -i v-fw-inet -o v-fw-gst -d 10.30.0.0/24 -j REJECT

sudo ip netns exec fw iptables -A FORWARD -i v-fw-dmz -o v-fw-inet -s 10.40.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

sudo ip netns exec fw iptables -A INPUT -i v-fw-inet -p udp --dport 51820 -j ACCEPT

echo "[7/7] VPN FORWARD规则..."
# VPN用户可以访问office
sudo ip netns exec fw iptables -A FORWARD -i wg0 -o v-fw-off -s 10.10.10.2 -d 10.20.0.0/24 -m conntrack --ctstate NEW -j ACCEPT

# VPN用户可以访问dmz:8080
sudo ip netns exec fw iptables -A FORWARD -i wg0 -o v-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

# VPN用户不能访问dmz:22（拒绝+LOG）
sudo ip netns exec fw iptables -A FORWARD -i wg0 -o v-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 22 -j LOG --log-prefix "VPN-TO-DMZ-SSH: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD -i wg0 -o v-fw-dmz -s 10.10.10.2 -d 10.40.0.2 -p tcp --dport 22 -j REJECT

# 其他VPN流量拒绝+LOG
sudo ip netns exec fw iptables -A FORWARD -i wg0 -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "VPN-DENY: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD -i wg0 -j REJECT

echo ""
echo "=== FORWARD规则 ==="
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
echo ""
echo "=== NAT规则 ==="
sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers

echo ""
echo "========== 第二部分完成！=========="
