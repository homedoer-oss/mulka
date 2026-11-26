"""Phase 0 throwaway gateway: proves that -http-proxy / -dns-server route all guest traffic through
host loopback endpoints of instance N (ADR-0004). Not the real Net Gateway (that is gateway/, Rust).

  HTTP proxy  127.0.0.1:(18080+N)  CONNECT tunnels + absolute-URI plain HTTP, logs every target
  DNS         127.0.1.(N+1):53     UDP forwarder to --upstream, logs every query name

  --upstream-proxy http://[user:pass@]host:port  chains every TCP connection through that HTTP proxy
                                                (CONNECT), so the guest's egress IP is the proxy's

usage: python -I poc-gateway.py [--instance N] [--upstream 1.1.1.1] [--upstream-proxy URL]
"""
import argparse
import base64
import datetime
import select
import socket
import struct
import threading
from urllib.parse import unquote, urlsplit

UPSTREAM_PROXY = None  # (host, port, Proxy-Authorization value or None)


def log(kind, msg):
    print(f"{datetime.datetime.now():%H:%M:%S} [{kind}] {msg}", flush=True)


def pipe(a, b):
    socks = [a, b]
    try:
        while True:
            r, _, x = select.select(socks, [], socks, 300)
            if x or not r:
                return
            for s in r:
                data = s.recv(65536)
                if not data:
                    return
                (b if s is a else a).sendall(data)
    except OSError:
        return
    finally:
        a.close()
        b.close()


def read_head(conn):
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = conn.recv(4096)
        if not chunk:
            return None, b""
        buf += chunk
        if len(buf) > 65536:
            return None, b""
    head, rest = buf.split(b"\r\n\r\n", 1)
    return head.decode("latin-1"), rest


def open_upstream(host, port):
    """TCP connection to host:port - directly, or as a CONNECT tunnel through UPSTREAM_PROXY."""
    if not UPSTREAM_PROXY:
        return socket.create_connection((host, port), timeout=15)
    phost, pport, auth = UPSTREAM_PROXY
    up = socket.create_connection((phost, pport), timeout=15)
    target = f"[{host}]:{port}" if ":" in host else f"{host}:{port}"
    req = f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n"
    if auth:
        req += f"Proxy-Authorization: {auth}\r\n"
    up.sendall((req + "\r\n").encode("latin-1"))
    head, rest = read_head(up)
    status = head.split("\r\n", 1)[0] if head else "no response"
    if head is None or status.split(" ")[1:2] != ["200"] or rest:
        up.close()
        raise OSError(f"upstream proxy refused {target}: {status}")
    return up


def handle_http(conn, peer):
    try:
        head, rest = read_head(conn)
        if head is None:
            conn.close()
            return
        lines = head.split("\r\n")
        method, target, version = lines[0].split(" ", 2)
        if method == "CONNECT":
            host, port = target.rsplit(":", 1)
            log("http", f"CONNECT {host}:{port} from {peer[0]}:{peer[1]}")
            up = open_upstream(host.strip("[]"), int(port))
            conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            if rest:
                up.sendall(rest)
        else:
            u = urlsplit(target)
            host, port = u.hostname, u.port or 80
            log("http", f"{method} {target} from {peer[0]}:{peer[1]}")
            path = (u.path or "/") + (f"?{u.query}" if u.query else "")
            fwd = [f"{method} {path} {version}"] + [
                l for l in lines[1:] if not l.lower().startswith(("proxy-connection:", "proxy-authorization:"))
            ]
            up = open_upstream(host, port)
            up.sendall(("\r\n".join(fwd) + "\r\n\r\n").encode("latin-1") + rest)
        up.settimeout(None)
        conn.settimeout(None)
        pipe(conn, up)
    except Exception as e:  # noqa: BLE001 - test tool, keep serving
        log("http", f"error from {peer}: {e!r}")
        conn.close()


def serve_http(addr):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
    srv.bind(addr)
    srv.listen(64)
    log("http", f"listening on {addr[0]}:{addr[1]}")
    while True:
        c, peer = srv.accept()
        threading.Thread(target=handle_http, args=(c, peer), daemon=True).start()


def qname(packet):
    i, labels = 12, []
    while i < len(packet) and packet[i]:
        n = packet[i]
        labels.append(packet[i + 1:i + 1 + n].decode("ascii", "replace"))
        i += 1 + n
    qtype = struct.unpack(">H", packet[i + 1:i + 3])[0] if i + 3 <= len(packet) else 0
    return ".".join(labels), {1: "A", 28: "AAAA", 5: "CNAME", 65: "HTTPS", 12: "PTR"}.get(qtype, str(qtype))


def serve_dns(addr, upstream):
    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.bind(addr)
    log("dns", f"listening on {addr[0]}:{addr[1]}, upstream {upstream}")

    def answer(data, peer):
        name, t = qname(data)
        try:
            up = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            up.settimeout(5)
            up.sendto(data, (upstream, 53))
            resp, _ = up.recvfrom(4096)
            srv.sendto(resp, peer)
            log("dns", f"{t} {name} from {peer[0]}:{peer[1]} -> {len(resp)} bytes")
        except OSError as e:
            log("dns", f"{t} {name} from {peer[0]}:{peer[1]} -> upstream error {e!r}")

    while True:
        data, peer = srv.recvfrom(4096)
        threading.Thread(target=answer, args=(data, peer), daemon=True).start()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--instance", type=int, default=0)
    ap.add_argument("--upstream", default="1.1.1.1")
    ap.add_argument("--upstream-proxy", help="http://[user:pass@]host:port")
    a = ap.parse_args()
    global UPSTREAM_PROXY
    if a.upstream_proxy:
        u = urlsplit(a.upstream_proxy)
        if u.scheme != "http" or not u.hostname or not u.port:
            ap.error("--upstream-proxy must be http://[user:pass@]host:port")
        auth = None
        if u.username is not None:
            cred = f"{unquote(u.username)}:{unquote(u.password or '')}".encode()
            auth = "Basic " + base64.b64encode(cred).decode("ascii")
        UPSTREAM_PROXY = (u.hostname, u.port, auth)
        log("http", f"upstream proxy {u.hostname}:{u.port}" + (" with auth" if auth else ""))
    threading.Thread(target=serve_dns, args=((f"127.0.1.{a.instance + 1}", 53), a.upstream), daemon=True).start()
    serve_http(("127.0.0.1", 18080 + a.instance))


if __name__ == "__main__":
    main()
