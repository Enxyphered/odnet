#!/bin/bash
set -e
echo "Building odnetclient for Linux (epoll Multi-Reactor Engine)..."
odin build odnetclient -out:odnetclient -target:linux_amd64 -o:speed
echo "[SUCCESS] Linux executable built: odnetclient"
