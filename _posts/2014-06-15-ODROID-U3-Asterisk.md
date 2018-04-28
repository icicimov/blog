---
type: posts
header:
  teaser: 'futuristic-banner.jpg'
title: 'ODROID-U3 as Asterisk Phone Central'
categories: 
  - Server
tags: [odroid, asterisk, freepbx]
date: 2014-6-15
---

# Setup

# Install needed packages and prepare MySQL

```
# apt-get install build-essential libqt4-dev git apache2 \
php-pear php-db php5-curl php5-gd libapache2-mod-php5 apache2-utils \
curl sox libncurses5-dev libssl-dev libmysqlclient15-dev mpg123 libxml2-dev \
libnewt-dev sqlite3 libsqlite3-dev pkg-config automake libtool autoconf \
git subversion uuid uuid-dev mysql-server-5.5 mysql-client-5.5 php5-mysql \
asterisk dahdi dahdi-firmware-nonfree asterisk-dahdi dahdi-dkms dahdi-linux \
dahdi-source yate-dahdi libopenr2-3 libtonezone2.0 libasound2-dev libogg-dev \
bison flex libspandsp-dev

# cd /usr/src/
# wget -O /usr/src/freepbx-2.11.0.25.tgz http://mirror.freepbx.org/freepbx-2.11.0.25.tgz
# tar -xzvf /usr/src/freepbx-2.11.0.25.tgz -C /usr/src/

# mysqladmin -u root create asterisk -p
# mysqladmin -u root create asteriskcdrdb -p
# mysql -u root asterisk -p < /usr/src/freepbx/SQL/newinstall.sql
# mysql -u root asteriskcdrdb -p < /usr/src/freepbx/SQL/cdr_mysql_table.sql 
# mysql -u root -p -e "GRANT ALL PRIVILEGES ON asterisk.* TO asteriskuser@localhost IDENTIFIED BY '${ASTERISK_DB_PW}';"
# mysql -u root -p -e "GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO asteriskuser@localhost IDENTIFIED BY '${ASTERISK_DB_PW}';"
# mysql -u root -p -e "flush privileges;"
```

Upgrade PEAR and downgrade DB module to 1.7.14:

```
# pear install -Z pear
# pear uninstall db
# pear install db-1.7.14
```

Later ones are broken and cause problems for freepbx. From freepbx-13 the PEAR dependencies will be complitely removed.

## Install FreePBX

```
# /usr/src/freepbx/install_amp
# /usr/src/freepbx/apply_conf.sh
# ln -s /var/lib/asterisk/moh /var/lib/asterisk/mohmp3
# amportal start
```

## Bug fixes

```
igorc@odroid:~$ sudo mkdir /var/www/html/admin/modules/_cache
igorc@odroid:~$ sudo chown asterisk:asterisk /var/www/html/admin/modules/_cache
igorc@odroid:~$ sudo chmod -R g+rw /var/lib/php5/*
root@odroid:~# for i in "extensions features iax logger sip sip_notify"; do \
    mv /etc/asterisk/$i.conf /etc/asterisk/$i.conf.default; \
    ln -s /var/www/html/admin/modules/core/etc/$i.conf /etc/asterisk/$i.conf; \
done
```

## Upgrade the Asterisk modules

```
igorc@odroid:~$ sudo -u asterisk /var/lib/asterisk/bin/module_admin download framework
igorc@odroid:~$ sudo -u asterisk /var/lib/asterisk/bin/module_admin install framework
igorc@odroid:~$ sudo amportal a ma upgrade core
igorc@odroid:~$ sudo amportal a ma upgradeall
igorc@odroid:~$ sudo amportal a ma reload
```

some other modules to install:

```
igorc@odroid:~$ sudo amportal a ma download ttsengines
igorc@odroid:~$ sudo amportal a ma install ttsengines
```

## Fix the DAHDI warnings

Put in `/etc/modprobe.d/dahdi.conf`:

```
options wctdm24xxp alawoverride=0
```

and set permissions:

```
igorc@odroid:~$ sudo chmod 666 /etc/modprobe.d/dahdi.conf
```

## Set proper permissions on all Asterisk files

```
igorc@odroid:~$ sudo amportal chown
```

## Prevent `amportal start` from hanging

In `/usr/sbin/safe_asterisk` change `SAFE_AST_BACKGROUND=0` to `SAFE_AST_BACKGROUND=1`.

## Increase max file upload size

Modify apache `/etc/php5/apache2/php.ini`

```
upload_max_filesize = 120M
```

## Allow `www-data` apache user to access asterisk web sessions 

Add this to root crontab:

```
@reboot while true; do chmod -R g+rw /var/lib/php5/sess_*; sleep 1; done
```

Or just run apache as Asterisk user:

```
igorc@odroid:~$ sudo sed -i 's/^\(User\|Group\).*/\1 asterisk/' /etc/apache2/apache2.conf
```

## Start/Restart Asterisk

```
igorc@odroid:~$ sudo amportal stop
igorc@odroid:~$ sudo amportal start
```

## Apache

```
igorc@odroid:~$ cat /etc/apache2/sites-available/000-default

  DocumentRoot /var/www/html
  <Directory />
          Options FollowSymLinks
          AllowOverride None
  </Directory>
  <Directory /var/www/html/>
          Options Indexes FollowSymLinks MultiViews
          AllowOverride All
          Order allow,deny
          allow from all
  </Directory>

  ServerAdmin webmaster@localhost

  ErrorLog ${APACHE_LOG_DIR}/error.log
  CustomLog ${APACHE_LOG_DIR}/access.log combined

igorc@odroid:~$ sudo service apache2 restart
```

To finish the setup go to `http://192.168.1.206/admin` and create the admin account, install/upgrade modules, set SIP etc.

## Install g279 codec

The `Digium g729` codec is propriatory and license is $10 per host. Only free one with support for ARM cpu is `bcg729` codec.

```
igorc@odroid:~$ wget http://download-mirror.savannah.gnu.org/releases/linphone/plugins/sources/bcg729-1.0.0.tar.gz
igorc@odroid:~$ tar -xzvf bcg729-1.0.0.tar.gz 
igorc@odroid:~$ cd bcg729-1.0.0/
igorc@odroid:~$ ./configure 
igorc@odroid:~$ make
igorc@odroid:~$ sudo make install
```

Next we need to compile and install `asterisk-g72x` based on `bcg729` codec we just installed. We also need to install the Asterisk development package first:

```
igorc@odroid:~$ sudo apt-get install asterisk-dev

igorc@odroid:~$ wget http://asterisk.hosting.lv/src/asterisk-g72x-1.2.tar.bz2
igorc@odroid:~$ tar -xjvf asterisk-g72x-1.2.tar.bz2
igorc@odroid:~$ cd asterisk-g72x-1.2/
igorc@odroid:~/asterisk-g72x-1.2$ vi configure.ac
...
if test -z "$saved_cflags"; then
    CFLAGS="-O3 -fomit-frame-pointer -march=$march $flto $cflags"
    FLTO_LDFLAGS="$fwholeprg"
fi
CFLAGS="$CFLAGS -Werror -O3 -funroll-loops -marm -march=armv7-a -mtune=cortex-a7"   # add this line

igorc@odroid:~/asterisk-g72x-1.2$ ./autogen.sh
igorc@odroid:~/asterisk-g72x-1.2$ ./configure --with-bcg729
.
.
Architecture: armv7l
  CPU -march: native
      CFLAGS: -O3 -fomit-frame-pointer -march=native -flto  -Werror -O3 -funroll-loops -marm -march=armv7-a -mtune=cortex-a7  
     LDFLAGS: -fwhole-program
 Codecs impl: Bcg729

igorc@odroid:~/asterisk-g72x-1.2$ make
igorc@odroid:~/asterisk-g72x-1.2$ sudo cp .libs/codec_g729.so /usr/lib/asterisk/modules/codec_g729.so
igorc@odroid:~/asterisk-g72x-1.2$ sudo amportal restart
```

Check the codec has loaded:

```
odroid*CLI> core show codecs audio
Disclaimer: this command is for informational purposes only.
    It does not indicate anything about your configuration.
      ID  TYPE     NAME DESCRIPTION
-----------------------------------------------------------------------------------
  100001 audio     g723 (G.723.1)
  100002 audio      gsm (GSM)
  100003 audio     ulaw (G.711 u-law)
  100004 audio     alaw (G.711 A-law)
  100011 audio     g726 (G.726 RFC3551)
  100006 audio    adpcm (ADPCM)
  100019 audio     slin (16 bit Signed Linear PCM)
  100007 audio    lpc10 (LPC10)
  100008 audio     g729 (G.729A)
.
.

odroid*CLI> core show translation recalc 10
         Recalculating Codec Translation (number of sample seconds: 10)

         Translation times between formats (in microseconds) for one second of data
          Source Format (Rows) Destination Format (Columns)

            gsm  ulaw  alaw  g726 adpcm  slin lpc10  g729 speex speex16 g726aal2  g722 slin16 testlaw speex32 slin12 slin24 slin32 slin44 slin48 slin96 slin192
      gsm     - 15000 15000 15000 15000  9000 15000 15000 15000   23000    15000 17250  17000   15000   23000  17000  17000  17000  17000  17000  17000   17000
     ulaw 15000     -  9150 15000 15000  9000 15000 15000 15000   23000    15000 17250  17000   15000   23000  17000  17000  17000  17000  17000  17000   17000
     alaw 15000  9150     - 15000 15000  9000 15000 15000 15000   23000    15000 17250  17000   15000   23000  17000  17000  17000  17000  17000  17000   17000
     g726 15000 15000 15000     - 15000  9000 15000 15000 15000   23000    15000 17250  17000   15000   23000  17000  17000  17000  17000  17000  17000   17000
    adpcm 15000 15000 15000 15000     -  9000 15000 15000 15000   23000    15000 17250  17000   15000   23000  17000  17000  17000  17000  17000  17000   17000
     slin  6000  6000  6000  6000  6000     -  6000  6000  6000   14000     6000  8250   8000    6000   14000   8000   8000   8000   8000   8000   8000    8000
    lpc10 15000 15000 15000 15000 15000  9000     - 15000 15000   23000    15000 17250  17000   15000   23000  17000  17000  17000  17000  17000  17000   17000
     g729 15000 15000 15000 15000 15000  9000 15000     - 15000   23000    15000 17250  17000   15000   23000  17000  17000  17000  17000  17000  17000   17000
.
.
```

Now we can see g729 showing up in the output.

## Telecube Trunk Setup

The DID obtained from Telecube comes with 10 VoIP extensions attached to it by default. I use the `10XXXXX` one for the Trunk to my home Asterisk server. The relevant Trunk settings in FreePBX are given below:

```
Outgoing Settings

Trunk Name?:  telecube
PEER Details?:
host=sip.telecube.net.au
defaultuser=10XXXXX
fromuser=10XXXXX
remotesecret=<MY_EXTENSION_PASSWORD>
type=peer
insecure=port,invite
preferred_codec_only=yes
disallow=all
allow=g729&ulaw&alaw
dtmfmode=rfc2833
use_q850_reason=yes
qualify=2000

Incoming Settings

USER Context?:  <MY_TC_ACC_ID>
USER Details?:
host=sip.telecube.net.au
username=10XXXXX

Registration

Register String?: 
10XXXXX:<MY_EXTENSION_PASSWORD>@sip.telecube.net.au/10XXXXX
```

In order to receive incoming calls an `Inbound Route` needs to be set with `DID Number` value of the extension we use `10XXXXX`.

Apart from that, under `Extensions` I set my devices like Zoiper on my PC and Laptop and my Gigaset A510 VoIP phone I purchased from Telecube and add them to a `Ring Group` so any incoming call will go to all available/connected devices (extensions).

For external outgoing calls I have `Outbound Route` set that goes via Telecube trunk and has condition for the extensions to prefix the number they want to call with `9`. For internal calls you just dial the extension you want to call.

The peer details:

```
odroid*CLI> sip show peer telecube

  * Name       : telecube
  Description  : 
  Secret       : <Not set>
  MD5Secret    : <Not set>
  Remote Secret: <Set>
  Context      : from-trunk-sip-telecube
  Record On feature : automon
  Record Off feature : automon
  Subscr.Cont. : <Not set>
  Language     : 
  Tonezone     : <Not set>
  AMA flags    : Unknown
  Transfer mode: open
  CallingPres  : Presentation Allowed, Not Screened
  FromUser     : 10XXXXX
  Callgroup    : 
  Pickupgroup  : 
  Named Callgr : 
  Nam. Pickupgr: 
  MOH Suggest  : 
  Mailbox      : 
  VM Extension : *97
  LastMsgsSent : 0/0
  Call limit   : 0
  Max forwards : 0
  Dynamic      : No
  Callerid     : "" <>
  MaxCallBR    : 384 kbps
  Expire       : -1
  Insecure     : port,invite
  Force rport  : Yes
  Symmetric RTP: Yes
  ACL          : No
  DirectMedACL : No
  T.38 support : Yes
  T.38 EC mode : Redundancy
  T.38 MaxDtgrm: 400
  DirectMedia  : Yes
  PromiscRedir : No
  User=Phone   : No
  Video Support: No
  Text Support : No
  Ign SDP ver  : No
  Trust RPID   : No
  Send RPID    : No
  Subscriptions: Yes
  Overlap dial : Yes
  DTMFmode     : rfc2833
  Timer T1     : 500
  Timer B      : 32000
  ToHost       : sip.telecube.net.au
  Addr->IP     : 103.193.167.55:5060
  Defaddr->IP  : (null)
  Prim.Transp. : UDP
  Allowed.Trsp : UDP
  Def. Username: 10XXXXX
  SIP Options  : replaces replace timer 
  Codecs       : (ulaw|alaw|g729)
  Codec Order  : (g729:20,ulaw:20,alaw:20)
  Auto-Framing :  No 
  Status       : OK (32 ms)
  Useragent    : 
  Reg. Contact : 
  Qualify Freq : 60000 ms
  Keepalive    : 0 ms
  Sess-Timers  : Accept
  Sess-Refresh : uas
  Sess-Expires : 1800 secs
  Min-Sess     : 90 secs
  RTP Engine   : asterisk
  Parkinglot   : 
  Use Reason   : Yes
  Encryption   : No

odroid*CLI> 
```

We can check the status of all our services on the FreePBX status page:

![FreePBX system status](/blog/images/FreePBX.png "FreePBX system status")

## Firewall

Execute the following commands:

```
# Apache FreePBX admin console access
iptables -A INPUT -p tcp --sport 1024:65535 --dport 80 -i eth0 -s 192.168.1.0/24 -m state --state NEW -j ACCEPT
iptables -A INPUT -p tcp --sport 1024:65535 --dport 443 -i eth0 -s 192.168.1.0/24 -m state --state NEW -j ACCEPT

# Asterisk (also forward udp sip port 5060 and udp rtp ports 10000:10100 to odroid server) 
# SIP on UDP port 5060 (allow inside network and Telecube SIP server)
iptables -A INPUT -p udp -m udp --sport 1024:65535 -m multiport --dports 5004:5082 -i eth0 -s 192.168.1.0/24 -m state --state NEW -j ACCEPT
iptables -A INPUT -p udp -m udp --sport 1024:65535 -m multiport --dports 5004:5082 -i eth0 -s 54.206.26.224 -m state --state NEW -j ACCEPT
# IAX2 protocol
iptables -A INPUT -p udp -m udp --sport 1024:65535 --dport 4569 -i eth0 -s 192.168.1.0/24 -m state --state NEW -j ACCEPT
iptables -A INPUT -p udp -m udp --sport 1024:65535 --dport 4569 -i eth0 -s 54.206.26.224 -m state --state NEW -j ACCEPT
# IAX protocol
iptables -A INPUT -p udp -m udp --sport 1024:65535 --dport 5036 -i eth0 -s 192.168.1.0/24 -m state --state NEW -j ACCEPT
iptables -A INPUT -p udp -m udp --sport 1024:65535 --dport 5036 -i eth0 -s 54.206.26.224 -m state --state NEW -j ACCEPT
# RTP - the media stream (related to the port range in /etc/asterisk/rtp.conf) 
iptables -A INPUT -p udp -m udp --sport 1024:65535 -m multiport --dports 10000:20000 -i eth0 -s 192.168.1.0/24 -m state --state NEW -j ACCEPT
# MGCP - if you use media gateway control protocol in the configuration
iptables -A INPUT -p udp -m udp --sport 1024:65535 --dport 2727 -i eth0 -s 192.168.1.0/24 -m state --state NEW -j ACCEPT
# Some hacking protection (additionally to strong passwords)
iptables -I INPUT -p udp -m udp --dport 5060 -m string --string "User-Agent: VaxSIPUserAgent" --algo bm --to 65535 -j DROP 
iptables -I INPUT -p udp -m udp --dport 5060 -m string --string "User-Agent: friendly-scanner" --algo bm --to 65535 -j REJECT --reject-with icmp-port-unreachable 
iptables -I INPUT -p udp -m udp --dport 5060 -m string --string "REGISTER sip:" --algo bm -m recent --set --name VOIP --rsource 
iptables -I INPUT -p udp -m udp --dport 5060 -m string --string "REGISTER sip:" --algo bm -m recent --update --seconds 60 --hitcount 12 --rttl --name VOIP --rsource -j DROP 
iptables -I INPUT -p udp -m udp --dport 5060 -m string --string "INVITE sip:" --algo bm -m recent --set --name VOIPINV --rsource 
iptables -I INPUT -p udp -m udp --dport 5060 -m string --string "INVITE sip:" --algo bm -m recent --update --seconds 60 --hitcount 12 --rttl --name VOIPINV --rsource -j DROP 
iptables -I INPUT -p udp -m hashlimit --hashlimit 6/sec --hashlimit-mode srcip,dstport --hashlimit-name tunnel_limit -m udp --dport 5060 -j ACCEPT
```

Save the config:

```
root@odroid:~# iptables-save > /etc/network/firewall.rules
```

My complete firewall rules:

```
root@odroid:~# cat /etc/network/firewall.rules
# Generated by iptables-save v1.4.21 on Sun Nov 30 19:34:53 2014
*mangle
:PREROUTING ACCEPT [27202999:8401977627]
:INPUT ACCEPT [20133529:3455300076]
:FORWARD ACCEPT [7027505:4938540549]
:OUTPUT ACCEPT [20547657:4999799248]
:POSTROUTING ACCEPT [27575162:9938339797]
:FAST_DNS - [0:0]
-A OUTPUT -s 192.168.24.1/32 -o eth0 -p tcp -m pkttype --pkt-type unicast -m tcp --dport 53 -m state --state NEW,RELATED,ESTABLISHED -j FAST_DNS
-A OUTPUT -s 192.168.24.1/32 -o eth0 -p udp -m pkttype --pkt-type unicast -m udp --dport 53 -m state --state NEW,RELATED,ESTABLISHED -j FAST_DNS
-A FAST_DNS -d 192.168.1.205 -p udp -j TOS --set-tos 0x10/0x3f 
-A FAST_DNS -d 8.8.8.8/32 -p udp -j TOS --set-tos 0x10/0x3f
-A FAST_DNS -d 8.8.4.4/32 -p udp -j TOS --set-tos 0x10/0x3f
-A FAST_DNS -d 192.168.1.205 -p tcp -j TOS --set-tos 0x10/0x3f
-A FAST_DNS -d 8.8.8.8/32 -p tcp -j TOS --set-tos 0x10/0x3f
-A FAST_DNS -d 8.8.4.4/32 -p tcp -j TOS --set-tos 0x10/0x3f
COMMIT
# Completed on Sun Nov 30 19:34:53 2014
# Generated by iptables-save v1.4.21 on Sun Nov 30 19:34:53 2014
*filter
:INPUT DROP [1:36]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [378:173060]
-A INPUT -p udp -m hashlimit --hashlimit-upto 6/sec --hashlimit-burst 5 --hashlimit-mode srcip,dstport --hashlimit-name tunnel_limit -m udp --dport 5060 -j ACCEPT
-A INPUT -p udp -m udp --dport 5060 -m string --string "INVITE sip:" --algo bm --to 65535 -m recent --update --seconds 60 --hitcount 12 --rttl --name VOIPINV --mask 255.255.255.255 --rsource -j DROP
-A INPUT -p udp -m udp --dport 5060 -m string --string "INVITE sip:" --algo bm --to 65535 -m recent --set --name VOIPINV --mask 255.255.255.255 --rsource
-A INPUT -p udp -m udp --dport 5060 -m string --string "REGISTER sip:" --algo bm --to 65535 -m recent --update --seconds 60 --hitcount 12 --rttl --name VOIP --mask 255.255.255.255 --rsource -j DROP
-A INPUT -p udp -m udp --dport 5060 -m string --string "REGISTER sip:" --algo bm --to 65535 -m recent --set --name VOIP --mask 255.255.255.255 --rsource
-A INPUT -p udp -m udp --dport 5060 -m string --string "User-Agent: friendly-scanner" --algo bm --to 65535 -j REJECT --reject-with icmp-port-unreachable
-A INPUT -p udp -m udp --dport 5060 -m string --string "User-Agent: VaxSIPUserAgent" --algo bm --to 65535 -j DROP
-A INPUT -i lo -j ACCEPT
-A INPUT -s 127.0.0.1/32 -j ACCEPT
-A INPUT -i wlan0 -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -m limit --limit 5/sec -j ACCEPT
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -i eth0 -p tcp -m tcp --sport 1024:65535 --dport 22 -m state --state NEW -j ACCEPT
-A INPUT -s 192.168.24.0/24 -i wlan0 -p udp -m udp --sport 1024:65535 --dport 53 -m state --state NEW -j ACCEPT
-A INPUT -s 192.168.24.0/24 -i wlan0 -p tcp -m tcp --sport 1024:65535 --dport 53 -m state --state NEW -j ACCEPT
-A INPUT -s 192.168.24.0/24 -i wlan0 -p tcp -m tcp --sport 1024:65535 --dport 9050 -m state --state NEW -j ACCEPT
-A INPUT -i wlan0 -p udp -m udp --sport 1024:65535 -m multiport --dports 67:68 -m state --state NEW -j ACCEPT
-A INPUT -i wlan0 -p tcp -m tcp --sport 1024:65535 -m multiport --dports 67:68 -m state --state NEW -j ACCEPT
-A INPUT -s 192.168.1.0/24 -i eth0 -p tcp -m tcp --sport 1024:65535 --dport 80 -m state --state NEW -j ACCEPT
-A INPUT -s 192.168.1.0/24 -i eth0 -p tcp -m tcp --sport 1024:65535 --dport 443 -m state --state NEW -j ACCEPT
-A INPUT -s 192.168.1.0/24 -i eth0 -p udp -m udp --sport 1024:65535 --dport 5060 -m state --state NEW -j ACCEPT
-A INPUT -s 192.168.1.0/24 -i eth0 -p udp -m udp --sport 1024:65535 --dport 4569 -m state --state NEW -j ACCEPT
-A INPUT -s 192.168.1.0/24 -i eth0 -p udp -m udp --sport 1024:65535 --dport 5036 -m state --state NEW -j ACCEPT
-A INPUT -s 192.168.1.0/24 -i eth0 -p udp -m udp --sport 1024:65535 -m multiport --dports 10000:20000 -m state --state NEW -j ACCEPT
-A INPUT -s 192.168.1.0/24 -i eth0 -p udp -m udp --sport 1024:65535 --dport 2727 -m state --state NEW -j ACCEPT
-A INPUT -s 54.206.26.224/32 -i eth0 -p udp -m udp --sport 1024:65535 --dport 5060 -m state --state NEW -j ACCEPT
-A INPUT -p udp -m udp --sport 1024:65535 --dport 53 -m state --state NEW -j ACCEPT
-A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -i wlan0 -o eth0 -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
COMMIT
# Completed on Sun Nov 30 19:34:53 2014
# Generated by iptables-save v1.4.21 on Sun Nov 30 19:34:53 2014
*nat
:PREROUTING ACCEPT [743509:64485076]
:INPUT ACCEPT [293547:17847242]
:OUTPUT ACCEPT [613951:38291989]
:POSTROUTING ACCEPT [454790:27925700]
-A POSTROUTING -o eth0 -j MASQUERADE
COMMIT
# Completed on Sun Nov 30 19:34:53 2014
root@odroid:~#
```