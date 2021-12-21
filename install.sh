#!/bin/sh

echo "Make sure to change /etc/mailname to correct domain prior to running."
echo "Currently $(cat /etc/mailname)"

echo "Program will continue in 5 seconds. Pres Ctrl+C to cancel."
sleep 5

$domain="$(cat /etc/mailname)"

# Install deps
apt update && apt upgrade -y
apt install postfix postfix-pgsql dovecot-imap dovecot-psql opendkim opendkim-tooks spamassassin spamc fail2ban certbot oistgresql -y


# dovecot-sieve maybe not needed with sql

# Make cert
certbot --nginx certonly -d mail.$(echo DOMAIN)

# PostgreSQL
groupadd mailreader
echo "Pick a password for mailreader -user."
read -p "Enter password: " mailreaderpwd
mailreaderpwdhash=$(mkpasswd $mailreaderpwd)
useradd -g mailreader -d /home/mail -s /sbin/nologin mailreader -p $mailreaderpwdhash
mailreader_gid=$(grep 'mailreader' /etc/passwd | cut -d':' -f3)
mkdir /home/mail
chown mailreader:mailreader /home/mail
cat postgresql/pg_hba.conf > /etc/postgresql/12/main/pg_hba.conf
/etc/init.d/postgresql reload
sudo -u postgres psql -f postgresql/config-1.psql
echo "Pick a password for admin@$domain."
read -p "Enter password: " adminpwd
adminpwdhash=$(doveadm pw -S PBKDF2 -p $admimnpwd)
pscmd="$(sed -e "s/ADMINPWD/$adminpwdhash/" \
    -e "s/DOMAIN/$domain/" \
    -e "s/MAILREADER_GID/$mailreader_gid/")"
psql -d mail -U mailreader_admin -W -c "$pscmd"


# Postfix
mv /etc/postfix/master.cf /etc/postfix/master.cf.bk
mv /etc/postfix/main.cf /etc/postfix/main.cf.bk
POSTFIX_MASTER="$(cat postfix/master.cf)"
POSTFIX_MAIN="$(sed -e "s/DOMAIN/$domain/g" -e "s/MAILREADER_GID/$mailreader_gid/g" postfix/main.cf)"
echo "$POSTFIX_MASTER" > /etc/postfix/master.cf
echo "$POSTFIX_MAIN" > /etc/postfix/main.cf
POSTFIX_MBOXES="$(sed "s/MAILREADERPWD/$mailreaderpwd/" postfix/pgsql/mailboxes.cf)"
POSTFIX_TANSPORT="$(sed "s/MAILREADERPWD/$mailreaderpwd/" postfix/pgsql/transport.cf)"
POSTFIX_MBOXES="$(sed "s/MAILREADERPWD/$mailreaderpwd/" postfix/pgsql/mailboxes.cf)"

# Dovecot
doveadm pw -s PBKDS2
mv /etc/dovecot/dovecot.conf /etc/dovecot/dovecot.conf.bk
DOVECOT_CONF="$(sed "s/DOMAIN/$domain/g" dovecot/dovecot.conf)"
echo "$DOVECOT_CONF" > /etc/dovecot.conf

## Dovecot-sieve
mkdir /var/lib/dovecot/sieve/
echo "require [\"fileinto\", \"mailbox\"];
if header :contains \"X-Spam-Flag\" \"YES\"
    {
        fileinto \"Junk\";
    }

if header :contains "subject" ["[SPAM]"]
{
    fileinto "Junk";
    stop;
}
else
{
    keep;
}" > /var/lib/dovecot/sieve/default.sieve

grep -q "^vmail:" /etc/passwd || useradd vmail
chown -R vmail:vmail /var/lib/dovecot
sievec /var/lib/dovecot/sieve/default.sieve

echo "auth required pam_unix.so nullok
account required pam_unix.so" >> /etc/pam.d/dovecot

# OpenDKIM
OPENDKIM_CONF="$(sed s/DOMAIN/$domain/g opendkim/opendkim.conf)"
echo "$OPENDKIM_CONF" > /etc/opendkim.conf

## OpenDKIM keys
mkdir -p /etc/postfix/dkim
opendkim-genkey -D /etc/postfix/dkim/ -d $domain -s mail
chgrp opendkim /etc/postfix/dkim/*
chmod g+r /etc/postfix/dkim/*

## OpenDKIM info
grep -q "$domain" /etc/postfix/dkim/signingtable 2>/dev/null ||
    echo "*@$domain mail._domainkey.$domain" > /etc/postfix/dkim/signingtable

grep -q "$domain" /etc/postfix/dkim/keytable 2>/dev/null ||
    echo "mail._domainkey.$domain $domain:mail:/etc/postfix/dkim/mail.private" >> /etc/opendkim/keytable

grep -q "127.0.0.1" /etc/postfix/dkim/trustedhosts 2>/dev/null ||
	echo "127.0.0.1
10.1.0.0/16" >> /etc/postfix/dkim/trustedhosts

# A fix for "Opendkim won't start: can't open PID file?", as specified here: https://serverfault.com/a/847442
/lib/opendkim/opendkim.service.generate
systemctl daemon-reload

# SpamAssassin
cat spamassassin/local.cf > /etc/spamassassin/local.cf

# Fail2Ban
cat fail2ban/jail.local > /etc/fail2ban/jail.local

# (re)run all programs
for x in spamassassin opendkim dovecot postfix fail2ban; do
	printf "Restarting %s..." "$x"
	service "$x" restart && printf " ...done\\n"
done

pval="$(tr -d "\n" </etc/postfix/dkim/$subdom.txt | sed "s/k=rsa.* \"p=/k=rsa; p=/;s/\"\s*\"//;s/\"\s*).*//" | grep -o "p=.*")"
dkimentry="$subdom._domainkey.$domain	TXT	v=DKIM1; k=rsa; $pval"
dmarcentry="_dmarc.$domain	TXT	v=DMARC1; p=reject; rua=mailto:dmarc@$domain; fo=1"
spfentry="@	TXT	v=spf1 mx a:mail.$domain -all"

mkdir "$HOME"/.config 2>/dev/null
echo "$dkimentry
$dmarcentry
$spfentry" > "$HOME"/.config/dkim

useradd -m -G mail dmarc

# Info
echo "Email has been configured for subdomain mail.$domain."
echo "You will now have to configure the following DNS records:"
echo "mail CNAME $domain"
echo "$dkimentry"
echo "$dmarcentry"
echo "$spfentry"
echo ""
echo "The TXT records are also stored under ~/.config/dkim"
echo "Remember to open your ports!"
