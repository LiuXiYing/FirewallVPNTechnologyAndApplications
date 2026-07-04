apyy@localhost:~$ # 创建6个网络命名空间
sudo ip netns add fw
sudo ip netns add office
sudo ip netns add guest
sudo ip netns add dmz
sudo ip netns add internet
sudo ip netns add remote
[sudo] password for apyy:
apyy@localhost:~$ # office网段veth配置
sudo ip link add veth-fw-office type veth peer name veth-office
sudo ip link set veth-fw-office netns fw
sudo ip link set veth-office netns office
sudo ip netns exec fw ip addr add 10.20.0.1/24 dev veth-fw-office
sudo ip netns exec fw ip link set veth-fw-office up
sudo ip netns exec fw ip link set lo up
sudo ip netns exec office ip addr add 10.20.0.2/24 dev veth-office
sudo ip netns exec office ip link set veth-office up
sudo ip netns exec office ip link set lo up

# guest网段veth配置
sudo ip link add veth-fw-guest type veth peer name veth-guest
sudo ip link set veth-fw-guest netns fw
sudo ip link set veth-guest netns guest
sudo ip netns exec fw ip addr add 10.30.0.1/24 dev veth-fw-guest
sudo ip netns exec fw ip link set veth-fw-guest up
sudo ip netns exec guest ip addr add 10.30.0.2/24 dev veth-guest
sudo ip netns exec guest ip link set veth-guest up
sudo ip netns exec guest ip link set lo up

# dmz网段veth配置
sudo ip link add veth-fw-dmz type veth peer name veth-dmz
sudo ip link set veth-fw-dmz netns fw
sudo ip link set veth-dmz netns dmz
sudo ip netns exec fw ip addr add 10.40.0.1/24 dev veth-fw-dmz
sudo ip netns exec fw ip link set veth-fw-dmz up
sudo ip netns exec dmz ip addr add 10.40.0.2/24 dev veth-dmz
sudo ip netns exec dmz ip link set veth-dmz up
echo "sudo ip netns exec internet ping -c 2 203.0.113.1".0.113.1-inet
net.ipv4.ip_forward = 1
====拓扑搭建完成====
连通测试命令：
sudo ip netns exec office ping -c 2 10.20.0.1
sudo ip netns exec guest ping -c 2 10.30.0.1
sudo ip netns exec dmz ping -c 2 10.40.0.1
sudo ip netns exec internet ping -c 2 203.0.113.1
apyy@localhost:~$ # 各区域主机的默认路由指向fw
sudo ip netns exec office ip route add default via 10.20.0.1
sudo ip netns exec guest ip route add default via 10.30.0.1
sudo ip netns exec dmz ip route add default via 10.40.0.1

# fw开启IP转发
sudo ip netns exec fw sysctl -w net.ipv4.ip_forward=1
RTNETLINK answers: File exists
RTNETLINK answers: File exists
RTNETLINK answers: File exists
net.ipv4.ip_forward = 1
apyy@localhost:~$ sudo ip netns exec office ping -c 2 10.20.0.1
PING 10.20.0.1 (10.20.0.1) 56(84) bytes of data.
64 bytes from 10.20.0.1: icmp_seq=1 ttl=64 time=0.094 ms
64 bytes from 10.20.0.1: icmp_seq=2 ttl=64 time=0.042 ms

--- 10.20.0.1 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1011ms
rtt min/avg/max/mdev = 0.042/0.068/0.094/0.026 ms
apyy@localhost:~$ sudo ip netns exec guest ping -c 2 10.30.0.1
PING 10.30.0.1 (10.30.0.1) 56(84) bytes of data.
64 bytes from 10.30.0.1: icmp_seq=1 ttl=64 time=0.148 ms
64 bytes from 10.30.0.1: icmp_seq=2 ttl=64 time=0.097 ms

--- 10.30.0.1 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1028ms
rtt min/avg/max/mdev = 0.097/0.122/0.148/0.025 ms
apyy@localhost:~$ sudo ip netns exec dmz ping -c 2 10.40.0.1
PING 10.40.0.1 (10.40.0.1) 56(84) bytes of data.
64 bytes from 10.40.0.1: icmp_seq=1 ttl=64 time=0.184 ms
64 bytes from 10.40.0.1: icmp_seq=2 ttl=64 time=0.037 ms

--- 10.40.0.1 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1016ms
rtt min/avg/max/mdev = 0.037/0.110/0.184/0.073 ms
apyy@localhost:~$ sudo ip netns exec internet ping -c 2 203.0.113.1
PING 203.0.113.1 (203.0.113.1) 56(84) bytes of data.
64 bytes from 203.0.113.1: icmp_seq=1 ttl=64 time=0.106 ms
64 bytes from 203.0.113.1: icmp_seq=2 ttl=64 time=0.042 ms

--- 203.0.113.1 ping statistics ---
2 packets transmitted, 2 received, 0% packet loss, time 1011ms
rtt min/avg/max/mdev = 0.042/0.074/0.106/0.032 ms
apyy@localhost:~$