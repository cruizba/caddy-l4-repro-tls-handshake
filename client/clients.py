"""Opens TLS connections to Caddy that never finish the handshake, plus one that
does, and reports how long Caddy keeps each one.

- no-clienthello: connects and sends nothing.
- partial-clienthello: sends the 5-byte header of a handshake record, nothing else.
- stall-after-clienthello: sends a complete ClientHello, then never answers.
- complete-handshake: completes the handshake and stays quiet (control).

Each client waits up to HOLD seconds for Caddy to close the connection.
"""
import os
import socket
import ssl
import threading
import time

HOST = os.environ.get("TARGET_HOST", "caddy")
PORT = int(os.environ.get("TARGET_PORT", "8443"))
HOLD = float(os.environ.get("HOLD", "30"))


def client_hello() -> bytes:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
    tls = ctx.wrap_bio(incoming, outgoing, server_hostname="localhost")
    try:
        tls.do_handshake()
    except ssl.SSLWantReadError:
        pass
    return outgoing.read()


def wait_for_close(sock: socket.socket) -> str:
    sock.settimeout(HOLD)
    try:
        while sock.recv(4096):
            pass
        return "closed by Caddy"
    except socket.timeout:
        return "STILL OPEN"
    except OSError as e:
        return f"closed by Caddy ({e.__class__.__name__})"


def run(name: str, send) -> None:
    start = time.monotonic()
    sock = socket.create_connection((HOST, PORT))
    send(sock)
    outcome = wait_for_close(sock)
    sock.close()
    print(f"{time.strftime('%T')} {name:<24} {outcome} after {time.monotonic() - start:4.1f}s", flush=True)


def complete_and_wait() -> None:
    """Completes the handshake and stays quiet: the echo handler keeps it open,
    whatever handshake_timeout says, since that only bounds the handshake."""
    start = time.monotonic()
    sock = socket.create_connection((HOST, PORT))
    tls = ssl.create_default_context()
    tls.check_hostname = False
    tls.verify_mode = ssl.CERT_NONE
    conn = tls.wrap_socket(sock, server_hostname="localhost")
    conn.settimeout(HOLD)
    try:
        outcome = "closed by Caddy" if conn.recv(4096) == b"" else "data"
    except socket.timeout:
        outcome = "STILL OPEN"
    except (OSError, ssl.SSLError) as e:
        outcome = f"closed by Caddy ({e.__class__.__name__})"
    conn.close()
    print(f"{time.strftime('%T')} {'complete-handshake':<24} {outcome} after {time.monotonic() - start:4.1f}s", flush=True)


hello = client_hello()
print(f"{time.strftime('%T')} clients: connecting to {HOST}:{PORT}, waiting up to {HOLD:.0f}s each", flush=True)
threads = [
    threading.Thread(target=run, args=("no-clienthello", lambda s: None)),
    threading.Thread(target=run, args=("partial-clienthello", lambda s: s.sendall(b"\x16\x03\x01\x02\x00"))),
    threading.Thread(target=run, args=("stall-after-clienthello", lambda s: s.sendall(hello))),
    threading.Thread(target=complete_and_wait),
]
for t in threads:
    t.start()
for t in threads:
    t.join()
