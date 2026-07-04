#!/bin/bash

set -e

########################################
# 清空规则
########################################

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

########################################
# 默认策略
########################################

iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD DROP

########################################
# 状态检测
########################################

iptables -A FORWARD \
    -m conntrack --ctstate ESTABLISHED,RELATED \
    -j ACCEPT

########################################
# Office → DMZ Web
########################################

iptables -A FORWARD \
    -i veth-fw-office \
    -o veth-fw-dmz \
    -s 10.20.0.0/24 \
    -d 10.40.0.0/24 \
    -p tcp \
    --dport 8080 \
    -m conntrack --ctstate NEW \
    -j ACCEPT

########################################
# Office → DMZ SSH
########################################

iptables -A FORWARD \
    -i veth-fw-office \
    -o veth-fw-dmz \
    -p tcp \
    --dport 22 \
    -j LOG \
    --log-prefix "OFFICE-TO-DMZ-SSH: "

iptables -A FORWARD \
    -i veth-fw-office \
    -o veth-fw-dmz \
    -p tcp \
    --dport 22 \
    -j REJECT

########################################
# Office → Internet
########################################

iptables -A FORWARD \
    -i veth-fw-office \
    -o veth-fw-inet \
    -j ACCEPT

########################################
# Guest → Internet
########################################

iptables -A FORWARD \
    -i veth-fw-guest \
    -o veth-fw-inet \
    -j ACCEPT

########################################
# Guest → Office
########################################

iptables -A FORWARD \
    -i veth-fw-guest \
    -o veth-fw-office \
    -j LOG \
    --log-prefix "GUEST-TO-OFFICE: "

iptables -A FORWARD \
    -i veth-fw-guest \
    -o veth-fw-office \
    -j REJECT

########################################
# Guest → DMZ
########################################

iptables -A FORWARD \
    -i veth-fw-guest \
    -o veth-fw-dmz \
    -j LOG \
    --log-prefix "GUEST-TO-DMZ: "

iptables -A FORWARD \
    -i veth-fw-guest \
    -o veth-fw-dmz \
    -j REJECT

########################################
# DMZ → Internet
########################################

iptables -A FORWARD \
    -i veth-fw-dmz \
    -o veth-fw-inet \
    -j ACCEPT

########################################
# Internet → Office
########################################

iptables -A FORWARD \
    -i veth-fw-inet \
    -o veth-fw-office \
    -j REJECT

########################################
# Internet → Guest
########################################

iptables -A FORWARD \
    -i veth-fw-inet \
    -o veth-fw-guest \
    -j REJECT

########################################
# Internet → DMZ:8080
########################################

iptables -A FORWARD \
    -i veth-fw-inet \
    -o veth-fw-dmz \
    -d 10.40.0.2 \
    -p tcp \
    --dport 8080 \
    -m conntrack --ctstate NEW \
    -j ACCEPT

########################################
# Internet → DMZ:22
########################################

iptables -A FORWARD \
    -i veth-fw-inet \
    -o veth-fw-dmz \
    -p tcp \
    --dport 22 \
    -j REJECT

########################################
# NAT
########################################

iptables -t nat -A POSTROUTING \
    -s 10.20.0.0/24 \
    -o veth-fw-inet \
    -j MASQUERADE

iptables -t nat -A POSTROUTING \
    -s 10.30.0.0/24 \
    -o veth-fw-inet \
    -j MASQUERADE

iptables -t nat -A POSTROUTING \
    -s 10.40.0.0/24 \
    -o veth-fw-inet \
    -j MASQUERADE

iptables -t nat -A PREROUTING \
    -i veth-fw-inet \
    -p tcp \
    --dport 8080 \
    -j DNAT \
    --to-destination 10.40.0.2:8080

echo "Firewall configuration completed."