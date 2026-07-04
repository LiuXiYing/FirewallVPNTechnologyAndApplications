#!/bin/bash
# firewall.sh 企业边界防火墙iptables策略脚本（修正版）
# 运行环境：fw网络命名空间

# ====================== 1. 清空原有防火墙规则，重置策略 ======================
echo "===== 清空fw命名空间原有iptables所有规则、链、NAT表 ====="
sudo ip netns exec fw iptables -F
sudo ip netns exec fw iptables -X
sudo ip netns exec fw iptables -t nat -F
sudo ip netns exec fw iptables -t nat -X
sudo ip netns exec fw iptables -t mangle -F
sudo ip netns exec fw iptables -t mangle -X

# 设置FORWARD链默认策略：全部拒绝
sudo ip netns exec fw iptables -P FORWARD DROP
sudo ip netns exec fw iptables -P INPUT ACCEPT
sudo ip netns exec fw iptables -P OUTPUT ACCEPT

# ====================== 2. 状态连接检测规则 ======================
echo "===== 配置连接状态检测规则 ESTABLISHED,RELATED ====="
sudo ip netns exec fw iptables -A FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT

# ====================== 3. Office办公网访问DMZ策略 ======================
echo "===== 配置Office <-> DMZ 访问控制策略 ===="
# 允许office访问dmz:8080
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 拒绝office访问dmz:22（TCP专用，tcp-reset有效）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 22 \
  -m conntrack --ctstate NEW \
  -j LOG --log-prefix "OFFICE-BLOCK-DMZ-SSH: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 22 \
  -m conntrack --ctstate NEW \
  -j REJECT --reject-with tcp-reset

# ====================== 4. Guest访客网络隔离策略 ======================
echo "===== 配置Guest访客网络隔离策略 ===="
# 拒绝guest访问office（所有协议）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -s 10.30.0.0/24 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW \
  -j LOG --log-prefix "GUEST-BLOCK-OFFICE: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -s 10.30.0.0/24 -d 10.20.0.0/24 \
  -m conntrack --ctstate NEW \
  -j REJECT --reject-with icmp-host-unreachable

# 拒绝guest访问dmz（所有协议）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -s 10.30.0.0/24 -d 10.40.0.0/24 \
  -m conntrack --ctstate NEW \
  -j LOG --log-prefix "GUEST-BLOCK-DMZ: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -s 10.30.0.0/24 -d 10.40.0.0/24 \
  -m conntrack --ctstate NEW \
  -j REJECT --reject-with icmp-host-unreachable

# ====================== 5. SNAT（内网访问外网） ======================
echo "===== 配置Office/Guest/DMZ访问外网SNAT MASQUERADE ===="
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.20.0.0/24 -o veth-fw-inet -j MASQUERADE
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.30.0.0/24 -o veth-fw-inet -j MASQUERADE
sudo ip netns exec fw iptables -t nat -A POSTROUTING \
  -s 10.40.0.0/24 -o veth-fw-inet -j MASQUERADE

# ====================== 6. DNAT（外网访问DMZ:8080） ======================
echo "===== 配置外网DNAT映射DMZ 8080 Web服务 ===="
sudo ip netns exec fw iptables -t nat -A PREROUTING \
  -i veth-fw-inet -p tcp --dport 8080 \
  -j DNAT --to-destination 10.40.0.2:8080

# FORWARD放行外网到DMZ:8080
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# ====================== 7. 各区域访问外网放行规则 ======================
echo "===== 配置各区域访问外网通用放行规则 ===="
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-inet \
  -m conntrack --ctstate NEW -j ACCEPT
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-inet \
  -m conntrack --ctstate NEW -j ACCEPT
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-dmz -o veth-fw-inet \
  -m conntrack --ctstate NEW -j ACCEPT

# ====================== 8. 外网主动入站拒绝（显式REJECT+LOG） ======================
echo "===== 配置外网到内网各区域的拒绝规则 ====="
# 外网到DMZ:22 (TCP专用)
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -p tcp --dport 22 \
  -m conntrack --ctstate NEW \
  -j LOG --log-prefix "INET-BLOCK-DMZ-SSH: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -p tcp --dport 22 \
  -m conntrack --ctstate NEW \
  -j REJECT --reject-with tcp-reset

# 外网到Office（所有协议）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-office \
  -m conntrack --ctstate NEW \
  -j LOG --log-prefix "INET-BLOCK-OFFICE: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-office \
  -m conntrack --ctstate NEW \
  -j REJECT --reject-with icmp-host-unreachable

# 外网到Guest（所有协议）
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-guest \
  -m conntrack --ctstate NEW \
  -j LOG --log-prefix "INET-BLOCK-GUEST: "
sudo ip netns exec fw iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-guest \
  -m conntrack --ctstate NEW \
  -j REJECT --reject-with icmp-host-unreachable

# ====================== 9. 输出规则 ======================
echo -e "\n==================== FORWARD 链 ===================="
sudo ip netns exec fw iptables -L FORWARD -n -v --line-numbers
echo -e "\n==================== NAT表 ===================="
sudo ip netns exec fw iptables -t nat -L -n -v --line-numbers

echo -e "\n===== 防火墙策略全部配置完成 ====="