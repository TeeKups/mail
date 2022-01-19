#!/bin/sh

read -p "Enter domain name: " domain
read -p "Enter mail subdomain name (e.g. mail-dom.tld -> mail): " subdom

read_pwd()
{
	read -s -p "Enter pwd: " pass 
	echo ''
	read -s -p "Enter pwd again: " pass2

	if [ $pass != $pass2 ]; then
		echo 'The passwords didnt match! Try again.'
	       	read_pwd
	else
		mailreader_adminpwd=$pass
	fi
}


echo "Pick a password for SQL user mailreader_admin."
read_pwd

mailreaderpwd=$(tr -dc A-Za-z0-9 </dev/urandom | head -c13 ; echo '')

echo $domain > /etc/hostname

# Install dependencies
apt install postfix postfix-pgsql dovecot-imapd dovecot-lmtpd dovecot-pgsql dovecot-sieve opendkim opendkim-tools spamassassin spamc fail2ban python3-certbot-nginx postgresql -y

# Make cert
certbot certonly -d mail.$domain

# PostgreSQL
echo "Configuring PostgreSQL"
groupadd mailreader
mailreaderpwdhash=$(mkpasswd $mailreaderpwd)
useradd -g mailreader -d /home/mail -s /sbin/nologin mailreader -p $mailreaderpwdhash
mailreader_gid=$(grep 'mailreader' /etc/passwd | cut -d':' -f3)
mkdir /home/mail
chown mailreader:mailreader /home/mail
cat postgresql/pg_hba.conf > /etc/postgresql/13/main/pg_hba.conf
/etc/init.d/postgresql reload
while read line; do
	sudo -u postgres psql -c "$line"
done <<<"$(sed -e s/ADMINPWD/$mailreader_adminpwd/ -e s/MAILREADERPWD/$mailreaderpwd/ postgresql/config-1.psql)"
echo "Pick a password for admin@$domain."
read -p "Enter password: " adminpwd
adminpwdhash=$(doveadm pw -s PBKDF2 -p $adminpwd)
cp postgresql/config-2.psql postgresql/config-2.psql.tmp
sed -i -e s/ADMINPWD/$adminpwdhash/g -e s/DOMAIN/$domain/g -e s/MAILREADER_GID/$mailreader_gid/g postgresql/config-2.psql.tmp
psql -d mail -U mailreader_admin -f postgresql/config-2.psql.tmp
rm postgresql/config-2.psql.tmp

# Postfix
echo "Configuring Postfix"
mv /etc/postfix/master.cf /etc/postfix/master.cf.bk
mv /etc/postfix/main.cf /etc/postfix/main.cf.bk
cp postfix/master.cf /etc/postfix/master.cf
cp postfix/main.cf /etc/postfix/main.cf
sed -i -e "s/DOMAIN/$domain/g" -e "s/MAILREADER_GID/$mailreader_gid/g" /etc/postfix/main.cf
[ -d /etc/postfix/pgsql ] || mkdir /etc/postfix/pgsql
cp postfix/pgsql/mailboxes.cf /etc/postfix/pgsql/mailboxes.cf
cp postfix/pgsql/transport.cf /etc/postfix/pgsql/transport.cf
cp postfix/pgsql/aliases.cf /etc/postfix/pgsql/aliases.cf
sed -i "s/MAILREADERPWD/$mailreaderpwd/" /etc/postfix/pgsql/mailboxes.cf
sed -i "s/MAILREADERPWD/$mailreaderpwd/" /etc/postfix/pgsql/transport.cf
sed -i "s/MAILREADERPWD/$mailreaderpwd/" /etc/postfix/pgsql/aliases.cf
echo '/^Received:.*with ESMTPSA/ IGNORE' > /etc/postfix/header_checks

# Dovecot
echo "Configuring Dovecot"
#doveadm pw -s PBKDS2
[ -f /etc/dovecot/dovecot.conf ] && mv /etc/dovecot/dovecot.conf /etc/dovecot/dovecot.conf.bk
cp dovecot/dovecot.conf /etc/dovecot/dovecot.conf
sed -i -e "s/DOMAIN/$domain/g" -e "s/MAILREADER_GID/$mailreader_gid/g" /etc/dovecot/dovecot.conf
cp dovecot/dovecot-sql.conf.ext /etc/dovecot/dovecot-sql.conf.ext
sed -i "s/MAILREADER_PWD/$mailreaderpwd/g" /etc/dovecot/dovecot-sql.conf.ext

## Dovecot-sieve
echo "Configuring Dovecot-sieve"
[ -d /var/lib/dovecot/sieve ] || mkdir /var/lib/dovecot/sieve
echo "require [\"fileinto\", \"mailbox\"];
if header :contains \"X-Spam-Flag\" \"YES\"
    {
        fileinto \"Junk\";
    }

if header :contains \"subject\" [\"[SPAM]\"]
{
    fileinto \"Junk\";
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
echo "Configuring OpenDKIM"
OPENDKIM_CONF="$(sed s/DOMAIN/$domain/g opendkim/opendkim.conf)"
echo "$OPENDKIM_CONF" > /etc/opendkim.conf

## OpenDKIM keys
mkdir -p /etc/postfix/dkim
opendkim-genkey -D /etc/postfix/dkim/ -d $domain -s $subdom
chgrp opendkim /etc/postfix/dkim/*
chmod g+r /etc/postfix/dkim/*

## OpenDKIM info
grep -q "$domain" /etc/postfix/dkim/signingtable 2>/dev/null ||
    echo "*@$domain mail._domainkey.$domain" > /etc/postfix/dkim/signingtable

grep -q "$domain" /etc/postfix/dkim/keytable 2>/dev/null ||
    echo "mail._domainkey.$domain $domain:mail:/etc/postfix/dkim/mail.private" >> /etc/postfix/dkim/keytable

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
echo "Restarting programs..."
for x in spamassassin opendkim dovecot postfix fail2ban; do
	printf "Restarting %s..." "$x"
	service "$x" restart && printf " ...done\\n"
done

pval="$(tr -d "\n" </etc/postfix/dkim/$subdom.txt | sed "s/k=rsa.* \"p=/k=rsa; p=/;s/\"\s*\"//;s/\"\s*).*//" | grep -o "p=.*")"
dkimentry="$subdom._domainkey.$domain	TXT	v=DKIM1; k=rsa; $pval"
dmarcentry="_dmarc.$domain	TXT	v=DMARC1; p=quarantine; rua=mailto:dmarc@$domain; fo=1"
spfentry="@	TXT	v=spf1 mx a:mail.$domain -all"

mkdir "$HOME"/.config 2>/dev/null
echo "$dkimentry
$dmarcentry
$spfentry" > "$HOME"/.config/dkim

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
