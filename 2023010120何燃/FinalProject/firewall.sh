#!/bin/bash
set -e

echo "=== 配置防火墙规则（fw 命名空间） ==="

# ---------- 清空旧规则（确保可重复运行）----------
echo "[0] 清空旧规则..."
ip netns exec fw iptables -F
ip netns exec fw iptables -t nat -F
ip netns exec fw iptables -X
ip netns exec fw iptables -t nat -X

# ---------- 1. 默认策略 ----------
echo "[1] 设置 FORWARD 默认策略为 DROP"
ip netns exec fw iptables -P FORWARD DROP

# ---------- 2. 状态检测（必须第一条）----------
echo "[2] 允许 ESTABLISHED,RELATED 回程流量"
ip netns exec fw iptables -A FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT

# ---------- 3. office → dmz:8080 允许 ----------
echo "[3] 允许 office 访问 dmz Web (8080)"
ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# ---------- 4. office → dmz:22 拒绝 + LOG ----------
echo "[4] 拒绝 office 访问 dmz SSH (22) [日志: OFFICE-TO-DMZ-SSH]"
ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: " --log-level 4

ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j REJECT --reject-with tcp-reset

# ---------- 5. guest → internet 允许 ----------
echo "[5] 允许 guest 访问 internet"
ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-inet \
  -s 10.30.0.0/24 -d 203.0.113.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# ---------- 5b. office → internet 允许（之前遗漏）----------
echo "[5b] 允许 office 访问 internet"
ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-inet \
  -s 10.20.0.0/24 -d 203.0.113.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# ---------- 6. guest → office 拒绝 + LOG ----------
echo "[6] 拒绝 guest 访问 office [日志: GUEST-TO-OFFICE]"
ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4

ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -j REJECT

# ---------- 7. guest → dmz 拒绝 + LOG ----------
echo "[7] 拒绝 guest 访问 dmz [日志: GUEST-TO-DMZ]"
ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-DMZ: " --log-level 4

ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -j REJECT

# ---------- 8. dmz → internet 允许 ----------
echo "[8] 允许 dmz 访问 internet（如系统更新）"
ip netns exec fw iptables -A FORWARD \
  -i veth-fw-dmz -o veth-fw-inet \
  -s 10.40.0.0/24 -d 203.0.113.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# ---------- 9. internet → dmz:8080 允许（DNAT 流量）----------
echo "[9] 允许 internet 访问 dmz:8080（经 DNAT）"
ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# ---------- 10. internet → office 拒绝 + LOG ----------
echo "[10] 拒绝 internet 访问 office [日志: INET-TO-OFFICE]"
ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-office \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "INET-TO-OFFICE: " --log-level 4

ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-office \
  -j REJECT

# ---------- 11. internet → guest 拒绝 + LOG ----------
echo "[11] 拒绝 internet 访问 guest [日志: INET-TO-GUEST]"
ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-guest \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "INET-TO-GUEST: " --log-level 4

ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-guest \
  -j REJECT

# ---------- 12. SNAT（内网访问外网时做源地址转换）----------
echo "[12] 配置 SNAT (MASQUERADE)"
ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.20.0.0/24 -o veth-fw-inet -j MASQUERADE

ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.30.0.0/24 -o veth-fw-inet -j MASQUERADE

ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.40.0.0/24 -o veth-fw-inet -j MASQUERADE

# ---------- 13. DNAT（外网访问 8080 转发到 dmz）----------
echo "[13] 配置 DNAT (internet:8080 → dmz:8080)"
ip netns exec fw iptables -t nat -A PREROUTING \
  -i veth-fw-inet -p tcp --dport 8080 \
  -j DNAT --to-destination 10.40.0.2:8080

# ========== 14. VPN 规则 ==========
echo "[14] 配置 VPN 访问控制"

# 14.1 允许 VPN → office（通用）
ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-office \
  -s 10.10.10.2 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 14.2 拒绝 VPN → dmz:22（必须在通用放行之前）
ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j LOG --log-prefix "VPN-TO-DMZ-SSH: " --log-level 4

ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j REJECT --reject-with tcp-reset

# 14.3 通用允许 VPN → dmz（其他端口，如 8080）
ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 14.4 兜底：拒绝所有其他从 wg0 来的流量，并记录日志（速率限制）
ip netns exec fw iptables -A FORWARD \
  -i wg0 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "VPN-DENY: " --log-level 4

ip netns exec fw iptables -A FORWARD \
  -i wg0 \
  -j REJECT

echo ""
echo "=============================================="
echo "  防火墙规则配置完成！"
echo "=============================================="
echo ""
echo "========== FORWARD 规则列表 =========="
ip netns exec fw iptables -L FORWARD -n -v --line-numbers
echo ""
echo "========== NAT 规则列表 =========="
ip netns exec fw iptables -t nat -L -n -v --line-numbers