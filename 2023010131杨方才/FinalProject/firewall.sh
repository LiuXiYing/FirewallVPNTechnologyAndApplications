#!/bin/bash
set -e

# 进入fw namespace执行规则配置
sudo ip netns exec fw bash -c '
  # 清空旧规则
  iptables -F
  iptables -F -t nat
  iptables -X
  iptables -P INPUT ACCEPT
  iptables -P OUTPUT ACCEPT
  iptables -P FORWARD DROP

  # 状态检测规则
  iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # office规则
  iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz -s 10.20.0.0/24 -d 10.40.0.0/24 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
  iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz -s 10.20.0.0/24 -d 10.40.0.0/24 -p tcp --dport 22 -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: "
  iptables -A FORWARD -i veth-fw-office -o veth-fw-dmz -s 10.20.0.0/24 -d 10.40.0.0/24 -p tcp --dport 22 -j REJECT

  # guest规则
  iptables -A FORWARD -i veth-fw-guest -o veth-fw-office -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "GUEST-TO-OFFICE: "
  iptables -A FORWARD -i veth-fw-guest -o veth-fw-office -j REJECT
  iptables -A FORWARD -i veth-fw-guest -o veth-fw-dmz -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "GUEST-TO-DMZ: "
  iptables -A FORWARD -i veth-fw-guest -o veth-fw-dmz -j REJECT

  # SNAT规则
  iptables -t nat -A POSTROUTING -s 10.20.0.0/24 -o veth-fw-inet -j MASQUERADE
  iptables -t nat -A POSTROUTING -s 10.30.0.0/24 -o veth-fw-inet -j MASQUERADE
  iptables -t nat -A POSTROUTING -s 10.40.0.0/24 -o veth-fw-inet -j MASQUERADE

  # DNAT规则
  iptables -t nat -A PREROUTING -i veth-fw-inet -p tcp --dport 8080 -j DNAT --to-destination 10.40.0.2:8080
  iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

  # 外网拒绝规则
  iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 22 -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "INET-TO-DMZ-SSH: "
  iptables -A FORWARD -i veth-fw-inet -o veth-fw-dmz -d 10.40.0.2 -p tcp --dport 22 -j REJECT
  iptables -A FORWARD -i veth-fw-inet -o veth-fw-office -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "INET-TO-OFFICE: "
  iptables -A FORWARD -i veth-fw-inet -o veth-fw-office -j REJECT
  iptables -A FORWARD -i veth-fw-inet -o veth-fw-guest -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "INET-TO-GUEST: "
  iptables -A FORWARD -i veth-fw-inet -o veth-fw-guest -j REJECT
'

echo "=== 防火墙规则配置完成 ==="
# 显示核心规则
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers | head -20
sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers | head -10