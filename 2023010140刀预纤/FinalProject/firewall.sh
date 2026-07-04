#!/bin/bash
# 清空旧规则
sudo ip netns exec fw iptables -F
sudo ip netns exec fw iptables -t nat -F
sudo ip netns exec fw iptables -X

# 1. FORWARD默认拒绝
sudo ip netns exec fw iptables -P FORWARD DROP
sudo ip netns exec fw iptables -P INPUT ACCEPT
sudo ip netns exec fw iptables -P OUTPUT ACCEPT

# 2. 状态检测回程优先放行（必须放在规则最顶部）
sudo ip netns exec fw iptables -A FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT

# ===================== office访问控制 =====================
# 允许office访问dmz 8080
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 拒绝office访问dmz 22，日志+限速
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -p tcp --dport 22 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -p tcp --dport 22 \
  -j REJECT

# 允许office访问外网
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-inet \
  -j ACCEPT

# ===================== guest隔离规则 =====================
# guest仅允许访问外网
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-inet \
   -j ACCEPT

# guest禁止访问office 日志+限速
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-OFFICE: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -j REJECT

# guest禁止访问dmz 日志+限速
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-DMZ: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -j REJECT

# ===================== DMZ访问外网 =====================
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-dmz -o veth-fw-inet \
  -j ACCEPT

# ===================== SNAT内网上网 =====================
sudo ip netns exec fw iptables -t nat -A POSTROUTING -s 10.20.0.0/24 -o veth-fw->
sudo ip netns exec fw iptables -t nat -A POSTROUTING -s 10.30.0.0/24 -o veth-fw->
sudo ip netns exec fw iptables -t nat -A POSTROUTING -s 10.40.0.0/24 -o veth-fw->

# ===================== DNAT外网映射8080 =====================
sudo ip netns exec fw iptables -t nat -A PREROUTING \
  -i veth-fw-inet -p tcp --dport 8080 \
  -j DNAT --to-destination 10.40.0.2:8080

# DNAT放行规则
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

  # 外网禁止访问dmz 22、内网、访客网
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz -p tcp --dport 22 -j REJECT
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-office -j REJECT
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-guest -j REJECT

# 放行WireGuard UDP 51820（VPN握手必备，解决之前收不到包的问题）
sudo ip netns exec fw iptables -A INPUT -p udp --dport 51820 -j ACCEPT
