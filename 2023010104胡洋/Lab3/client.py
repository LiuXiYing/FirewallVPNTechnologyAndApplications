import socket

# 阶段1：创建套接字
client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)

# 阶段2：连接服务器
client.connect(('127.0.0.1', 8080))

# 阶段3：发送数据
client.send('你好，服务器'.encode())

# 阶段3：接收响应（这里会阻塞，直到收到服务器数据）
data = client.recv(1024)
print('收到：', data.decode())

# 阶段4：断开
client.close()