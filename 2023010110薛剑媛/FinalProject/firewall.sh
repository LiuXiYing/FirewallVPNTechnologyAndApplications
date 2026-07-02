#!/bin/bash
# 企业防火墙策略脚本 - 第二部分

FW_NS="fw"

echo "========================================="
echo "开始配置防火墙策略..."
echo "========================================="

# 清空所有现有规则
echo "1. 清空旧规则..."
sudo ip netns exec $FW_NS iptables -F
sudo ip netns exec $FW_NS iptables -t nat -F
sudo ip netns exec $FW_NS iptables -X
echo "   ✓ 清空完成"

# 设置 FORWARD 链默认策略为 DROP
echo "2. 设置默认策略为DROP..."
sudo ip netns exec $FW_NS iptables -P FORWARD DROP
echo "   ✓ 默认策略已设置"

# 状态检测
echo "3. 配置状态检测规则..."
sudo ip netns exec $FW_NS iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
echo "   ✓ 状态检测已配置"

# 允许规则
echo "4. 配置允许规则..."
sudo ip netns exec $FW_NS iptables -A FORWARD -i fw-office -o fw-dmz -s 10.20.0.0/24 -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
sudo ip netns exec $FW_NS iptables -A FORWARD -i fw-office -o fw-inet -s 10.20.0.0/24 -m conntrack --ctstate NEW -j ACCEPT
sudo ip netns exec $FW_NS iptables -A FORWARD -i fw-guest -o fw-inet -s 10.30.0.0/24 -m conntrack --ctstate NEW -j ACCEPT
sudo ip netns exec $FW_NS iptables -A FORWARD -i fw-dmz -o fw-inet -s 10.40.0.0/24 -m conntrack --ctstate NEW -j ACCEPT
sudo ip netns exec $FW_NS iptables -A FORWARD -i fw-inet -o fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
echo "   ✓ 允许规则已配置"

# 拒绝规则
echo "5. 配置拒绝规则..."
sudo ip netns exec $FW_NS iptables -A FORWARD -i fw-office -o fw-dmz -s 10.20.0.0/24 -d 10.40.0.2 -p tcp --dport 22 -j LOG --log-prefix "FW-OFFICE-TO-DMZ-SSH: "
sudo ip netns exec $FW_NS iptables -A FORWARD -i fw-office -o fw-dmz -s 10.20.0.0/24 -d 10.40.0.2 -p tcp --dport 22 -j REJECT
sudo ip netns exec $FW_NS iptables -A FORWARD -i fw-guest -o fw-office -s 10.30.0.0/24 -d 10.20.0.0/24 -j LOG --log-prefix "FW-GUEST-TO-OFFICE: "
sudo ip netns exec $FW_NS iptables -A FORWARD -i fw-guest -o fw-office -s 10.30.0.0/24 -d 10.20.0.0/24 -j REJECT
sudo ip netns exec $FW_NS iptables -A FORWARD -i fw-guest -o fw-dmz -s 10.30.0.0/24 -d 10.40.0.0/24 -j LOG --log-prefix "FW-GUEST-TO-DMZ: "
sudo ip netns exec $FW_NS iptables -A FORWARD -i fw-guest -o fw-dmz -s 10.30.0.0/24 -d 10.40.0.0/24 -j REJECT
sudo ip netns exec $FW_NS iptables -A FORWARD -i fw-inet -o fw-dmz -d 10.40.0.2 -p tcp --dport 22 -j LOG --log-prefix "FW-INTERNET-TO-DMZ-SSH: "
sudo ip netns exec $FW_NS iptables -A FORWARD -i fw-inet -o fw-dmz -d 10.40.0.2 -p tcp --dport 22 -j REJECT
echo "   ✓ 拒绝规则已配置"

# SNAT
echo "6. 配置SNAT..."
sudo ip netns exec $FW_NS iptables -t nat -A POSTROUTING -s 10.20.0.0/24 -o fw-inet -j MASQUERADE
sudo ip netns exec $FW_NS iptables -t nat -A POSTROUTING -s 10.30.0.0/24 -o fw-inet -j MASQUERADE
sudo ip netns exec $FW_NS iptables -t nat -A POSTROUTING -s 10.40.0.0/24 -o fw-inet -j MASQUERADE
echo "   ✓ SNAT已配置"

# DNAT
echo "7. 配置DNAT..."
sudo ip netns exec $FW_NS iptables -t nat -A PREROUTING -i fw-inet -p tcp --dport 8080 -j DNAT --to-destination 10.40.0.2:8080
echo "   ✓ DNAT已配置"

echo "========================================="
echo "✓ 防火墙规则加载完成！"
echo "========================================="
