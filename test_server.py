#!/usr/bin/env python3
"""Minimal microkernel mock — listens on Unix socket, echoes messages back."""
import socket, struct, os, time

SOCK_PATH = "/tmp/mios-test.sock"
WIRE_HEADER = struct.Struct("<QQIII")  # source(8), dest(8), type(4), payload_size(4), reserved(4)

# Clean up stale socket
if os.path.exists(SOCK_PATH):
    os.unlink(SOCK_PATH)

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(SOCK_PATH)
srv.listen(1)
print(f"Listening on {SOCK_PATH}")

while True:
    conn, _ = srv.accept()
    print("Client connected!")

    # Send a welcome message to the client
    welcome = b"Hello from microkernel!"
    hdr = WIRE_HEADER.pack(
        1,           # source: actor 1 (the "kernel")
        0,           # dest: client
        0xFF000060,  # MSG_CONSOLE_WRITE
        len(welcome),
        0
    )
    conn.sendall(hdr + welcome)
    print(f"Sent welcome: {welcome}")

    try:
        while True:
            # Read header
            data = b""
            while len(data) < 28:
                chunk = conn.recv(28 - len(data))
                if not chunk:
                    raise ConnectionError("closed")
                data += chunk

            source, dest, msg_type, payload_size, _ = WIRE_HEADER.unpack(data)
            payload = b""
            if payload_size > 0:
                while len(payload) < payload_size:
                    chunk = conn.recv(payload_size - len(payload))
                    if not chunk:
                        raise ConnectionError("closed")
                    payload += chunk

            print(f"Recv: type=0x{msg_type:08X} payload={payload!r}")

            # Echo back with modified type (response = type + 1)
            response = f"Echo: {payload.decode('utf-8', errors='replace')}".encode()
            resp_hdr = WIRE_HEADER.pack(1, source, msg_type + 1, len(response), 0)
            conn.sendall(resp_hdr + response)
            print(f"Sent response: {response}")

    except (ConnectionError, BrokenPipeError):
        print("Client disconnected")
        conn.close()
