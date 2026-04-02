import socket
import threading

SERVER_IP = '8.137.86.107'
PORT = 31318
NAME = '胡洋'

client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
client.connect((SERVER_IP, PORT))
client.send(NAME.encode())

def receive():
    while True:
        try:
            msg = client.recv(1024).decode()
            print(msg)
        except:
            break

threading.Thread(target=receive, daemon=True).start()

while True:
    msg = input()
    if msg:
        client.send(msg.encode())