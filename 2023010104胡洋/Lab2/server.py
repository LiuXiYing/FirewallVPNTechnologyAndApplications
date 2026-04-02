import socket
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('0.0.0.0', 8080))
server.listen(1)
print('服务器启动，等待连接...')

conn, addr = server.accept()
print(f'连接来自：{addr}')
print(f'描述符编号 — server: {server.fileno()}, conn: {conn.fileno()}')

data = conn.recv(1024)
print(f'收到：{data.decode()}')
conn.send('已收到，你好客户端'.encode())

conn.close()
server.close()