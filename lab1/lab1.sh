#!/bin/bash
whoami
pwd
cd /
pwd
cd .. 2>/dev/null
ls
ls /etc
cd ~
pwd
ls
ls -la
mkdir -p ~/fruits
cd /
mkdir -p ~/animals
cd /tmp
touch temp
echo "Hello" > /tmp/temp
echo "world" >> /tmp/temp
echo "!!!" >> /tmp/temp
cat /tmp/temp
cd ~/fruits
touch apple && touch banana && touch pineaple && touch lion
touch ~/animals/cat.txt ~/animals/dog.txt ~/animals/elephant.txt
ls ~/fruits/a*
ls ~/fruits/*e
ls ~/fruits/*a*n*
cp /etc/passwd ~/
wc -l ~/passwd
ln -s ~/passwd ~/passwd_symlink
ls -i ~/passwd_symlink
cat /etc/issue
cp /etc/issue ~/fruits/apple
cat ~/fruits/apple
mv ~/fruits/lion ~/animals/
mv ~/fruits/pineaple ~/fruits/pineapple
ln ~/.bash_history ~/bash_history_hardlink
ls -l ~/bash_history_hardlink
rm -rf ~/fruits
cat /var/log/boot.log 2>/dev/null
cut -d: -f1 /etc/passwd | sort
grep -c '/bin/bash' /etc/passwd
grep '/bin/bash' /etc/passwd | cut -d: -f1 | sort -r
cut -d: -f1,7 /etc/passwd
cat /etc/shadow 2>/dev/null
groups
sudo usermod -aG wheel $USER
sudo cat /etc/shadow
getent group wheel
sudo dnf update -y
sudo dnf groupinstall -y "Development Tools"
gcc --version | head -n1
g++ --version | head -n1
make --version | head -n1
find --help | head -n 20
sudo find / -name '*pass*' 2>/dev/null | head -n 20
sudo find / -iname '*pass*' 2>/dev/null | head -n 20
sudo find / -maxdepth 1 -name '*pass*' 2>/dev/null
find /home -name '*.bin' 2>/dev/null
find . -type f -name '*.bak' -delete
find . -type f \( -name '*.txt' -o -name '*.sh' \)
find . -type f -printf '%f %u %g %n %s\n'
find . -type d -empty ! -path .
find . -type d -empty ! -path . -delete
find . -type f -empty -delete
find . -type f -links +1
sudo find /etc ! -user root
find . -type f ! -name '*.sh'
find . -type f -links +2
sudo find /usr/bin -type f -atime +90
sudo find /usr/bin /usr/share -type f -mtime -10
sudo find /tmp -type f -mtime +14 -delete