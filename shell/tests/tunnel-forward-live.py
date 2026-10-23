#!/usr/bin/env python3
"""TCP/UDP payload checks for temporary live forwarding endpoints."""

import argparse
import hashlib
import json
import secrets
import signal
import socket
import socketserver
import threading


def response(server, peer, payload):
    header = json.dumps({"server": server.label, "port": server.server_address[1],
                         "peer": peer[0]}, separators=(",", ":")).encode()
    return header + b"\n" + payload


class TCPHandler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(15)
        payload = self.rfile.readline(2 * 1024 * 1024)
        self.wfile.write(response(self.server, self.client_address, payload))


class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        payload, sock = self.request
        sock.sendto(response(self.server, self.client_address, payload), self.client_address)


class TCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def serve(args):
    servers = []
    for port in args.ports:
        for cls, handler in ((TCPServer, TCPHandler), (socketserver.ThreadingUDPServer, UDPHandler)):
            server = cls(("0.0.0.0", port), handler)
            server.label = args.label
            servers.append(server)
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    print(json.dumps({"ready": args.label, "ports": args.ports}), flush=True)
    signal.pause()


def check(args):
    for proto in args.protocols.split(","):
        size = args.tcp_bytes if proto == "tcp" else args.udp_bytes
        payload = secrets.token_hex((size + 1) // 2).encode()[:size] + b"\n"
        received = b""
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM if proto == "tcp" else socket.SOCK_DGRAM) as sock:
            sock.settimeout(10)
            sock.connect((args.host, args.port))
            sock.sendall(payload)
            if proto == "tcp":
                while True:
                    chunk = sock.recv(65536)
                    if not chunk:
                        break
                    received += chunk
            else:
                received = sock.recv(65536)
        header, echoed = received.split(b"\n", 1)
        metadata = json.loads(header)
        assert echoed == payload, "payload mismatch"
        assert metadata["server"] == args.server, metadata
        assert metadata["port"] == (args.target_port or args.port), metadata
        if args.peer:
            assert metadata["peer"] == args.peer, metadata
        print(json.dumps({"pass": True, "proto": proto, "host": args.host, "entry_port": args.port,
                          "bytes": len(echoed), "sha256": hashlib.sha256(echoed).hexdigest(),
                          **metadata}, sort_keys=True), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    server = sub.add_parser("serve")
    server.add_argument("--label", required=True)
    server.add_argument("--ports", type=lambda value: [int(p) for p in value.split(",")], required=True)
    client = sub.add_parser("check")
    client.add_argument("--host", required=True)
    client.add_argument("--port", type=int, required=True)
    client.add_argument("--server", required=True)
    client.add_argument("--target-port", type=int)
    client.add_argument("--peer")
    client.add_argument("--protocols", choices=("tcp", "udp", "tcp,udp"), default="tcp,udp")
    client.add_argument("--tcp-bytes", type=int, default=262144)
    client.add_argument("--udp-bytes", type=int, default=1200)
    args = parser.parse_args()
    (serve if args.command == "serve" else check)(args)


if __name__ == "__main__":
    main()
