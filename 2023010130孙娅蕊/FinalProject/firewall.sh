
#!/bin/bash
# 防火墙策略配置脚本
# 所有iptables操作仅在fw命名空间内执行
EXEC="sudo ip netns exec fw"

# 清空fw内所有旧规则（FORWARD、NAT、自定义链）
$EXEC iptables -F FORWARD
$EXEC iptables -t nat -F
$EXEC iptables -X
$EXEC iptables -t nat -X
# 任务2.1：配置FORWARD链默认策略为DROP
$EXEC iptables -P FORWARD DROP

# 任务2.2：配置状态检测规则（允许已建立/相关连接）
$EXEC iptables -A FORWARD \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT

# 任务2.3：配置office访问dmz规则
## 允许office访问dmz:8080
$EXEC iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

## 拒绝office访问dmz:22（带LOG）
$EXEC iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-dmz \
  -s 10.20.0.0/24 -d 10.40.0.0/24 \
  -p tcp --dport 22 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "OFFICE-TO-DMZ-SSH: " --log-level 4


# 任务2.4：配置guest隔离规则
## 拒绝guest访问office（带LOG）
$EXEC iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-OFFICE: " --log-level 4

$EXEC iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-office \
  -j REJECT --reject-with icmp-host-prohibited

## 拒绝guest访问dmz（带LOG）
$EXEC iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "GUEST-TO-DMZ: " --log-level 4

$EXEC iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-dmz \
  -j REJECT --reject-with icmp-host-prohibited

# 任务2.5：配置SNAT让内网访问外网
## office网段SNAT
$EXEC iptables -t nat -A POSTROUTING \
  -s 10.20.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

## guest网段SNAT
$EXEC iptables -t nat -A POSTROUTING \
  -s 10.30.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

## dmz网段SNAT
$EXEC iptables -t nat -A POSTROUTING \
  -s 10.40.0.0/24 -o veth-fw-inet \
  -j MASQUERADE

# 任务2.6：配置DNAT让外网访问dmz:8080
## DNAT规则（外网8080端口映射到dmz的8080）
$EXEC iptables -t nat -A PREROUTING \
  -i veth-fw-inet \
  -p tcp --dport 8080 \
  -j DNAT --to-destination 10.40.0.2:8080

## 对应的FORWARD规则
$EXEC iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 \
  -p tcp --dport 8080 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 额外规则：拒绝外网访问dmz:22（带LOG）
$EXEC iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 \
  -p tcp --dport 22 \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "INET-TO-DMZ-SSH: " --log-level 4

$EXEC iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-dmz \
  -d 10.40.0.2 \
  -p tcp --dport 22 \
  -j REJECT --reject-with tcp-reset

# 额外规则：拒绝外网访问office/guest（带LOG）
$EXEC iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-office \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "INET-TO-OFFICE: " --log-level 4

$EXEC iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-office \
  -j REJECT --reject-with icmp-host-prohibited

$EXEC iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-guest \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "INET-TO-GUEST: " --log-level 4

$EXEC iptables -A FORWARD \
  -i veth-fw-inet -o veth-fw-guest \
  -j REJECT --reject-with icmp-host-prohibited


# 允许office访问外网internet
$EXEC iptables -A FORWARD \
  -i veth-fw-office -o veth-fw-inet \
  -s 10.20.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 允许guest访问外网internet
$EXEC iptables -A FORWARD \
  -i veth-fw-guest -o veth-fw-inet \
  -s 10.30.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# 允许dmz访问外网internet
$EXEC iptables -A FORWARD \
  -i veth-fw-dmz -o veth-fw-inet \
  -s 10.40.0.0/24 \
  -m conntrack --ctstate NEW \
  -j ACCEPT




# 显示规则配置完成
echo "防火墙规则配置完成！"
echo "================== FORWARD 规则 =================="
$EXEC iptables -L FORWARD -n -v --line-numbers
echo "================== NAT 规则 =================="
$EXEC iptables -t nat -L -n -v --line-numbers
