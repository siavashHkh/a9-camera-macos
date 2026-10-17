#!/usr/bin/env python3
"""Optional GUI fixture: synthetic blue JPEG frames on localhost, no physical camera."""
import json
from pathlib import Path
import socket
import struct
import sys
import time

frame = Path(sys.argv[1] if len(sys.argv) > 1 else "build/TestFrame.jpg").read_bytes()

def packet(command, payload=b"", modern=False):
    return struct.pack("<II", len(payload), command) + (bytes(12) if modern else b"00000000" + bytes(4)) + payload

with socket.socket() as server:
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 6123))
    server.listen(1)
    print("SYNTHETIC GUI FIXTURE: listening only on 127.0.0.1:6123", flush=True)
    while True:
        connection, _ = server.accept()
        with connection:
            buffer = b""
            streaming = False
            modern = None
            connection.settimeout(0.2)
            try:
                while True:
                    try:
                        data = connection.recv(65536)
                        if not data:
                            break
                        buffer += data
                    except socket.timeout:
                        pass
                    while len(buffer) >= 20:
                        length, command = struct.unpack("<II", buffer[:8])
                        if length > 4 * 1024 * 1024:
                            raise ValueError("oversized client packet")
                        if len(buffer) < 20 + length:
                            break
                        payload = buffer[20:20 + length]
                        buffer = buffer[20 + length:]
                        if modern is None:
                            modern = command == 8
                        if command == 115 and not modern:
                            connection.sendall(packet(115))
                        elif command in (0, 8):
                            request = json.loads(payload)
                            code = request["code"]
                            if modern:
                                if code in (115, 214):
                                    reply = json.dumps({"code": code}).encode()
                                    connection.sendall(packet(8, reply, True))
                                elif code == 213:
                                    streaming = True
                            elif code == 501:
                                connection.sendall(packet(0, b'{"code":501}'))
                            elif code == 502:
                                if request["content"]["code"] == 4:
                                    connection.sendall(packet(0, b'{"code":502,"content":{"code":4}}'))
                                elif request["content"]["code"] == 2:
                                    streaming = True
                    if streaming:
                        connection.sendall(packet(1003 if modern else 0x00010001, frame, modern))
                        time.sleep(0.2)
            except (BrokenPipeError, ConnectionResetError):
                pass
        print("GUI fixture disconnected; ready for another test", flush=True)
