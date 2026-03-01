collect_amd_gpus_paraniko.py is useful when you have massive number of systems and you want to collect the AMD GPUs available on each of these systems(Linux). Following are the guidelines to make use of this python script.

Prerequisites: Python(preferably python3) and paramiko should be installed on the system where this script is being run
you may use following to install paramiko
pip install paramiko

You should have the login credentails which should be same across all the systems as the script is run against all systems using the same credentials.

The Script: collect_amd_gpus_paraniko.py ****# Description: Repeatedly checks the list of servers given for all AMD GPUs in them and prepares an inventory file with all the records.

#How to use or download:

#Have all the systems in a file called hosts.txt

#Use this to download or get the script: wget https://raw.githubusercontent.com/LokeshVemula/labutils/main/tools/collect_amd_gpu_inventory/collect_amd_gpus_paraniko.py -O ssh_which_cred_works.sh

#Run the following to make the downloaded script to executable

chmod +x collect_amd_gpus_paraniko.py

Now run the script and give your inputs as it prompts for the password: 
python3 ./collect_amd_gpus_paraniko.py -u <user_name> ****
