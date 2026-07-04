#!/bin/bash
# 防火墙策略配置脚本

echo "=== 清理旧规则 ==="
sudo ip netns exec fw iptables -F
sudo ip netns exec fw iptables -X
sudo ip netns exec fw iptables -t nat -F
sudo ip netns exec fw iptables -t nat -X
sudo ip netns exec fw iptables -t mangle -F 2>/dev/null || true

echo "=== 设置默认策略 ==="
sudo ip netns exec fw iptables -P FORWARD DROP
sudo ip netns exec fw iptables -P INPUT DROP
sudo ip netns exec fw iptables -P OUTPUT ACCEPT

echo "=== 允许本地回环和内部接口 ==="
sudo ip netns exec fw iptables -I INPUT 1 -i lo -j ACCEPT
sudo ip netns exec fw iptables -I INPUT 2 -i veth-fw-office -j ACCEPT
sudo ip netns exec fw iptables -I INPUT 3 -i veth-fw-guest -j ACCEPT
sudo ip netns exec fw iptables -I INPUT 4 -i veth-fw-dmz -j ACCEPT
sudo ip netns exec fw iptables -I INPUT 5 -i veth-fw-inet -j ACCEPT
sudo ip netns exec fw iptables -I INPUT 6 -i veth-fw-remote -j ACCEPT

echo "=== 状态检测规则（必须放在最前面）==="
sudo ip netns exec fw iptables -A FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT

echo "=== 1. office访问规则 ==="
# 允许office访问dmz:8080
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 拒绝office访问dmz:22（LOG + REJECT）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 22 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 22 \
  -j REJECT

echo "=== 2. guest隔离规则 ==="
# 拒绝guest访问office（LOG + REJECT）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -j REJECT

# 拒绝guest访问dmz（LOG + REJECT）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-DMZ: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -j REJECT

# 允许guest访问internet
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-inet \
  -s 10.30.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

echo "=== 3. office访问internet ==="
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-inet \
  -s 10.20.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

echo "=== 4. dmz访问internet ==="
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-dmz -o veth-fw-inet \
  -s 10.40.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

echo "=== 5. internet访问控制 ==="
# 拒绝internet访问office（LOG + REJECT）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-office \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "INET-TO-OFFICE: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-office \
  -j REJECT

# 拒绝internet访问guest（LOG + REJECT）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-guest \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "INET-TO-GUEST: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-guest \
  -j REJECT

# 拒绝internet访问dmz:22
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 22 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "INET-TO-DMZ-SSH: " --log-level 4

sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 22 \
  -j REJECT

echo "=== 6. SNAT配置 ==="
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.20.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.30.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.40.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

echo "=== 7. DNAT配置 ==="
sudo ip netns exec fw iptables -t nat -A PREROUTING \
  -i veth-fw-inet \
  -p tcp --dport 8080 \
  -j DNAT --to-destination 10.40.0.2:8080

# 对应的FORWARD规则
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

echo "=== 防火墙规则配置完成 ==="
