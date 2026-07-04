#!/bin/bash
# 防火墙策略实现脚本 - 支持多次重复执行，开头自动清空历史规则
# 网段规划
# office:10.20.0.0/24 网卡veth-fw-office
# guest:10.30.0.0/24 网卡veth-fw-guest
# dmz:10.40.0.0/24 网卡veth-fw-dmz
# internet网卡:veth-fw-inet
# DMZ业务主机:10.40.0.2

echo "===== 1. 清空fw命名空间所有旧iptables规则，防止重复执行冲突 ====="
# 清空filter表FORWARD链所有规则
sudo ip netns exec fw iptables -F FORWARD
# 清空nat表所有规则
sudo ip netns exec fw iptables -t nat -F
# 删除自定义链
sudo ip netns exec fw iptables -X
sudo ip netns exec fw iptables -t nat -X

# ====================== 任务2.1：配置FORWARD链默认策略 ======================
sudo ip netns exec fw iptables -P FORWARD DROP

# ====================== 任务2.2：配置状态检测规则 ======================
sudo ip netns exec fw iptables -A FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT

# ====================== 任务2.3：配置office访问dmz规则 ======================
# 允许office访问dmz:8080（原题原始代码无修改）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 自行补充：拒绝office访问dmz:22，带LOG日志+REJECT阻断
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 22 \
  -m conntrack --ctstate NEW \
  -j LOG --log-prefix "OFFICE-DENY-SSH-DMZ: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 22 \
  -m conntrack --ctstate NEW \
  -j REJECT

# ====================== 任务2.4：配置guest隔离规则 ======================
# 拒绝guest访问office（原题原始代码无修改）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -j LOG --log-prefix "GUEST-TO-OFFICE: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -j REJECT

# 自行补充：拒绝guest访问dmz，带LOG日志+REJECT阻断
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -j LOG --log-prefix "GUEST-DENY-DMZ: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -j REJECT

# ====================== 补充放行规则：各区域访问外网 ======================
# office访问internet允许
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-inet \
  -s 10.20.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT
# guest访问internet允许
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-inet \
  -s 10.30.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT
# dmz访问internet允许
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-dmz -o veth-fw-inet \
  -s 10.40.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# ====================== 补充阻断规则：外网internet访问内网 ======================
# 外网禁止SSH访问DMZ dmz:22
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.0/24 \
  -p tcp --dport 22 \
  -m conntrack --ctstate NEW \
  -j LOG --log-prefix "INTERNET-DENY-SSH-DMZ: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.0/24 \
  -p tcp --dport 22 \
  -m conntrack --ctstate NEW \
  -j REJECT
# 外网禁止访问office办公网
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-office \
  -j LOG --log-prefix "INTERNET-DENY-OFFICE: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-office \
  -j REJECT
# 外网禁止访问guest访客网
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-guest \
  -j LOG --log-prefix "INTERNET-DENY-GUEST: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-guest \
  -j REJECT

# ====================== 任务2.5：配置SNAT内网访问外网（原题代码无修改） ======================
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.20.0.0/24 -o veth-fw-inet \
  -j MASQUERADE
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.30.0.0/24 -o veth-fw-inet \
  -j MASQUERADE
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.40.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

# ====================== 任务2.6：配置DNAT外网访问dmz:8080（原题代码无修改） ======================
# DNAT端口映射
sudo ip netns exec fw iptables -t nat -A PREROUTING \
  -i veth-fw-inet \
  -p tcp --dport 8080 \
  -j DNAT --to-destination 10.40.0.2:8080
# DNAT配套FORWARD放行规则
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# ====================== 任务2.7：查看完整规则 ======================
echo -e "\n===== 2. FORWARD链完整规则列表 ====="
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
echo -e "\n===== 3. NAT表完整规则列表 ====="
sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers
