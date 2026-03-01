ssh-credential-tester is useful when you have massive number of systems and you have lot of logins created and you are not able to figure out which logins are created to which system(Linux). Following are the guidelines to make use of this script.

The Script: ssh_which_cred_works.sh ****# Description: Repeatedly checks the logins provided in master credentials file and will share the consolidated list with the successful logins to each of the system.

#How to use or download:
# Updated all login credentials available with each line as shown below into a file, say credentials.txt
#login1:password1
#login2:password2

#Have all the systems in a file, say systems.txt

#Use this to download or get the script:
wget https://raw.githubusercontent.com/LokeshVemula/labutils/main/tools/ssh-credential-tester/ssh_which_cred_works.sh -O ssh_which_cred_works.sh

#Run the following to make the downloaded script to executable

chmod +x ssh_which_cred_works.sh

Now run the script and give your inputs: system, IPMI details and PDU details
./ssh_which_cred_works.sh systems.txt crednetials.txt****
