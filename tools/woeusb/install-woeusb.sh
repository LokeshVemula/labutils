#!/bin/bash
set -e

echo "📦 Updating packages and installing prerequisites..."
sudo apt update -y
sudo apt install -y git p7zip-full wget software-properties-common

echo "➕ Adding WoeUSB PPA..."
sudo add-apt-repository -y ppa:tomtomtom/woeusb

echo "📦 Installing WoeUSB..."
sudo apt update -y
sudo apt install -y woeusb woeusb-frontend-wxgtk

echo "✅ WoeUSB installation complete!"
