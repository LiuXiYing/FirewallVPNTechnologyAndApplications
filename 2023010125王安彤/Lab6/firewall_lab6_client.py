#!/usr/bin/env python3
import os
import socket
import time


# 这些环境变量和 Lab6.md 中的命令保持一致。
HOST = os.environ.get("LAB6_HOST", "127.0.0.1")
PORT = int(os.environ.get("LAB6_PORT", "38060"))
TIMEOUT = float(os.environ.get("LAB6_TIMEOUT", "3"))


def main():
    target = (HOST, PORT)
    # 构造最小 HTTP GET 请求；ts 参数让每次请求路径略有不同，便于观察。
    request = (
        f"GET /lab6?ts={int(time.time())} HTTP/1.1\r\n"
        f"Host: {HOST}:{PORT}\r\n"
        "User-Agent: firewall-lab6-client/1.0\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode("ascii")

    print(f"target = http://{HOST}:{PORT}/")
    print(f"timeout = {TIMEOUT:.1f}s")
    print("creating socket")

    start = time.perf_counter()
    # AF_INET 表示 IPv4，SOCK_STREAM 表示 TCP。
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    # 超时时间用于观察 DROP：包被丢弃时，客户端会等待到超时。
    sock.settimeout(TIMEOUT)

    try:
        print("calling connect()")
        # connect() 会发起 TCP 连接；如果被 REJECT/DROP，失败现象会不同。
        sock.connect(target)
        connected_at = time.perf_counter()
        print(f"connect() returned after {connected_at - start:.3f}s")
        # 本地临时端口由操作系统自动分配，报告里需要记录。
        print(f"local socket = {sock.getsockname()[0]}:{sock.getsockname()[1]}")

        print(f"sending HTTP request, bytes={len(request)}")
        sock.sendall(request)

        chunks = []
        while True:
            # recv() 返回空字节串表示对端已经关闭连接。
            data = sock.recv(4096)
            if not data:
                break
            chunks.append(data)

        elapsed = time.perf_counter() - start
        response = b"".join(chunks)
        # 响应首行通常类似 HTTP/1.1 200 OK，用来判断请求是否成功。
        first_line = response.splitlines()[0].decode("iso-8859-1") if response else ""
        print(f"response bytes = {len(response)}")
        print(f"response status = {first_line}")
        print(f"request succeeded after {elapsed:.3f}s")
    except socket.timeout:
        elapsed = time.perf_counter() - start
        print(f"request failed: timeout after {elapsed:.3f}s")
    except OSError as exc:
        elapsed = time.perf_counter() - start
        print(f"request failed: {exc} after {elapsed:.3f}s")
    finally:
        sock.close()


if __name__ == "__main__":
    main()
