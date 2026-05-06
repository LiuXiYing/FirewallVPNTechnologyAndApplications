#!/usr/bin/env python3
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


# 允许通过环境变量改监听地址和端口，便于端口冲突时快速切换。
HOST = os.environ.get("LAB6_HOST", "127.0.0.1")
PORT = int(os.environ.get("LAB6_PORT", "38060"))


def now():
    # 只用于终端输出，方便学生对照客户端运行时间。
    return time.strftime("%H:%M:%S")


class Lab6Handler(BaseHTTPRequestHandler):
    # 明确使用 HTTP/1.1，响应里会配合 Content-Length 和 Connection。
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        # 返回简单文本即可；本实验关注防火墙是否放行，不关注网页内容。
        body = (
            "lab6 firewall server ok\n"
            f"path={self.path}\n"
            f"time={now()}\n"
        ).encode("utf-8")

        # 打印客户端源地址和源端口，用来判断请求是否真的到达服务端。
        print(
            f"[{now()}] request from {self.client_address[0]}:"
            f"{self.client_address[1]} {self.command} {self.path}",
            flush=True,
        )

        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        # HTTP/1.1 下写明长度，客户端就能判断响应体何时接收完整。
        self.send_header("Content-Length", str(len(body)))
        # 每次请求后关闭连接，让实验输出更简单稳定。
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        # 关闭 BaseHTTPRequestHandler 默认日志，避免干扰实验观察。
        return


def main():
    # ThreadingHTTPServer 可以同时处理多个连接；本实验通常只会有一个客户端。
    server = ThreadingHTTPServer((HOST, PORT), Lab6Handler)
    print(f"lab6 firewall server listening on {HOST}:{PORT}", flush=True)
    print("press Ctrl+C to stop", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nserver stopped", flush=True)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
