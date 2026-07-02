#!/bin/bash
set -e

FW=fw

echo "[1] 清空旧规则..."
sudo ip netns exec $FW iptables -F
sudo ip netns exec $FW iptables -t nat -F
sudo ip netns exec $FW iptables -X
sudo ip netns exec $FW iptables -t nat -X

echo "[2] 默认策略（最小权限）..."
sudo ip netns exec $FW iptables -P FORWARD DROP

echo "[3] 允许已建立连接（必须最先）..."
sudo ip netns exec $FW iptables -A FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT

# =========================
# OFFICE区域策略
# =========================
echo "[4] office -> dmz:8080允许..."
sudo ip netns exec $FW iptables -A FORWARD \
  -s 10.20.0.0/24 -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

echo "[5] office -> dmz:22拒绝 + LOG..."
sudo ip netns exec $FW iptables -A FORWARD \
  -s 10.20.0.0/24 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: "

sudo ip netns exec $FW iptables -A FORWARD \
  -s 10.20.0.0/24 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j REJECT

echo "[6] office -> internet允许..."
sudo ip netns exec $FW iptables -A FORWARD \
  -s 10.20.0.0/24 -o veth-fw-inet \
  -m conntrack --ctstate NEW,ESTABLISHED,RELATED \
  -j ACCEPT

# =========================
# GUEST区域策略
# =========================
echo "[7] guest -> office拒绝 + LOG..."
sudo ip netns exec fw iptables -A FORWARD \
  -s 10.30.0.0/24 -d 10.20.0.0/24 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-OFFICE: " \
  --log-level 4 # 第四部分补充：日志限制

sudo ip netns exec $FW iptables -A FORWARD \
  -s 10.30.0.0/24 -d 10.20.0.0/24 \
  -j REJECT

echo "[8] guest -> dmz拒绝 + LOG..."
sudo ip netns exec fw iptables -A FORWARD \
  -s 10.30.0.0/24 -d 10.40.0.0/24 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-DMZ: " \
  --log-level 4 # 第四部分补充：日志限制

sudo ip netns exec $FW iptables -A FORWARD \
  -s 10.30.0.0/24 -d 10.40.0.0/24 \
  -j REJECT

echo "[9] guest -> internet允许..."
sudo ip netns exec $FW iptables -A FORWARD \
  -s 10.30.0.0/24 -o veth-fw-inet \
  -m conntrack --ctstate NEW,ESTABLISHED,RELATED \
  -j ACCEPT

# =========================
# DMZ区域策略
# =========================
echo "[10] dmz -> internet允许..."
sudo ip netns exec $FW iptables -A FORWARD \
  -s 10.40.0.0/24 -o veth-fw-inet \
  -m conntrack --ctstate NEW,ESTABLISHED,RELATED \
  -j ACCEPT

echo "[11] internet -> dmz:22拒绝..."
sudo ip netns exec $FW iptables -A FORWARD \
  -i veth-fw-inet -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j REJECT

# =========================
# INTERNET -> 内网隔离
# =========================
echo "[12] internet -> office拒绝..."
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -d 10.20.0.0/24 \
  -m limit --limit 5/min --limit-burst 10  \
  -j LOG --log-prefix "INET-TO-OFFICE: " \
  --log-level 4 # 第四部分补充：日志限制

sudo ip netns exec $FW iptables -A FORWARD \
  -i veth-fw-inet -d 10.20.0.0/24 \
  -j REJECT

echo "[13] internet -> guest拒绝..."
sudo ip netns exec $FW iptables -A FORWARD \
  -i veth-fw-inet -d 10.30.0.0/24 \
  -j REJECT

# =========================
# NAT区域
# =========================
echo "[14] SNAT（内网访问外网）..."
sudo ip netns exec $FW iptables -t nat -A POSTROUTING \
  -s 10.20.0.0/24 -o veth-fw-inet -j MASQUERADE

sudo ip netns exec $FW iptables -t nat -A POSTROUTING \
  -s 10.30.0.0/24 -o veth-fw-inet -j MASQUERADE

sudo ip netns exec $FW iptables -t nat -A POSTROUTING \
  -s 10.40.0.0/24 -o veth-fw-inet -j MASQUERADE

echo "[15] DNAT（外网访问DMZ:8080）...（第六部分修改版）"
sudo ip netns exec $FW iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -p tcp --dport 8080 -d 10.40.0.2 \
  -m conntrack --ctstate NEW \
  -m recent --rcheck --seconds 60 --hitcount 10 --name DMZ8080 \
  -j REJECT --reject-with tcp-reset

sudo ip netns exec $FW iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -p tcp --dport 8080 -d 10.40.0.2 \
  -m conntrack --ctstate NEW \
  -m recent --set --name DMZ8080 \
  -j ACCEPT

# =========================
# VPN区域策略（第三部分）
# =========================
echo "[16] VPN -> office"
sudo ip netns exec $FW iptables -A FORWARD \
  -i wg0 -o veth-fw-office \
  -s 10.10.10.0/24 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW,ESTABLISHED,RELATED \
  -j ACCEPT

echo "[17] VPN -> dmz 8080"
sudo ip netns exec $FW iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW,ESTABLISHED,RELATED \
  -j ACCEPT

echo "[18] VPN -> dmz ssh reject"
sudo ip netns exec $FW iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 22 \
  -j LOG --log-prefix "VPN-TO-DMZ-SSH: "

sudo ip netns exec $FW iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 22 \
  -j REJECT

echo "[19] VPN其余拒绝"
sudo ip netns exec $FW iptables -A FORWARD \
  -i wg0 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "VPN-DENY: "\
  --log-level 4 # 第四部分补充：日志限制

sudo ip netns exec $FW iptables -A FORWARD \
  -i wg0 \
  -j REJECT

echo "[20] 完成"