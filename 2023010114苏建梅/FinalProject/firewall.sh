## firewall.sh

#!/bin/bash
# firewall.sh - 实验二：防火墙策略实现

# 任务2.1：配置FORWARD链默认策略
sudo ip netns exec fw iptables -P FORWARD DROP

# 任务2.2：配置状态检测规则
sudo ip netns exec fw iptables -A FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT

# 任务2.3：配置office访问dmz规则
# 允许office访问dmz:8080
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 拒绝office访问dmz:22
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 22 \
  -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: "

sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 22 \
  -j REJECT

# office访问internet
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-inet \
  -s 10.20.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 任务2.4：配置guest隔离规则
# 拒绝guest访问office
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -j LOG --log-prefix "GUEST-TO-OFFICE: "

sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -j REJECT

# 拒绝guest访问dmz
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -j LOG --log-prefix "GUEST-TO-DMZ: "

sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -j REJECT

# guest访问internet
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-inet \
  -s 10.30.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# dmz访问internet
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-dmz -o veth-fw-inet \
  -s 10.40.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 拒绝dmz访问office
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-dmz -o veth-fw-office \
  -s 10.40.0.0/24 \
  -j REJECT

# 拒绝dmz访问guest
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-dmz -o veth-fw-guest \
  -s 10.40.0.0/24 \
  -j REJECT

# 拒绝internet访问office
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-office \
  -s 203.0.113.0/24 \
  -j DROP

# 拒绝internet访问guest
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-guest \
  -s 203.0.113.0/24 \
  -j DROP

# 拒绝internet访问dmz:22
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -s 203.0.113.0/24 -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j DROP

# 任务2.5：配置SNAT
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.20.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.30.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.40.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

# 任务2.6：配置DNAT
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

# 任务2.7：查看完整规则
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers
