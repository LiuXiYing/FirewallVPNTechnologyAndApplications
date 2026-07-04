#!/bin/bash
set -e

# 清空已有规则，确保可重复运行
sudo ip netns exec fw iptables -F
sudo ip netns exec fw iptables -t nat -F
sudo ip netns exec fw iptables -X 2>/dev/null || true
sudo ip netns exec fw iptables -Z

# 默认策略
sudo ip netns exec fw iptables -P FORWARD DROP
sudo ip netns exec fw iptables -P INPUT DROP
sudo ip netns exec fw iptables -P OUTPUT ACCEPT

# 允许本地回环和已建立连接（包括WireGuard控制包本身）
sudo ip netns exec fw iptables -A INPUT -i lo -j ACCEPT
sudo ip netns exec fw iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 1. 状态检测规则（FORWARD最前）
sudo ip netns exec fw iptables -A FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT

# 2. office -> dmz:8080 允许
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 3. office -> internet 允许
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-inet \
  -s 10.20.0.0/24 \
  -j ACCEPT

# 4. guest -> internet 允许
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-inet \
  -s 10.30.0.0/24 \
  -j ACCEPT

# 5. dmz -> internet 允许
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-dmz -o veth-fw-inet \
  -s 10.40.0.0/24 \
  -j ACCEPT

# 6. DNAT：外网 -> dmz:8080
sudo ip netns exec fw iptables -t nat -A PREROUTING \
  -i veth-fw-inet \
  -p tcp --dport 8080 \
  -j DNAT --to-destination 10.40.0.2:8080

sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 7. VPN -> office 允许
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-office \
  -s 10.10.10.2 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 8. VPN -> dmz:8080 允许
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 9. SNAT：内网访问外网
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.20.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.30.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.40.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

# ================== 拒绝/日志规则（LOG 在 REJECT 前） ==================

# 10. office -> dmz:22 拒绝 + LOG（无速率限制）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 22 \
  -j LOG --log-prefix "OFFICE-TO-DMZ-22: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 22 \
  -j REJECT

# 11. guest -> office 拒绝 + LOG（5/min）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-OFFICE: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -j REJECT

# 12. guest -> dmz 拒绝 + LOG（5/min）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-DMZ: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -j REJECT

# 13. internet -> office 拒绝 + LOG（5/min）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-office \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "INET-TO-OFFICE: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-office \
  -j REJECT

# 14. internet -> guest 拒绝 + LOG（5/min）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-guest \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "INET-TO-GUEST: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-guest \
  -j REJECT

# 15. internet -> dmz:22 拒绝（无DNAT，走INPUT链）
sudo ip netns exec fw iptables -A INPUT \
  -i veth-fw-inet \
  -p tcp --dport 22 \
  -j REJECT

# 16. internet -> 未映射端口（如3306）拒绝 + LOG（5/min）
sudo ip netns exec fw iptables -A INPUT \
  -i veth-fw-inet \
  -p tcp --dport 3306 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "INET-TO-DMZ-UNMAPPED: "
sudo ip netns exec fw iptables -A INPUT \
  -i veth-fw-inet \
  -p tcp --dport 3306 \
  -j REJECT

# 17. VPN -> dmz:22 拒绝 + LOG（无速率限制）
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j LOG --log-prefix "VPN-TO-DMZ-SSH: "
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j REJECT

# 18. 其他VPN流量拒绝 + LOG（5/min）
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "VPN-DENY: "
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 \
  -j REJECT

# 19. 查看完整规则
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
sudo ip netns exec fw iptables -L INPUT -n -v --line-numbers
sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers
