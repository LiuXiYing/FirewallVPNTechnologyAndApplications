
#!/bin/bash
# firewall.sh - 企业网络安全架构防火墙规则配置脚本
# 功能：配置 FORWARD 链、NAT、DNAT、SNAT、VPN 访问控制
# 作者：王珍铖
# 日期：2026-07-02

set -e

echo "========================================="
echo "  企业网络安全架构 - 防火墙规则配置"
echo "========================================="

# ============================================
# 第一部分：清理旧规则
# ============================================
echo ""
echo "[1/6] 清理旧规则..."

# 清空 FORWARD 链
sudo ip netns exec fw iptables -F FORWARD
# 清空 NAT 表
sudo ip netns exec fw iptables -t nat -F
# 清空自定义链
sudo ip netns exec fw iptables -X
sudo ip netns exec fw iptables -t nat -X

echo "  ✅ 规则清理完成"

# ============================================
# 第二部分：配置 FORWARD 链
# ============================================
echo ""
echo "[2/6] 配置 FORWARD 链..."

# 2.1 默认策略为 DROP（最小权限原则）
sudo ip netns exec fw iptables -P FORWARD DROP
echo "  - FORWARD 默认策略: DROP"

# 2.2 状态检测规则（必须放在最前面）
sudo ip netns exec fw iptables -A FORWARD \
    -m conntrack --ctstate ESTABLISHED,RELATED \
    -j ACCEPT
echo "  - 状态检测规则: ✅"

# ============================================
# 第三部分：配置区域间访问控制
# ============================================
echo ""
echo "[3/6] 配置区域间访问控制..."

# 3.1 office 访问规则
echo "  - office 访问规则..."

# office -> dmz:8080 (允许)
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-office -o veth-fw-dmz \
    -s 10.20.0.0/24 -d 10.40.0.2 \
    -p tcp --dport 8080 \
    -m conntrack --ctstate NEW \
    -j ACCEPT
echo "    ✅ office -> dmz:8080 (允许)"

# office -> internet (允许)
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-office -o veth-fw-inet \
    -s 10.20.0.0/24 \
    -m conntrack --ctstate NEW \
    -j ACCEPT
echo "    ✅ office -> internet (允许)"

# office -> dmz:22 (拒绝+LOG)
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-office -o veth-fw-dmz \
    -s 10.20.0.0/24 -d 10.40.0.2 \
    -p tcp --dport 22 \
    -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-office -o veth-fw-dmz \
    -s 10.20.0.0/24 -d 10.40.0.2 \
    -p tcp --dport 22 \
    -j REJECT
echo "    ✅ office -> dmz:22 (拒绝+LOG)"

# 3.2 guest 访问规则
echo "  - guest 访问规则..."

# guest -> internet (允许)
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-guest -o veth-fw-inet \
    -s 10.30.0.0/24 \
    -m conntrack --ctstate NEW \
    -j ACCEPT
echo "    ✅ guest -> internet (允许)"

# guest -> office (拒绝+LOG)
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-guest -o veth-fw-office \
    -s 10.30.0.0/24 -d 10.20.0.0/24 \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-guest -o veth-fw-office \
    -s 10.30.0.0/24 -d 10.20.0.0/24 \
    -j REJECT
echo "    ✅ guest -> office (拒绝+LOG)"

# guest -> dmz (拒绝+LOG)
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-guest -o veth-fw-dmz \
    -s 10.30.0.0/24 -d 10.40.0.0/24 \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "GUEST-TO-DMZ: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-guest -o veth-fw-dmz \
    -s 10.30.0.0/24 -d 10.40.0.0/24 \
    -j REJECT
echo "    ✅ guest -> dmz (拒绝+LOG)"

# 3.3 dmz 访问规则
echo "  - dmz 访问规则..."

# dmz -> internet (允许)
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-dmz -o veth-fw-inet \
    -s 10.40.0.0/24 \
    -m conntrack --ctstate NEW \
    -j ACCEPT
echo "    ✅ dmz -> internet (允许)"

# 3.4 internet 访问规则
echo "  - internet 访问规则..."

# internet -> dmz:8080 (DNAT 放行)
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-inet -o veth-fw-dmz \
    -d 10.40.0.2 -p tcp --dport 8080 \
    -m conntrack --ctstate NEW \
    -j ACCEPT
echo "    ✅ internet -> dmz:8080 (DNAT放行)"

# internet -> office (拒绝+LOG)
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-inet -o veth-fw-office \
    -d 10.20.0.0/24 \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "INET-TO-OFFICE: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-inet -o veth-fw-office \
    -d 10.20.0.0/24 \
    -j REJECT
echo "    ✅ internet -> office (拒绝+LOG)"

# internet -> guest (拒绝)
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-inet -o veth-fw-guest \
    -d 10.30.0.0/24 \
    -j REJECT
echo "    ✅ internet -> guest (拒绝)"

# internet -> dmz:22 (拒绝)
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-inet -o veth-fw-dmz \
    -d 10.40.0.2 -p tcp --dport 22 \
    -j REJECT
echo "    ✅ internet -> dmz:22 (拒绝)"

# ============================================
# 第四部分：配置 NAT
# ============================================
echo ""
echo "[4/6] 配置 NAT..."

# 4.1 SNAT：内网访问外网
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
    -s 10.20.0.0/24 -o veth-fw-inet \
    -j MASQUERADE
echo "  - SNAT office -> internet: ✅"

sudo ip netns exec fw iptables -t nat -A POSTROUTING \
    -s 10.30.0.0/24 -o veth-fw-inet \
    -j MASQUERADE
echo "  - SNAT guest -> internet: ✅"

sudo ip netns exec fw iptables -t nat -A POSTROUTING \
    -s 10.40.0.0/24 -o veth-fw-inet \
    -j MASQUERADE
echo "  - SNAT dmz -> internet: ✅"

# 4.2 DNAT：外网访问 DMZ Web
sudo ip netns exec fw iptables -t nat -A PREROUTING \
    -i veth-fw-inet -p tcp --dport 8080 \
    -j DNAT --to-destination 10.40.0.2:8080
echo "  - DNAT internet -> dmz:8080: ✅"

# ============================================
# 第五部分：配置 VPN 访问控制
# ============================================
echo ""
echo "[5/6] 配置 VPN 访问控制..."

# VPN -> office (允许)
sudo ip netns exec fw iptables -A FORWARD \
    -i wg0 -o veth-fw-office \
    -s 10.10.10.2 -d 10.20.0.0/24 \
    -m conntrack --ctstate NEW \
    -j ACCEPT
echo "  - VPN -> office: ✅"

# VPN -> dmz:8080 (允许)
sudo ip netns exec fw iptables -A FORWARD \
    -i wg0 -o veth-fw-dmz \
    -s 10.10.10.2 -d 10.40.0.2 \
    -p tcp --dport 8080 \
    -m conntrack --ctstate NEW \
    -j ACCEPT
echo "  - VPN -> dmz:8080: ✅"

# VPN -> dmz:22 (拒绝+LOG)
sudo ip netns exec fw iptables -A FORWARD \
    -i wg0 -o veth-fw-dmz \
    -s 10.10.10.2 -d 10.40.0.2 \
    -p tcp --dport 22 \
    -j LOG --log-prefix "VPN-TO-DMZ-SSH: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD \
    -i wg0 -o veth-fw-dmz \
    -s 10.10.10.2 -d 10.40.0.2 \
    -p tcp --dport 22 \
    -j REJECT
echo "  - VPN -> dmz:22 (拒绝+LOG): ✅"

# VPN 其他流量 (拒绝+LOG)
sudo ip netns exec fw iptables -A FORWARD \
    -i wg0 \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "VPN-DENY: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD \
    -i wg0 \
    -j REJECT
echo "  - VPN 其他流量 (拒绝+LOG): ✅"

# ============================================
# 第六部分：显示规则验证
# ============================================
echo ""
echo "[6/6] 规则验证"
echo "========================================="

echo ""
echo "📋 FORWARD 链规则列表："
echo "----------------------------------------"
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers

echo ""
echo "📋 NAT 规则列表："
echo "----------------------------------------"
sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers

echo ""
echo "📋 规则统计："
echo "----------------------------------------"
echo "FORWARD 规则总数: $(sudo ip netns exec fw iptables -L FORWARD -n | wc -l)"
echo "NAT 规则总数: $(sudo ip netns exec fw iptables -t nat -L -n | wc -l)"
echo "LOG 规则数: $(sudo ip netns exec fw iptables -L FORWARD -n | grep -c LOG)"

echo ""
echo "========================================="
echo "  ✅ 防火墙规则配置完成！"
echo "========================================="
