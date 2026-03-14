#!/bin/bash

echo "================================="
echo " SOM WEB HACKING LAB INSTALLER"
echo "================================="

sleep 1

echo "[+] Checking Docker installation..."

if ! command -v docker &> /dev/null
then
    echo "[-] Docker not found. Installing Docker..."

    sudo apt update
    sudo apt install -y docker.io docker-compose

    sudo systemctl enable docker
    sudo systemctl start docker
else
    echo "[✓] Docker already installed"
fi

echo "[+] Deploying lab environment..."

docker compose up -d

echo ""
echo "Lab Ready!"
echo ""
echo "Targets:"
echo "DVWA       http://localhost:8081"
echo "JuiceShop  http://localhost:3000"
echo ""
echo "Internal Network: 10.10.10.0/24"
echo ""
