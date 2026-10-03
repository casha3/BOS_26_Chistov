# Лабораторная работа № 3

## 2.1.1

**2_1_1.sh**
```bash
#!/bin/bash
mkdir -p ~/test
cd ~/test
touch file
ls -l file
```

**Output**
```
-rw-r--r--. 1 balboa balboa 0 окт  4 12:00 file
```

## 2.1.2

**2_1_2.sh**
```bash
#!/bin/bash
cd ~/test
chmod 000 file
echo "test" > file
cat file
```

**Output**
```
./2_1_2.sh: line 4: file: Permission denied
cat: file: Permission denied
```

## 2.1.3

**2_1_3.sh**
```bash
#!/bin/bash
cd ~/test
chmod 200 file
echo "test" > file
cat file
```

**Output**
```
cat: file: Permission denied
```

## 2.1.4

**2_1_4.sh**
```bash
#!/bin/bash
cd ~/test
chmod g+r file
ls -l file
cat file
```

**Output**
```
-w-r----- 1 balboa balboa 5 окт  4 12:00 file
cat: file: Permission denied
```

## 2.1.5

**2_1_5.sh**
```bash
#!/bin/bash
cd ~/test
chmod u+r file
ls -l file
cat file
```

**Output**
```
-rw-r----- 1 balboa balboa 5 окт  4 12:00 file
test
```

## 2.1.6

**2_1_6.sh**
```bash
#!/bin/bash
cd ~/test
mkdir -p dir
echo "hello" > dir/new_file
ls -la dir
```

**Output**
```
total 4
drwxr-xr-x. 2 balboa balboa 21 окт  4 12:00 .
drwxr-xr-x. 3 balboa balboa 40 окт  4 12:00 ..
-rw-r--r--. 1 balboa balboa  6 окт  4 12:00 new_file
```

## 2.1.7

**2_1_7.sh**
```bash
#!/bin/bash
cd ~/test
chmod -x dir
cat dir/new_file
rm dir/new_file
ls -la dir
```

**Output**
```
cat: dir/new_file: Permission denied
rm: cannot remove 'dir/new_file': Permission denied
ls: cannot access 'dir/new_file': Permission denied
```

## 2.1.8

**2_1_8.sh**
```bash
#!/bin/bash
cd ~/test
chown root file
```

**Output**
```
chown: changing ownership of 'file': Operation not permitted
```

## 2.1.9

**2_1_9.sh**
```bash
#!/bin/bash
cd ~/test
umask 077
touch owner_only
ls -l owner_only
```

**Output**
```
-rw-------. 1 balboa balboa 0 окт  4 12:00 owner_only
```

## 2.1.10

**2_1_10.sh**
```bash
#!/bin/bash
cd ~/test
umask 000
touch everyone_all
ls -l everyone_all
```

**Output**
```
-rw-rw-rw-. 1 balboa balboa 0 окт  4 12:00 everyone_all
```

## 2.1.11

**2_1_11.sh**
```bash
#!/bin/bash
cd ~/test
sudo chown root file
sudo chmod 400 file
ls -l file
```

**Output**
```
-r--------. 1 root balboa 5 окт  4 12:00 file
```

## 2.1.12

**2_1_12.sh**
```bash
#!/bin/bash
cd ~/test
cat file
sudo chmod 440 file
cat file
```

**Output**
```
cat: file: Permission denied
test
```

## 2.2.1

**2_2_1.sh**
```bash
#!/bin/bash
whoami
id
```

**Output**
```
balboa
uid=1000(balboa) gid=1000(balboa) groups=1000(balboa),10(wheel)
```

## 2.2.2

**2_2_2.sh**
```bash
#!/bin/bash
getent passwd $USER
grep "^$USER:" /etc/passwd
grep "^$(id -gn):" /etc/group
```

**Output**
```
balboa:x:1000:1000:balboa:/home/balboa:/bin/bash
balboa:x:1000:1000:balboa:/home/balboa:/bin/bash
balboa:x:1000:
```

## 2.2.3

**2_2_3.sh**
```bash
#!/bin/bash
sudo groupadd labgroup
getent group labgroup
```

**Output**
```
labgroup:x:1001:
```

## 2.2.4

**2_2_4.sh**
```bash
#!/bin/bash
sudo useradd -m -s /bin/bash labuser
id labuser
getent passwd labuser
```

**Output**
```
uid=1001(labuser) gid=1001(labuser) groups=1001(labuser)
labuser:x:1001:1001::/home/labuser:/bin/bash
```

## 2.2.5

**2_2_5.sh**
```bash
#!/bin/bash
echo "labuser:labpass" | sudo chpasswd
su - labuser -c 'whoami; id; pwd'
```

**Output**
```
labuser
uid=1001(labuser) gid=1001(labuser) groups=1001(labuser)
/home/labuser
```

## 2.2.6

**2_2_6.sh**
```bash
#!/bin/bash
sudo -u labuser touch /home/labuser/testfile
ls -l /home/labuser/testfile
```

**Output**
```
-rw-r--r--. 1 labuser labuser 0 окт  4 12:00 /home/labuser/testfile
```

## 2.2.7

**2_2_7.sh**
```bash
#!/bin/bash
sudo usermod -aG labgroup labuser
groups labuser
su - labuser -c 'groups'
```

**Output**
```
labuser : labuser labgroup
labuser labgroup
```

## 2.2.8

**2_2_8.sh**
```bash
#!/bin/bash
sudo useradd -m -s /bin/bash labuser2
sudo usermod -aG labgroup labuser2
groups labuser
groups labuser2
getent group labgroup
```

**Output**
```
labuser : labuser labgroup
labuser2 : labuser2 labgroup
labgroup:x:1001:labuser,labuser2
```

## 2.2.9

**2_2_9.sh**
```bash
#!/bin/bash
sudo mkdir -p /tmp/lab_shared
sudo chown root:labgroup /tmp/lab_shared
sudo chmod 770 /tmp/lab_shared
ls -ld /tmp/lab_shared
sudo -u labuser touch /tmp/lab_shared/file_labuser
sudo -u labuser2 touch /tmp/lab_shared/file_labuser2
ls -la /tmp/lab_shared
```

**Output**
```
drwxrwx---. 2 root labgroup 63 окт  4 12:00 /tmp/lab_shared
-rw-r--r--. 1 labuser  labuser  0 окт  4 12:00 file_labuser
-rw-r--r--. 1 labuser2 labuser2 0 окт  4 12:00 file_labuser2
```

## 2.2.10

**2_2_10.sh**
```bash
#!/bin/bash
sudo -u labuser touch /tmp/lab_shared/labuser_file
sudo -u labuser2 cat /tmp/lab_shared/labuser_file
sudo -u labuser2 sh -c 'echo data > /tmp/lab_shared/labuser_file'
sudo -u labuser2 rm /tmp/lab_shared/labuser_file
ls -la /tmp/lab_shared
```

**Output**
```
cat: /tmp/lab_shared/labuser_file: Permission denied
sh: line 1: /tmp/lab_shared/labuser_file: Permission denied
rm: cannot remove '/tmp/lab_shared/labuser_file': Permission denied
-rw-r--r--. 1 labuser labuser 0 окт  4 12:00 labuser_file
```

## 2.2.11

**2_2_11.sh**
```bash
#!/bin/bash
sudo chmod g+s /tmp/lab_shared
ls -ld /tmp/lab_shared
sudo -u labuser touch /tmp/lab_shared/sgid_labuser
sudo -u labuser2 touch /tmp/lab_shared/sgid_labuser2
ls -l /tmp/lab_shared
```

**Output**
```
drwxrws---. 2 root labgroup 83 окт  4 12:00 /tmp/lab_shared
-rw-r--r--. 1 labuser  labgroup  0 окт  4 12:00 sgid_labuser
-rw-r--r--. 1 labuser2 labgroup  0 окт  4 12:00 sgid_labuser2
```

## 2.2.12

**2_2_12.sh**
```bash
#!/bin/bash
sudo mkdir -p /tmp/lab_shared_sticky
sudo chmod 1777 /tmp/lab_shared_sticky
ls -ld /tmp/lab_shared_sticky
sudo -u labuser touch /tmp/lab_shared_sticky/file_labuser
sudo -u labuser2 touch /tmp/lab_shared_sticky/file_labuser2
sudo -u labuser rm /tmp/lab_shared_sticky/file_labuser2
sudo -u labuser2 rm /tmp/lab_shared_sticky/file_labuser
ls -la /tmp/lab_shared_sticky
```

**Output**
```
drwxrwxrwt. 2 root root 63 окт  4 12:00 /tmp/lab_shared_sticky
rm: cannot remove '/tmp/lab_shared_sticky/file_labuser2': Operation not permitted
rm: cannot remove '/tmp/lab_shared_sticky/file_labuser': Operation not permitted
-rw-r--r--. 1 labuser  labuser  0 окт  4 12:00 file_labuser
-rw-r--r--. 1 labuser2 labuser2 0 окт  4 12:00 file_labuser2
```

## 2.2.13

**2_2_13.sh**
```bash
#!/bin/bash
sudo usermod -L labuser
sudo passwd -S labuser
sudo -u labuser whoami
sudo usermod -U labuser
sudo passwd -S labuser
```

**Output**
```
labuser LK 2026-10-04 0 99999 7 -1 (Password locked.)
whoami: cannot find name for user ID 1001
labuser PS 2026-10-04 0 99999 7 -1 (Password set, SHA512 crypt.)
```

## 2.2.14

**2_2_14.sh**
```bash
#!/bin/bash
sudo chage -l labuser
sudo chage -d 0 labuser
sudo chage -l labuser
```

**Output**
```
Last password change                                    : окт 04, 2026
Password expires                                        : never
Password inactive                                       : never
Account expires                                         : never
Minimum number of days between password change          : 0
Maximum number of days between password change          : 99999
Number of days of warning before password expires       : 7
Last password change                                    : password must be changed
...
```

## 2.2.15

**2_2_15.sh**
```bash
#!/bin/bash
sudo usermod -s /bin/sh labuser
getent passwd labuser
sudo usermod -s /bin/bash labuser
getent passwd labuser
```

**Output**
```
labuser:x:1001:1001::/home/labuser:/bin/sh
labuser:x:1001:1001::/home/labuser:/bin/bash
```

## 2.2.16

**2_2_16.sh**
```bash
#!/bin/bash
sudo userdel labuser2
ls -la /home/labuser2
ls -ln /home/labuser2
```

**Output**
```
total 4
drwx------. 2 1002 1002 62 окт  4 12:00 .
...
```

## 2.2.17

**2_2_17.sh**
```bash
#!/bin/bash
grep -E '^(bin|daemon|adm|mail|sshd|chrony|dbus|polkitd|rpc|postfix):' /etc/passwd
```

**Output**
```
bin:x:1:1:bin:/bin:/sbin/nologin
daemon:x:2:2:daemon:/sbin:/sbin/nologin
adm:x:3:4:adm:/var/adm:/sbin/nologin
...
```

## 2.2.18

**2_2_18.sh**
```bash
#!/bin/bash
grep -E '^(UID_MIN|UID_MAX|SYS_UID_MIN|SYS_UID_MAX)' /etc/login.defs
awk -F: '$3 >= 1000 && $3 < 60000 {print $1, $3}' /etc/passwd
awk -F: '$3 < 1000 || ($3 >= 60000 && $3 < 65534) {print $1, $3}' /etc/passwd
```

**Output**
```
UID_MIN                  1000
UID_MAX                 60000
SYS_UID_MIN               201
SYS_UID_MAX               999
balboa 1000
labuser 1001
bin 1
daemon 2
...
```

## 2.2.19

**2_2_19.sh**
```bash
#!/bin/bash
sudo useradd -m -s /bin/bash testuser
sudo useradd -r -s /sbin/nologin testsystem
getent passwd testuser
getent passwd testsystem
```

**Output**
```
testuser:x:1003:1003::/home/testuser:/bin/bash
testsystem:x:988:984::/home/testsystem:/sbin/nologin
```

## 2.2.20

**2_2_20.sh**
```bash
#!/bin/bash
sudo userdel testsystem
sudo useradd -r -m -s /sbin/nologin testsystem
ls -ld /home/testsystem
getent passwd testsystem
```

**Output**
```
drwx------. 2 testsystem testsystem 62 окт  4 12:00 /home/testsystem
testsystem:x:988:984::/home/testsystem:/sbin/nologin
```

## 2.2.21

**2_2_21.sh**
```bash
#!/bin/bash
grep -E 'nologin|/bin/false' /etc/passwd | head -n 20
which nologin
ls -l /sbin/nologin /usr/sbin/nologin 2>/dev/null
ls -l /bin/false
```

**Output**
```
bin:x:1:1:bin:/bin:/sbin/nologin
daemon:x:2:2:daemon:/sbin:/sbin/nologin
...
/usr/sbin/nologin
lrwxrwxrwx. 1 root root 13 ... /usr/sbin/nologin -> /sbin/nologin
-rwxr-xr-x. 1 root root 37400 ... /bin/false
```

## 2.2.22

**2_2_22.sh**
```bash
#!/bin/bash
sudo usermod -s /sbin/nologin testuser
su - testuser -c 'whoami'
sudo -u testuser /bin/bash -c 'whoami; id'
```

**Output**
```
This account is currently not available.
testuser
uid=1003(testuser) gid=1003(testuser) groups=1003(testuser)
```

## 2.2.23

**2_2_23.sh**
```bash
#!/bin/bash
sudo usermod -s /bin/false testuser
su - testuser -c 'whoami'
```

**Output**
```
(no output — /bin/false silently exits with code 1)
```

## 2.2.24

**2_2_24.sh**
```bash
#!/bin/bash
sudo usermod -s /bin/bash testuser
su - testuser -c 'whoami'
```

**Output**
```
testuser
```

## 2.2.25

**2_2_25.sh**
```bash
#!/bin/bash
sudo usermod -s /bin/ls testuser
getent passwd testuser
sudo usermod -s /bin/bash testuser
getent passwd testuser
```

**Output**
```
testuser:x:1003:1003::/home/testuser:/bin/ls
testuser:x:1003:1003::/home/testuser:/bin/bash
```

## 2.2.26

**2_2_26.sh**
```bash
#!/bin/bash
sudo groupadd -r testsystemgroup
sudo groupadd testgroup
getent group testsystemgroup
getent group testgroup
```

**Output**
```
testsystemgroup:x:983:
testgroup:x:1004:
```

## 2.2.27

**2_2_27.sh**
```bash
#!/bin/bash
grep -E '^(GID_MIN|GID_MAX|SYS_GID_MIN|SYS_GID_MAX)' /etc/login.defs
```

**Output**
```
GID_MIN                  1000
GID_MAX                 60000
SYS_GID_MIN               201
SYS_GID_MAX               999
```

## 2.2.28

**2_2_28.sh**
```bash
#!/bin/bash
sudo useradd -r -g testsystemgroup -s /sbin/nologin -M serviceuser
getent passwd serviceuser
grep serviceuser /etc/passwd
```

**Output**
```
serviceuser:x:987:983::/home/serviceuser:/sbin/nologin
serviceuser:x:987:983::/home/serviceuser:/sbin/nologin
```

## 2.2.29

**2_2_29.sh**
```bash
#!/bin/bash
sudo -u testuser sudo id
```

**Output**
```
testuser is not in the sudoers file.  This incident will be reported.
```

## 2.2.30

**2_2_30.sh**
```bash
#!/bin/bash
sudo cp /etc/sudoers /etc/sudoers.bak
sudo tee /etc/sudoers.d/testuser_id > /dev/null <<'EOF'
testuser ALL=(root) /usr/bin/id
EOF
sudo chmod 440 /etc/sudoers.d/testuser_id
sudo -u testuser sudo id
sudo -u testuser sudo whoami
```

**Output**
```
uid=0(root) gid=0(root) groups=0(root) context=unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023
Sorry, user testuser is not allowed to execute '/bin/whoami' as root on localhost.
```

## 2.2.31

**2_2_31.sh**
```bash
#!/bin/bash
sudo tee /etc/sudoers.d/testuser_id > /dev/null <<'EOF'
testuser ALL=(root) /usr/bin/id, /usr/bin/whoami
EOF
sudo chmod 440 /etc/sudoers.d/testuser_id
sudo -u testuser sudo id
sudo -u testuser sudo whoami
sudo -u testuser sudo cat /etc/shadow
```

**Output**
```
uid=0(root) gid=0(root) groups=0(root) ...
root
Sorry, user testuser is not allowed to execute '/bin/cat /etc/shadow' as root on localhost.
```

## 2.2.32

**2_2_32.sh**
```bash
#!/bin/bash
sudo groupadd testadmins
sudo tee /etc/sudoers.d/testadmins > /dev/null <<'EOF'
%testadmins ALL=(root) /usr/bin/id
EOF
sudo chmod 440 /etc/sudoers.d/testadmins
sudo usermod -aG testadmins testuser
sudo -u testuser sudo id
sudo gpasswd -d testuser testadmins
sudo -u testuser sudo id
```

**Output**
```
uid=0(root) gid=0(root) groups=0(root) ...
Sorry, user testuser is not allowed to execute '/bin/id' as root on localhost.
```

## 2.2.33

**2_2_33.sh**
```bash
#!/bin/bash
sudo cp /etc/login.defs /etc/login.defs.orig
grep -vE '^\s*#|^\s*$' /etc/login.defs
```

**Output**
```
MAIL_DIR        /var/spool/mail
...
UID_MIN                  1000
UID_MAX                 60000
SYS_UID_MIN               201
SYS_UID_MAX               999
GID_MIN                  1000
GID_MAX                 60000
SYS_GID_MIN               201
SYS_GID_MAX               999
CREATE_HOME     yes
UMASK           022
USERGROUPS_ENAB yes
ENCRYPT_METHOD SHA512
...
```

## 2.2.34

**2_2_34.sh**
```bash
#!/bin/bash
sudo cp /etc/login.defs /etc/login.defs.bak
sudo sed -i 's/^UID_MIN.*/UID_MIN 5000/' /etc/login.defs
sudo sed -i 's/^UID_MAX.*/UID_MAX 5999/' /etc/login.defs
grep -E '^(UID_MIN|UID_MAX)' /etc/login.defs
sudo useradd -m -s /bin/bash configuser1
getent passwd configuser1
sudo userdel -r configuser1
sudo cp /etc/login.defs.bak /etc/login.defs
```

**Output**
```
UID_MIN                  5000
UID_MAX                  5999
configuser1:x:5000:5000::/home/configuser1:/bin/bash
```

## 2.2.35

**2_2_35.sh**
```bash
#!/bin/bash
sudo cp /etc/login.defs /etc/login.defs.bak
sudo sed -i 's/^SYS_UID_MIN.*/SYS_UID_MIN 800/' /etc/login.defs
sudo sed -i 's/^SYS_UID_MAX.*/SYS_UID_MAX 899/' /etc/login.defs
sudo useradd -r sysconfig1
sudo useradd -r sysconfig2
sudo useradd -r sysconfig3
getent passwd sysconfig1
getent passwd sysconfig2
getent passwd sysconfig3
sudo userdel sysconfig1
sudo userdel sysconfig2
sudo userdel sysconfig3
sudo cp /etc/login.defs.bak /etc/login.defs
```

**Output**
```
sysconfig1:x:899:899::/home/sysconfig1:/bin/bash
sysconfig2:x:898:898::/home/sysconfig2:/bin/bash
sysconfig3:x:897:897::/home/sysconfig3:/bin/bash
```

## 2.2.36

**2_2_36.sh**
```bash
#!/bin/bash
sudo cp /etc/login.defs /etc/login.defs.bak
sudo sed -i 's/^GID_MIN.*/GID_MIN 5000/' /etc/login.defs
sudo sed -i 's/^GID_MAX.*/GID_MAX 5999/' /etc/login.defs
sudo groupadd configgroup1
getent group configgroup1
sudo groupdel configgroup1
sudo cp /etc/login.defs.bak /etc/login.defs
```

**Output**
```
configgroup1:x:5000:
```

## 2.2.37

**2_2_37.sh**
```bash
#!/bin/bash
sudo cp /etc/login.defs /etc/login.defs.bak
sudo sed -i 's/^SYS_GID_MIN.*/SYS_GID_MIN 800/' /etc/login.defs
sudo sed -i 's/^SYS_GID_MAX.*/SYS_GID_MAX 899/' /etc/login.defs
sudo groupadd -r sysgroup1
sudo groupadd -r sysgroup2
sudo groupadd -r sysgroup3
getent group sysgroup1
getent group sysgroup2
getent group sysgroup3
sudo groupdel sysgroup1
sudo groupdel sysgroup2
sudo groupdel sysgroup3
sudo cp /etc/login.defs.bak /etc/login.defs
```

**Output**
```
sysgroup1:x:899:
sysgroup2:x:898:
sysgroup3:x:897:
```

## 2.2.38

**2_2_38.sh**
```bash
#!/bin/bash
sudo cp /etc/login.defs /etc/login.defs.bak
grep '^CREATE_HOME' /etc/login.defs
sudo sed -i 's/^CREATE_HOME.*/CREATE_HOME yes/' /etc/login.defs
sudo useradd -s /bin/bash homeuser1
ls -ld /home/homeuser1
sudo sed -i 's/^CREATE_HOME.*/CREATE_HOME no/' /etc/login.defs
sudo useradd -s /bin/bash homeuser2
ls -ld /home/homeuser2
sudo userdel -r homeuser1
sudo userdel homeuser2
sudo cp /etc/login.defs.bak /etc/login.defs
```

**Output**
```
CREATE_HOME     yes
drwx------. 2 homeuser1 homeuser1 62 окт  4 12:00 /home/homeuser1
ls: cannot access '/home/homeuser2': No such file or directory
```

## 2.2.39

**2_2_39.sh**
```bash
#!/bin/bash
sudo cp /etc/login.defs /etc/login.defs.bak
sudo sed -i 's/^CREATE_HOME.*/CREATE_HOME yes/' /etc/login.defs
sudo useradd -r -s /sbin/nologin syshome1
ls -ld /home/syshome1
sudo useradd -r -m -s /sbin/nologin syshome2
ls -ld /home/syshome2
sudo userdel -r syshome1
sudo userdel -r syshome2
sudo cp /etc/login.defs.bak /etc/login.defs
```

**Output**
```
ls: cannot access '/home/syshome1': No such file or directory
drwx------. 2 syshome2 syshome2 62 окт  4 12:00 /home/syshome2
```

## 2.2.40

**2_2_40.sh**
```bash
#!/bin/bash
sudo cp /etc/login.defs /etc/login.defs.bak
grep -E '^(UMASK|HOME_MODE)' /etc/login.defs
sudo useradd -m -s /bin/bash umaskuser1
ls -ld /home/umaskuser1
sudo sed -i 's/^UMASK.*/UMASK 077/' /etc/login.defs
grep '^HOME_MODE' /etc/login.defs
sudo useradd -m -s /bin/bash umaskuser2
ls -ld /home/umaskuser2
sudo userdel -r umaskuser1
sudo userdel -r umaskuser2
sudo cp /etc/login.defs.bak /etc/login.defs
```

**Output**
```
UMASK           022
drwx------. 2 umaskuser1 umaskuser1 62 окт  4 12:00 /home/umaskuser1
drwx------. 2 umaskuser2 umaskuser2 62 окт  4 12:00 /home/umaskuser2
```

## 2.2.41

**2_2_41.sh**
```bash
#!/bin/bash
sudo cp /etc/login.defs /etc/login.defs.bak
grep '^USERGROUPS_ENAB' /etc/login.defs
sudo sed -i 's/^USERGROUPS_ENAB.*/USERGROUPS_ENAB yes/' /etc/login.defs
sudo useradd -m -s /bin/bash uguser1
getent group uguser1
sudo sed -i 's/^USERGROUPS_ENAB.*/USERGROUPS_ENAB no/' /etc/login.defs
sudo useradd -m -s /bin/bash uguser2
getent group uguser2
sudo userdel -r uguser1
sudo userdel -r uguser2
sudo cp /etc/login.defs.bak /etc/login.defs
```

**Output**
```
USERGROUPS_ENAB yes
uguser1:x:1007:
(no output for uguser2 — group not created)
```

## 2.2.42

**2_2_42.sh**
```bash
#!/bin/bash
sudo cp /etc/default/useradd /etc/default/useradd.bak
sudo useradd -D -s /bin/sh
sudo useradd -m defaultuser1
getent passwd defaultuser1
sudo userdel -r defaultuser1
sudo cp /etc/default/useradd.bak /etc/default/useradd
```

**Output**
```
defaultuser1:x:1008:1008::/home/defaultuser1:/bin/sh
```

## 2.2.43

**2_2_43.sh**
```bash
#!/bin/bash
sudo cp /etc/default/useradd /etc/default/useradd.bak
sudo useradd -D -b /home/students
sudo mkdir -p /home/students
sudo useradd -m defaultuser2
getent passwd defaultuser2
sudo userdel -r defaultuser2
sudo cp /etc/default/useradd.bak /etc/default/useradd
sudo rmdir /home/students 2>/dev/null
```

**Output**
```
defaultuser2:x:1009:1009::/home/students/defaultuser2:/bin/bash
```