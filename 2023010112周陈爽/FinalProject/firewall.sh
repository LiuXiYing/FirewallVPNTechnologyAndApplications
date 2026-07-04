#!/bin/bash
# 防火墙策略配置脚本 firewall.sh
# 先清空原有规则，避免规则冲突
sudo ip netns exec fw iptables -F
sudo ip netns exec fw iptables -t nat -F
sudo ip netns exec fw iptables -X
sudo ip netns exec fw iptables -t nat -X

# 任务2.1：配置FORWARD链默认拒绝策略
sudo ip netns exec fw iptables -P FORWARD DROP

# 任务2.2：配置状态检测规则（必须放在所有业务规则最前面）
sudo ip netns exec fw iptables -A FORWARD \
-m conntrack --ctstate ESTABLISHED,RELATED \
-j ACCEPT

# 任务2.3：office区域访问DMZ规则
# 1. 允许office访问dmz 8080端口Web服务
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-office -o veth-fw-inet \
-s 10.20.0.0/24 \
-j ACCEPT

sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-office -o veth-fw-dmz \
-s 10.20.0.0/24 -d 10.40.0.0/24 \
-p tcp --dport 8080 \
-m conntrack --ctstate NEW \
-j ACCEPT

# 2. 拒绝office访问dmz 22端口SSH，带日志记录
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-office -o veth-fw-dmz \
-s 10.20.0.0/24 -d 10.40.0.0/24 \
-p tcp --dport 22 \
-m limit --limit 5/min --limit-burst 10 \
-j LOG --log-prefix "OFFICE-DENY-SSH:"
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-office -o veth-fw-dmz \
-s 10.20.0.0/24 -d 10.40.0.0/24 \
-p tcp --dport 22 \
-j REJECT --reject-with icmp-port-unreachable

# 任务2.4：guest区域隔离规则
# 1. 允许guest访问外网internet
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-guest -o veth-fw-inet \
-s 10.30.0.0/24 \
-j ACCEPT

# 2. 拒绝guest访问office内网，带日志
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-guest -o veth-fw-office \
-m limit --limit 5/min --limit-burst 10 \
-j LOG --log-prefix "GUEST-DENY-OFFICE:"
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-guest -o veth-fw-office \
-j REJECT --reject-with icmp-port-unreachable

# 3. 拒绝guest访问DMZ区域，带日志
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-guest -o veth-fw-dmz \
-m limit --limit 5/min --limit-burst 10 \
-j LOG --log-prefix "GUEST-DENY-DMZ:"
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-guest -o veth-fw-dmz \
-j REJECT --reject-with icmp-port-unreachable

# 允许DMZ访问外网（系统更新）
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-dmz -o veth-fw-inet \
-s 10.40.0.0/24 \
-j ACCEPT

# 拒绝外网主动访问office、guest内网
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-inet -o veth-fw-office \
-m limit --limit 5/min --limit-burst 10 \
-j LOG --log-prefix "INTERNET-DENY-OFFICE:"
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-inet -o veth-fw-office \
-j REJECT --reject-with icmp-port-unreachable

sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-inet -o veth-fw-guest \
-m limit --limit 5/min --limit-burst 10 \
-j LOG --log-prefix "INTERNET-DENY-GUEST:"
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-inet -o veth-fw-guest \
-j REJECT --reject-with icmp-port-unreachable

# 拒绝外网SSH访问DMZ 22端口
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-inet -o veth-fw-dmz \
-d 10.40.0.0/24 -p tcp --dport 22 \
-m limit --limit 5/min --limit-burst 10 \
-j LOG --log-prefix "INTERNET-DENY-DMZ-SSH:"
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-inet -o veth-fw-dmz \
-d 10.40.0.0/24 -p tcp --dport 22 \
-j REJECT --reject-with icmp-port-unreachable

# 任务2.5：配置SNAT，内网访问外网地址转换
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
-s 10.20.0.0/24 -o veth-fw-inet \
-j MASQUERADE

sudo ip netns exec fw iptables -t nat -A POSTROUTING \
-s 10.30.0.0/24 -o veth-fw-inet \
-j MASQUERADE

sudo ip netns exec fw iptables -t nat -A POSTROUTING \
-s 10.40.0.0/24 -o veth-fw-inet \
-j MASQUERADE

# 任务2.6：配置DNAT，外网访问公网8080转发至DMZ内网Web服务
sudo ip netns exec fw iptables -t nat -A PREROUTING \
-i veth-fw-inet \
-p tcp --dport 8080 \
-j DNAT --to-destination 10.40.0.2:8080

# DNAT配套放行外网访问DMZ 8080端口规则
sudo ip netns exec fw iptables -A FORWARD \
-i veth-fw-inet -o veth-fw-dmz \
-d 10.40.0.2 -p tcp --dport 8080 \
-m conntrack --ctstate NEW \
-j ACCEPT

# 任务3.5：VPN流量FORWARD规则
# VPN用户可以访问office
sudo ip netns exec fw iptables -A FORWARD \
-i wg0 -o veth-fw-office \
-s 10.10.10.2 -d 10.20.0.0/24 \
-m conntrack --ctstate NEW \
-j ACCEPT

# VPN用户可以访问dmz:8080
sudo ip netns exec fw iptables -A FORWARD \
-i wg0 -o veth-fw-dmz \
-s 10.10.10.2 -d 10.40.0.2 \
-p tcp --dport 8080 \
-m conntrack --ctstate NEW \
-j ACCEPT

# VPN用户不能访问dmz:22（拒绝+LOG）
sudo ip netns exec fw iptables -A FORWARD \
-i wg0 -o veth-fw-dmz \
-s 10.10.10.2 -d 10.40.0.2 \
-p tcp --dport 22 \
-j LOG --log-prefix "VPN-TO-DMZ-SSH:"

sudo ip netns exec fw iptables -A FORWARD \
-i wg0 -o veth-fw-dmz \
-s 10.10.10.2 -d 10.40.0.2 \
-p tcp --dport 22 \
-j REJECT --reject-with icmp-port-unreachable

# 其他VPN流量拒绝+LOG
sudo ip netns exec fw iptables -A FORWARD \
-i wg0 \
-m limit --limit 5/min --limit-burst 10 \
-j LOG --log-prefix "VPN-DENY:"

sudo ip netns exec fw iptables -A FORWARD \
-i wg0 \
-j REJECT --reject-with icmp-port-unreachable

# 任务2.7：查看防火墙规则命令
echo "===== FORWARD链规则 ====="
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
echo -e "\n===== NAT表规则 ====="
sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers