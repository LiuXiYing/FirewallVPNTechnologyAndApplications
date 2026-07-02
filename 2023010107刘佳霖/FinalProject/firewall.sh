#!/bin/bash
# FinalProject/firewall.sh 防火墙、SNAT、DNAT、全审计LOG、DMZ并发加固
# 清空fw全部旧规则
sudo ip netns exec fw iptables -F FORWARD
sudo ip netns exec fw iptables -F INPUT
sudo ip netns exec fw iptables -F OUTPUT
sudo ip netns exec fw iptables -t nat -F PREROUTING
sudo ip netns exec fw iptables -t nat -F POSTROUTING
sudo ip netns exec fw iptables -t nat -F OUTPUT

# 设置转发默认拒绝
sudo ip netns exec fw iptables -P FORWARD DROP

# 最高优先级：状态检测，放行回程流量
sudo ip netns exec fw iptables -A FORWARD \
-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# ========== Office访问DMZ规则 ==========
# 允许office访问dmz 8080
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-office -o veth-fw-dmz \
-s 10.20.0.0/24 -d 10.40.0.0/24 \
-p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
# 拒绝office访问dmz 22，带审计日志
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-office -o veth-fw-dmz \
-s 10.20.0.0/24 -d 10.40.0.0/24 \
-p tcp --dport 22 -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-office -o veth-fw-dmz \
-s 10.20.0.0/24 -d 10.40.0.0/24 \
-p tcp --dport 22 -j REJECT

# ========== 5 条审计 LOG 规则（带 -i/-o 网卡匹配，插入在最前） ==========
# 1. guest访问office
sudo ip netns exec fw iptables -I FORWARD \
-i veth-fw-guest -o veth-fw-office \
-j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4

# 2. guest访问dmz
sudo ip netns exec fw iptables -I FORWARD \
-i veth-fw-guest -o veth-fw-dmz \
-j LOG --log-prefix "GUEST-TO-DMZ: " --log-level 4

# 3. VPN访问dmz 22端口
sudo ip netns exec fw iptables -I FORWARD \
-i wg0 -o veth-fw-dmz -p tcp --dport 22 \
-j LOG --log-prefix "VPN-TO-DMZ-SSH: " --log-level 4

# 4. internet访问office内网
sudo ip netns exec fw iptables -I FORWARD \
-i veth-fw-inet -o veth-fw-office \
-j LOG --log-prefix "INET-TO-OFFICE: " --log-level 4

# 5. VPN其余所有违规流量
sudo ip netns exec fw iptables -I FORWARD \
-i wg0 \
-j LOG --log-prefix "VPN-DENY: " --log-level 4

# ========== Guest隔离规则（全带LOG） ==========
# guest访问office（拒绝 + 对应审计日志）
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-guest -o veth-fw-office -j REJECT
# guest访问dmz（拒绝 + 对应审计日志）
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-guest -o veth-fw-dmz -j REJECT
# guest允许访问外网
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-guest -o veth-fw-inet -j ACCEPT

# office、dmz允许访问外网
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-office -o veth-fw-inet -j ACCEPT
sudo ip netns exec fw iptables -A FORWARD -i veth-fw-dmz -o veth-fw-inet -j ACCEPT

# ========== Internet外网隔离规则（全带LOG） ==========
# 外网禁止访问办公网（LOG 已由顶部 #4 处理）
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-inet -o veth-fw-office -j REJECT
# 外网禁止访问访客网
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-inet -o veth-fw-guest -j LOG --log-prefix "INET-TO-GUEST: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-inet -o veth-fw-guest -j REJECT
# 外网禁止访问DMZ 22端口
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 22 \
-j LOG --log-prefix "INET-TO-DMZ-SSH: " --log-level 4
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 22 -j REJECT

# ========== SNAT 内网访问外网地址转换 ==========
sudo ip netns exec fw iptables -t nat -A POSTROUTING -s 10.20.0.0/24 -o veth-fw-inet -j MASQUERADE
sudo ip netns exec fw iptables -t nat -A POSTROUTING -s 10.30.0.0/24 -o veth-fw-inet -j MASQUERADE
sudo ip netns exec fw iptables -t nat -A POSTROUTING -s 10.40.0.0/24 -o veth-fw-inet -j MASQUERADE

# ========== DNAT 外网发布DMZ 8080 Web服务 ==========
sudo ip netns exec fw iptables -t nat -A PREROUTING \
-i veth-fw-inet -p tcp --dport 8080 -j DNAT --to-destination 10.40.0.2:8080
# DNAT配套放行规则
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 \
-m conntrack --ctstate NEW -j ACCEPT

# ========== 第五部分改进方案：边界安全加固 ==========
# 1. connlimit：限制单IP访问DMZ最大并发连接（防止DDoS/CC攻击）
#    WSL内核不支持connlimit模块，在生产环境取消注释即可生效
# sudo ip netns exec fw iptables -I FORWARD \
#   -p tcp --syn --dport 8080 -d 10.40.0.2 \
#   -m connlimit --connlimit-above 10 --connlimit-mask 32 \
#   -j REJECT --reject-with tcp-reset

# 2. recent：限制guest区域扫描频率（防止端口扫描/暴力破解）
#    每秒超过20个新连接则DROP后续包
# sudo ip netns exec fw iptables -I FORWARD -i veth-fw-guest \
#   -m recent --name GUEST_SCAN --set
# sudo ip netns exec fw iptables -I FORWARD -i veth-fw-guest \
#   -m recent --name GUEST_SCAN --update --seconds 1 --hitcount 20 \
#   -j DROP

# ========== VPN (wg0) 访问控制规则 ==========

# VPN → Office 办公网 (允许)
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-office \
  -s 10.10.10.2 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# VPN → DMZ:8080 Web (允许)
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# VPN → DMZ:22 (拒绝 - LOG 已由顶部 #3 处理)
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 -o veth-fw-dmz \
  -s 10.10.10.2 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j REJECT

# VPN 其他流量默认拒绝（LOG 已由顶部 #5 处理）
sudo ip netns exec fw iptables -A FORWARD \
  -i wg0 \
  -j REJECT

echo "=== 防火墙规则加载完成 ==="
echo "查看转发规则：sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers"
echo "查看NAT规则：sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers"