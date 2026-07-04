#!/bin/bash
# firewall.sh - 防火墙规则配置脚本
# 功能：基于最小权限原则配置所有防火墙规则
# 包含：默认策略、状态检测、区域隔离、SNAT、DNAT
# 作者：[学号] [姓名]
# 日期：2026-06-29

set -e

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "========================================="
echo "  企业网络安全架构 - 防火墙规则配置"
echo "  作者：[学号] [姓名]"
echo "  日期：2026-06-29"
echo "========================================="

# ---------- 0. 清理现有规则 ----------
echo -e "${YELLOW}[0/7] 清理现有iptables规则...${NC}"
sudo ip netns exec fw iptables -F
sudo ip netns exec fw iptables -t nat -F
sudo ip netns exec fw iptables -X
echo "  规则已清理"

# ---------- 1. 设置默认策略 ----------
echo -e "${YELLOW}[1/7] 设置默认策略（最小权限）...${NC}"
sudo ip netns exec fw iptables -P FORWARD DROP
sudo ip netns exec fw iptables -P INPUT ACCEPT
sudo ip netns exec fw iptables -P OUTPUT ACCEPT
echo "  FORWARD默认DROP，INPUT/OUTPUT默认ACCEPT"

# ---------- 2. 状态检测规则（最高优先级） ----------
echo -e "${YELLOW}[2/7] 配置状态检测（允许已建立连接的回程流量）...${NC}"
sudo ip netns exec fw iptables -A FORWARD \
    -m conntrack --ctstate ESTABLISHED,RELATED \
    -j ACCEPT
echo "  ESTABLISHED,RELATED 已放行"

# ---------- 3. office访问规则 ----------
echo -e "${YELLOW}[3/7] 配置office访问规则...${NC}"

# office -> dmz:8080 (允许 - 业务需要)
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-office -o veth-fw-dmz \
    -s 10.20.0.0/24 -d 10.40.0.2 \
    -p tcp --dport 8080 \
    -m conntrack --ctstate NEW \
    -m comment --comment "office->dmz:8080 allow" \
    -j ACCEPT
echo "  office -> dmz:8080: ACCEPT"

# office -> dmz:22 (拒绝 + LOG - 防止横向移动)
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-office -o veth-fw-dmz \
    -s 10.20.0.0/24 -d 10.40.0.2 \
    -p tcp --dport 22 \
    -m conntrack --ctstate NEW \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-office -o veth-fw-dmz \
    -s 10.20.0.0/24 -d 10.40.0.2 \
    -p tcp --dport 22 \
    -m conntrack --ctstate NEW \
    -j REJECT --reject-with icmp-admin-prohibited
echo "  office -> dmz:22: LOG + REJECT"

# ---------- 4. guest隔离规则 ----------
echo -e "${YELLOW}[4/7] 配置guest隔离规则（访客完全隔离）...${NC}"

# guest -> office (拒绝 + LOG)
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-guest -o veth-fw-office \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-guest -o veth-fw-office \
    -j REJECT --reject-with icmp-admin-prohibited
echo "  guest -> office: LOG + REJECT"

# guest -> dmz (拒绝 + LOG)
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-guest -o veth-fw-dmz \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "GUEST-TO-DMZ: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-guest -o veth-fw-dmz \
    -j REJECT --reject-with icmp-admin-prohibited
echo "  guest -> dmz: LOG + REJECT"

# ---------- 5. SNAT配置 ----------
echo -e "${YELLOW}[5/7] 配置SNAT（允许内网访问外网）...${NC}"

# office上网
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
    -s 10.20.0.0/24 -o veth-fw-inet \
    -j MASQUERADE
echo "  office -> internet: MASQUERADE"

# guest上网
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
    -s 10.30.0.0/24 -o veth-fw-inet \
    -j MASQUERADE
echo "  guest -> internet: MASQUERADE"

# dmz访问外网（如软件更新）
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
    -s 10.40.0.0/24 -o veth-fw-inet \
    -j MASQUERADE
echo "  dmz -> internet: MASQUERADE"

# ---------- 6. DNAT配置 ----------
echo -e "${YELLOW}[6/7] 配置DNAT（外网访问DMZ服务）...${NC}"

# 外网访问dmz:8080 (先DNAT)
sudo ip netns exec fw iptables -t nat -A PREROUTING \
    -i veth-fw-inet \
    -p tcp --dport 8080 \
    -j DNAT --to-destination 10.40.0.2:8080
echo "  DNAT: internet -> dmz:8080"

# 对应的FORWARD规则（放行DNAT后的流量）
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-inet -o veth-fw-dmz \
    -d 10.40.0.2 \
    -p tcp --dport 8080 \
    -m conntrack --ctstate NEW \
    -m comment --comment "DNAT: inet->dmz:8080" \
    -j ACCEPT
echo "  FORWARD: internet -> dmz:8080 ACCEPT"

# 外网访问dmz:22 (拒绝 + LOG)
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-inet -o veth-fw-dmz \
    -d 10.40.0.2 \
    -p tcp --dport 22 \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "INET-TO-DMZ-SSH: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-inet -o veth-fw-dmz \
    -d 10.40.0.2 \
    -p tcp --dport 22 \
    -j REJECT --reject-with icmp-admin-prohibited
echo "  internet -> dmz:22: LOG + REJECT"

# 外网访问office (拒绝 + LOG)
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-inet -o veth-fw-office \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "INET-TO-OFFICE: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-inet -o veth-fw-office \
    -j REJECT --reject-with icmp-admin-prohibited
echo "  internet -> office: LOG + REJECT"

# 外网访问guest (拒绝 + LOG)
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-inet -o veth-fw-guest \
    -m limit --limit 5/min --limit-burst 10 \
    -j LOG --log-prefix "INET-TO-GUEST: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD \
    -i veth-fw-inet -o veth-fw-guest \
    -j REJECT --reject-with icmp-admin-prohibited
echo "  internet -> guest: LOG + REJECT"

# ---------- 7. 显示规则 ----------
echo -e "${YELLOW}[7/7] 当前规则列表...${NC}"
echo ""

echo -e "${BLUE}=== FORWARD链规则（含计数器） ===${NC}"
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers

echo ""
echo -e "${BLUE}=== NAT规则 ===${NC}"
sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers

echo ""
echo -e "${BLUE}=== 规则统计 ===${NC}"
echo -n "  FORWARD规则数: "
sudo ip netns exec fw iptables -L FORWARD -n | grep -c "^[A-Z]"
echo -n "  NAT规则数: "
sudo ip netns exec fw iptables -t nat -L -n | grep -c "^[A-Z]"

echo ""
echo -e "${GREEN}========================================="
echo "  ✓ 防火墙规则配置完成！"
echo "=========================================${NC}"
echo ""
echo "下一步: 启动各区域服务进行访问测试"
