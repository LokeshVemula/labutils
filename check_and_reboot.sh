#!/bin/bash

# Script: check_and_reboot.sh
# Description: Interactively check if a system is reachable and SSH-accessible (expects password prompt). If not, perform hard reboot via IPMI.

# Function to check if command is installed
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "Error: $1 is not installed. Please install it (e.g., sudo apt install $2)."
        exit 1
    fi
}

# Check required commands
check_command ping iputils-ping
check_command expect expect
check_command ipmitool ipmitool

# Interactive prompts
read -p "Enter hostname or IP of the target system: " TARGET_HOST
read -p "Enter IPMI IP of the target system: " IPMI_IP
read -p "Enter IPMI username: " IPMI_USER
read -s -p "Enter IPMI password: " IPMI_PASS
echo

# Step 1: Check if the system is reachable via ping
echo "Step 1: Pinging $TARGET_HOST..."
if ping -c 4 "$TARGET_HOST" > /dev/null 2>&1; then
    echo "Ping successful: System is reachable."
else
    echo "Ping failed: System is not reachable. Proceeding to IPMI reboot."
    REBOOT_NEEDED=true
fi

# Step 2: Check SSH accessibility (expect password prompt without logging in)
if [ -z "$REBOOT_NEEDED" ]; then
    echo "Step 2: Checking SSH accessibility on $TARGET_HOST..."
    expect_output=$(expect -c "
        set timeout 10
        spawn ssh $TARGET_HOST
        expect {
            \"password:\" { send_user \"Password prompt received: System is accessible.\n\"; exit 0 }
            timeout { send_user \"Timeout: No password prompt. System may be hung.\n\"; exit 1 }
            eof { send_user \"Connection closed unexpectedly.\n\"; exit 1 }
        }
    ")

    if [ $? -eq 0 ]; then
        echo "SSH check successful: Password prompt received."
        exit 0  # System is fine, no reboot needed
    else
        echo "SSH check failed: No password prompt. Proceeding to IPMI reboot."
        REBOOT_NEEDED=true
    fi
fi

# Step 3: Perform hard reboot via IPMI if needed
if [ "$REBOOT_NEEDED" = true ]; then
    echo "Step 3: Performing hard reboot via IPMI on $IPMI_IP..."
    ipmitool -H "$IPMI_IP" -U "$IPMI_USER" -P "$IPMI_PASS" chassis power cycle

    if [ $? -eq 0 ]; then
        echo "IPMI reboot command sent successfully."
    else
        echo "Error: IPMI reboot failed. Check credentials or IPMI configuration."
    fi
fi
