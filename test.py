import socket
import time

clientsocket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
clientsocket.connect(("localhost", 5882))
time.sleep(0.5)

while True:
    msg = input()
    clientsocket.send(bytes(ascii(msg), encoding="ascii"))
    print(f"recv: {clientsocket.recv(len(msg)).decode("ascii")}")

clientsocket.close()
