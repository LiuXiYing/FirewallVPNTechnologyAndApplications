#!/bin/bash

echo "====================================="
echo " Enterprise Firewall Configuration"
echo "====================================="

##############################
# 清空旧规则
##############################

ip netns exec fw iptables -F
ip netns exec fw iptables -X

ip netns exec fw iptables -t nat -F
ip netns exec fw iptables -t nat -X

##############################
# 默认策略
##############################

ip netns exec fw iptables -P INPUT ACCEPT
ip netns exec fw iptables -P OUTPUT ACCEPT
ip netns exec fw iptables -P FORWARD DROP

##############################
# 状态检测
##############################

ip netns exec fw iptables -A FORWARD \
-m conntrack --ctstate ESTABLISHED,RELATED \
-j ACCEPT

#################################################
# Office → DMZ:8080
#################################################

ip netns exec fw iptables -A FORWARD \
-i veth-fw-office \
-o veth-fw-dmz \
-s 10.20.0.0/24 \
-d 10.40.0.0/24 \
-p tcp \
--dport 8080 \
-m conntrack --ctstate NEW \
-j ACCEPT

#################################################
# Office → DMZ:22
#################################################

ip netns exec fw iptables -A FORWARD \
-i veth-fw-office \
-o veth-fw-dmz \
-p tcp \
--dport 22 \
-j LOG \
--log-prefix "OFFICE-DMZ-SSH: "

ip netns exec fw iptables -A FORWARD \
-i veth-fw-office \
-o veth-fw-dmz \
-p tcp \
--dport 22 \
-j REJECT

#################################################
# Office → Internet
#################################################

ip netns exec fw iptables -A FORWARD \
-i veth-fw-office \
-o veth-fw-int \
-j ACCEPT

#################################################
# Guest → Internet
#################################################

ip netns exec fw iptables -A FORWARD \
-i veth-fw-guest \
-o veth-fw-int \
-j ACCEPT

#################################################
# Guest → Office
#################################################

ip netns exec fw iptables -A FORWARD \
-i veth-fw-guest \
-o veth-fw-office \
-j LOG \
--log-prefix "GUEST-OFFICE: "

ip netns exec fw iptables -A FORWARD \
-i veth-fw-guest \
-o veth-fw-office \
-j REJECT

#################################################
# Guest → DMZ
#################################################

ip netns exec fw iptables -A FORWARD \
-i veth-fw-guest \
-o veth-fw-dmz \
-j LOG \
--log-prefix "GUEST-DMZ: "

ip netns exec fw iptables -A FORWARD \
-i veth-fw-guest \
-o veth-fw-dmz \
-j REJECT

#################################################
# DMZ → Internet
#################################################

ip netns exec fw iptables -A FORWARD \
-i veth-fw-dmz \
-o veth-fw-int \
-j ACCEPT

#################################################
# Internet → Office
#################################################

ip netns exec fw iptables -A FORWARD \
-i veth-fw-int \
-o veth-fw-office \
-j REJECT

#################################################
# Internet → Guest
#################################################

ip netns exec fw iptables -A FORWARD \
-i veth-fw-int \
-o veth-fw-guest \
-j REJECT

#################################################
# Internet → DMZ SSH
#################################################

ip netns exec fw iptables -A FORWARD \
-i veth-fw-int \
-o veth-fw-dmz \
-p tcp \
--dport 22 \
-j REJECT

#################################################
# NAT
#################################################

ip netns exec fw iptables -t nat -A POSTROUTING \
-s 10.20.0.0/24 \
-o veth-fw-int \
-j MASQUERADE

ip netns exec fw iptables -t nat -A POSTROUTING \
-s 10.30.0.0/24 \
-o veth-fw-int \
-j MASQUERADE

ip netns exec fw iptables -t nat -A POSTROUTING \
-s 10.40.0.0/24 \
-o veth-fw-int \
-j MASQUERADE

#################################################
# DNAT
#################################################

ip netns exec fw iptables -t nat -A PREROUTING \
-i veth-fw-int \
-p tcp \
--dport 8080 \
-j DNAT --to-destination 10.40.0.2:8080

ip netns exec fw iptables -A FORWARD \
-i veth-fw-int \
-o veth-fw-dmz \
-d 10.40.0.2 \
-p tcp \
--dport 8080 \
-m conntrack --ctstate NEW \
-j ACCEPT

#################################################
# 查看规则
#################################################

echo
echo "========== FORWARD =========="
ip netns exec fw iptables -L FORWARD -n -v --line-numbers

echo
echo "========== NAT =========="
ip netns exec fw iptables -t nat -L -n -v --line-numbers
