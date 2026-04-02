import socket

SERVER_IP = '8.137.86.107'   # 从黑板上抄
PORT = 31317

client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
client.connect((SERVER_IP, PORT))

# 发送自己的名字
client.send('我是胡洋'.encode())

# 接收服务器回应
data = client.recv(1024)
print('服务器说：', data.decode())

client.close()

import socket

# 阶段 1：创建套接字
client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)

# 阶段 2：连接服务器
client.connect(('127.0.0.1', 8888))

# 阶段 3：发送数据
client.send('你好，服务器'.encode())

# 阶段 3：接收响应
data = client.recv(1024)
print('收到：', data.decode())

# 阶段 4：断开
client.close()