# labadmintasks-woeusb
To make bootable windows USB using iso files on Ubuntu systems
# WoeUSB Installer for Ubuntu/Debian

This repository provides a simple script to install **WoeUSB** on Ubuntu or Debian-based systems.

## 📋 Prerequisites
- Ubuntu/Debian system
- `sudo` privileges

## 🚀 Installation

Clone the repository:
```bash
git clone https://github.com/lokeshvemula/labutils/tools/woeusb.git

cd labadmin-woeusb/

chmod +x ./install-woeusb.sh

./install-woeusb.sh

**USB preparation step assuming USB as /dev/sdc:
sudo woeusb --device ./en-us_windows_server_2022_updated_nov_2022_x64_dvd_8d436d40.iso /dev/sdc

