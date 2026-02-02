System Hung recovery using IPMI and Smart PDU provided the PDUs are configured with the outlet names with the hostnames. Following are the guidelines to make use of this script.

The Script: system_hung_recovery.sh ****# Description: Interactively check if a system is reachable and SSH-accessible (expects password prompt). If not, perform hard reboot via IPMI. If IPMI is not resonging will reach out to the backend smart PDU outlet to stop and start it, to use this script, one should have these inputs: Target system name/IP, IPMI details with credentials and smart PDU details(Should be enabled with SSH) where the system is connected and outlet is labelled with the proper name, which can be given as one of the input).

How to use or download: Use this to download or get the script:  wget https://raw.githubusercontent.com/LokeshVemula/labutils/main/tools/hung-recovery/system-hung-recovery.sh -O system-hung-recovery.sh
chmod +x system-hung-recovery.sh 
./system-hung-recovery.sh****
