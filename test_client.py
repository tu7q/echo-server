import socket
import time

clientsocket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
clientsocket.connect(("localhost", 5882))
time.sleep(0.5)

while True:
    msg = input()

    clientsocket.send(msg.encode("utf-8"))
    print(f"recv: {clientsocket.recv(1024).decode("utf-8")}")

clientsocket.close()
