#!/bin/bash
# 防火墙访问控制+NAT规则一键部署脚本
# 执行命名空间锁定fw
NS="fw"

# 清空原有规则，避免重复叠加
sudo ip netns exec $NS iptables -F FORWARD
sudo ip netns exec $NS iptables -F -t nat
sudo ip netns exec $NS iptables -Z FORWARD
sudo ip netns exec $NS iptables -Z -t nat

## 任务2.1 FORWARD默认全部拒绝
sudo ip netns exec $NS iptables -P FORWARD DROP

## 任务2.2 状态检测：放行已建立、相关连接回包
sudo ip netns exec $NS iptables -A FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT

## 任务2.3 office与DMZ访问规则
# 允许office访问dmz 8080新连接
sudo ip netns exec $NS iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT
# 记录office访问dmz 22非法流量日志
sudo ip netns exec $NS iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 22 \
  -m conntrack --ctstate NEW \
  -j LOG --log-prefix "OFFICE-DENY-SSH-DMZ: " --log-level info
# 拒绝office访问dmz 22端口
sudo ip netns exec $NS iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 22 \
  -m conntrack --ctstate NEW \
  -j REJECT

## 任务2.4 guest隔离规则
# guest禁止访问office，带日志
sudo ip netns exec $NS iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level info
sudo ip netns exec $NS iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -j REJECT
# guest禁止访问dmz，带日志
sudo ip netns exec $NS iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -j LOG --log-prefix "GUEST-TO-DMZ: " --log-level info
sudo ip netns exec $NS iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -j REJECT
# guest允许访问外网internet
sudo ip netns exec $NS iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-inet \
  -s 10.30.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# office允许访问外网internet
sudo ip netns exec $NS iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-inet \
  -s 10.20.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# dmz允许访问外网internet
sudo ip netns exec $NS iptables -A FORWARD \
  -i veth-fw-dmz -o veth-fw-inet \
  -s 10.40.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 外网禁止访问office、guest全流量
sudo ip netns exec $NS iptables -A FORWARD -i veth-fw-inet -o veth-fw-office -j REJECT
sudo ip netns exec $NS iptables -A FORWARD -i veth-fw-inet -o veth-fw-guest -j REJECT
# 外网禁止访问dmz 22端口
sudo ip netns exec $NS iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -p tcp --dport 22 \
  -j REJECT

## 任务2.5 SNAT内网访问外网地址转换
sudo ip netns exec $NS iptables -t nat -A POSTROUTING \
  -s 10.20.0.0/24 -o veth-fw-inet \
  -j MASQUERADE
sudo ip netns exec $NS iptables -t nat -A POSTROUTING \
  -s 10.30.0.0/24 -o veth-fw-inet \
  -j MASQUERADE
sudo ip netns exec $NS iptables -t nat -A POSTROUTING \
  -s 10.40.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

## 任务2.6 DNAT外网8080转发至DMZ 10.40.0.2:8080
sudo ip netns exec $NS iptables -t nat -A PREROUTING \
  -i veth-fw-inet \
  -p tcp --dport 8080 \
  -j DNAT --to-destination 10.40.0.2:8080
# DNAT配套FORWARD放行规则
sudo ip netns exec $NS iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

echo "防火墙规则全部加载完成"
echo "查看FORWARD链规则：sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers"
echo "查看NAT规则：sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers"