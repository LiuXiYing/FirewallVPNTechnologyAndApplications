#!/bin/bash
# ============================================================
# firewall.sh - 防火墙策略配置脚本（Kali Linux 版本）
# ============================================================
# 功能：配置FORWARD规则、NAT规则、日志规则
# 原则：最小权限、状态检测在前、LOG在REJECT前
# ============================================================

set -e

echo "========================================="
echo "  防火墙策略配置"
echo "========================================="

# ---------- 2.1 FORWARD链默认策略 ----------
echo "[1/11] 设置FORWARD默认策略为DROP..."
sudo ip netns exec fw iptables -P FORWARD DROP
echo "  FORWARD默认策略: DROP"

# ---------- 2.2 状态检测规则（必须放在最前面） ----------
echo "[2/11] 配置状态检测规则..."
sudo ip netns exec fw iptables -A FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT
echo "  ESTABLISHED,RELATED -> ACCEPT"

# ---------- 2.3 office访问dmz规则 ----------
echo "[3/11] 配置office访问dmz规则..."

# 允许office访问dmz:8080 (Web服务)
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 拒绝office访问dmz:22 (SSH) - LOG
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: " --log-level 4

# 拒绝office访问dmz:22 (SSH) - REJECT
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j REJECT --reject-with tcp-reset

echo "  office -> dmz:8080 ACCEPT"
echo "  office -> dmz:22   REJECT (with LOG)"

# ---------- 2.4 office访问internet规则 ----------
echo "[4/11] 配置office访问internet规则..."

# 允许office访问internet（所有端口）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-inet \
  -s 10.20.0.0/24 -d 203.0.113.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

echo "  office -> internet ACCEPT"

# ---------- 2.5 guest隔离规则 ----------
echo "[5/11] 配置guest隔离规则..."

# 拒绝guest访问office - LOG
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4

# 拒绝guest访问office - REJECT
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -j REJECT --reject-with icmp-admin-prohibited

# 拒绝guest访问dmz - LOG
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-DMZ: " --log-level 4

# 拒绝guest访问dmz - REJECT
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -j REJECT --reject-with icmp-admin-prohibited

# 允许guest访问internet
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-inet \
  -s 10.30.0.0/24 -d 203.0.113.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

echo "  guest -> office   REJECT (with LOG)"
echo "  guest -> dmz      REJECT (with LOG)"
echo "  guest -> internet ACCEPT"

# ---------- 2.6 dmz访问internet规则 ----------
echo "[6/11] 配置dmz访问internet规则..."

# 允许dmz访问internet（如更新软件）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-dmz -o veth-fw-inet \
  -s 10.40.0.0/24 -d 203.0.113.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

echo "  dmz -> internet ACCEPT"

# ---------- 2.7 internet访问内网规则 ----------
echo "[7/11] 配置internet访问内网规则..."

# 拒绝internet访问office - LOG
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-office \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "INET-TO-OFFICE: " --log-level 4

# 拒绝internet访问office - REJECT
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-office \
  -j REJECT --reject-with icmp-admin-prohibited

# 拒绝internet访问guest - REJECT
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-guest \
  -j REJECT --reject-with icmp-admin-prohibited

# 允许internet访问dmz:8080（通过DNAT）- FORWARD规则
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 拒绝internet访问dmz:22 - LOG
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 \
  -p tcp --dport 22 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "INET-TO-DMZ-SSH: " --log-level 4

# 拒绝internet访问dmz:22 - REJECT
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j REJECT --reject-with tcp-reset

echo "  internet -> office      REJECT (with LOG)"
echo "  internet -> guest       REJECT"
echo "  internet -> dmz:8080    ACCEPT (DNAT)"
echo "  internet -> dmz:22      REJECT (with LOG)"

# ---------- 2.8 SNAT配置 ----------
echo "[8/11] 配置SNAT规则（内网访问外网时做源地址转换）..."

sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.20.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.30.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.40.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

echo "  SNAT: 10.20.0.0/24 -> MASQUERADE"
echo "  SNAT: 10.30.0.0/24 -> MASQUERADE"
echo "  SNAT: 10.40.0.0/24 -> MASQUERADE"

# ---------- 2.9 DNAT配置 ----------
echo "[9/11] 配置DNAT规则（外网访问fw公网IP:8080转发到dmz:8080）..."

sudo ip netns exec fw iptables -t nat -A PREROUTING \
  -i veth-fw-inet \
  -p tcp --dport 8080 \
  -j DNAT --to-destination 10.40.0.2:8080

echo "  DNAT: 203.0.113.1:8080 -> 10.40.0.2:8080"

# ---------- 2.10 VPN远程访问规则 ----------
echo "[10/11] 配置VPN远程访问规则..."

# 允许VPN远程用户访问office内网
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-office \
  -s 10.10.10.2 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 允许VPN远程用户访问dmz:8080 (Web服务)
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 拒绝VPN远程用户访问dmz:22 (SSH) - LOG
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "VPN-TO-DMZ-SSH: " --log-level 4

# 拒绝VPN远程用户访问dmz:22 (SSH) - REJECT
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j REJECT --reject-with tcp-reset

# 拒绝VPN远程用户访问guest - LOG
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-guest \
  -s 10.10.10.2 -d 10.30.0.0/24 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "VPN-TO-GUEST: " --log-level 4

# 拒绝VPN远程用户访问guest - REJECT
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-guest \
  -s 10.10.10.2 -d 10.30.0.0/24 \
  -j REJECT --reject-with icmp-admin-prohibited

echo "  VPN -> office   ACCEPT"
echo "  VPN -> dmz:8080 ACCEPT"
echo "  VPN -> dmz:22   REJECT (with LOG)"
echo "  VPN -> guest    REJECT (with LOG)"

# ---------- 2.11 VPN SNAT规则 ----------
echo "[11/11] 配置VPN SNAT规则..."

# 注：由于 setup.sh 已添加 10.10.10.0/24 dev wg0 路由，
# fw 可直接将回程包转发回 remote，无需 SNAT。
# 若做 SNAT 到 fw 接口地址（10.20.0.1/10.40.0.1），回程包会被内核判定为
# 发往本机，导致无法回到 remote。

echo "  VPN 流量无需 SNAT，依赖 wg0 路由直接回程"

echo ""
echo "========================================="
echo "  防火墙策略配置完成！"
echo "========================================="
echo ""
echo "查看规则："
echo "  sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers"
echo "  sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers"
echo ""
echo "下一步：启动dmz服务并测试访问控制矩阵"
