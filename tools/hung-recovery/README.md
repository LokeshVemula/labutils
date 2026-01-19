System Hung recovery using IPMI and Smart PDU provided the PDUs are configured with the outlet names with the hostnames. Following are the guidelines to make use of this script.

The Script: system_hung_recovery.sh ****# Description: Interactively check if a system is reachable and SSH-accessible (expects password prompt). If not, perform hard reboot via IPMI. If IPMI is not resonging will reach out to the backend PDU outlet to stop and start it

How to use or download: Use this to download or get the script: wget https://raw.githubusercontent.com/LokeshVemula/labutils/main/tools/hung-recovery/system_hung_recivery.sh -O system_hung_recivery.sh chmod +x system_hung_recivery.sh ./system_hung_recivery.sh****
