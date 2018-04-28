---
type: posts
header:
  teaser: 'futuristic-banner.jpg'
title: 'ODROID-U3 as wireless router'
categories: 
  - Server
tags: [odroid]
date: 2014-5-15
---

[ODROID-U3](http://www.hardkernel.com/main/products/prdt_info.php?g_code=G138745696275) is tiny SBC from Hardkernel packing quad-core CPU and 2GB of RAM.

# Preparing the image

I had two images in consideration:

```
$ wget http://oph.mdrjr.net/meveric/images/Ubuntu-Server-14.04-armhf-U2-1.0_20140422.img.xz
$ wget http://oph.mdrjr.net/memeka/ezywheezy-u3-23032014.img.xz
```

and decided to installed Ubuntu-Server-14.04 headless server. Connected a 16GB SanDisk SD card to my linux pc and dumped the image:

```
$ xz -d Ubuntu-Server-14.04-armhf-U2-1.0_20140422.img.xz
$ sudo dd if=Ubuntu-Server-14.04-armhf-U2-1.0_20140422.img of=/dev/sdc bs=4M
```

The default user/password combination is `linaro/linaro`. I also want to set static IP on the wired interface and configure the default GW:

```
$ sudo fdisk -lu /dev/sdc
$ sudo mount /dev/sdc2 /media/rootfs
$ sudo vi /media/rootfs/etc/network/interfaces.d/eth0
auto eth0
allow-hotplug eth0
iface eth0 inet static
  address 192.168.1.206
  network 192.168.1.0
  netmask 255.255.255.0
  broadcast 192.168.1.255
  gateway 192.168.1.254
  dns-nameservers 192.168.1.205 192.168.1.254
  dns-search cicim.no-ip.org
$ sudo umount /dev/sdc1 /dev/sdc2
```

Now insert the SD card into U3 and boot with network cable connected. Then ssh to U3:

```
$ ssh linaro@192.168.1.206
```

# Odroid Setup

## Timezone

```
root@odroid:~# rm /etc/localtime 
root@odroid:~# ln -s /usr/share/zoneinfo/Australia/Sydney /etc/localtime
```

## Add a new user

```
root@odroid:~# useradd -c "Igor Cicimov" -s /bin/bash -m -G sudo igorc
root@odroid:~# passwd igorc
```

Logout and login as igorc and delete the default image user:

```
root@odroid:~# userdel linaro
```

## Resize the root partition

The following script will be used for this purpose:

```
root@odroid:~# vi resize.sh 
#!/bin/bash

fdisk_first() {
    p2_start=`fdisk -l /dev/mmcblk0 | grep mmcblk0p2 | awk '{print $2}'`
    echo "Found the start point of mmcblk0p2: $p2_start"
    fdisk /dev/mmcblk0 << __EOF__ >> /dev/null
d
2
n
p
2
$p2_start

p
w
__EOF__

    sync
    touch /root/.resize
    echo "Ok, Partition resized, please reboot now"
    echo "Once the reboot is completed please run this script again"
}

resize_fs() {
    echo "Activating the new size"
    resize2fs /dev/mmcblk0p2 >> /dev/null
    echo "Done!"
    echo "Enjoy your new space!"
    rm -rf /root/.resize
}

if [ -f /root/.resize ]; then
    resize_fs
else
    fdisk_first
fi
```

Make it executable, run it and reboot:

```
root@odroid:~# chmod u+x resize.sh

root@odroid:~# ./resize.sh 
Found the start point of mmcblk0p2: 134144
Ok, Partition resized, please reboot now
Once the reboot is completed please run this script again

root@odroid:~# reboot
```

Now connect again and run the script once more:

```
igorc@odroid:~$ df -h
Filesystem      Size  Used Avail Use% Mounted on
/dev/mmcblk0p2 1009M  643M  315M  68% /
none            884M  8.0K  884M   1% /dev
none            4.0K     0  4.0K   0% /sys/fs/cgroup
tmpfs          1012M     0 1012M   0% /tmp
none            203M  344K  202M   1% /run
none            5.0M  4.0K  5.0M   1% /run/lock
none           1012M     0 1012M   0% /run/shm
none            100M     0  100M   0% /run/user
/dev/mmcblk0p1   64M   13M   52M  20% /boot

root@odroid:~# ./resize.sh 
Activating the new size
resize2fs 1.42.9 (4-Feb-2014)
Done!
Enjoy your new space!

root@odroid:~# df -h
Filesystem      Size  Used Avail Use% Mounted on
/dev/mmcblk0p2   15G  647M   14G   5% /
none            884M  8.0K  884M   1% /dev
none            4.0K     0  4.0K   0% /sys/fs/cgroup
tmpfs          1012M     0 1012M   0% /tmp
none            203M  348K  202M   1% /run
none            5.0M     0  5.0M   0% /run/lock
none           1012M     0 1012M   0% /run/shm
none            100M     0  100M   0% /run/user
/dev/mmcblk0p1   64M   13M   52M  20% /boot
```

# Access Point Setup

I'm using the USB WiFi adapter I purchased with the ODROID kit, which also included a plastic case and power supply.

## Configure the interface (wlan0)

With the WiFi adapter now plugged into U3 we configure the wireless network interface:

```
root@odroid:~# vi /etc/network/interfaces.d/wlan0
auto wlan0 
allow-hotplug wlan0 
iface wlan0 inet static
  address 192.168.24.1
  network 192.168.24.0
  netmask 255.255.255.0
  broadcast 192.168.24.255
```

## Set wifi geographic region to improve power levels

Make sure `crda` package is installed, if not then:

```
root@odroid:~# apt-get install crda
```

and set the local region in the config file:

```
root@odroid:~# vi /etc/default/crda
...
REGDOMAIN=AU
```

## Install and configure the AP software

We can simply use the `hostapd` package:

```
root@odroid:~# apt-get install hostapd
```

Unfortunately, the packaged hostapd does not support our Odroid usb wifi dongle with RTL8188CUS chipset:

```
root@odroid:~# lsusb 
Bus 001 Device 005: ID 0bda:8176 Realtek Semiconductor Corp. RTL8188CUS 802.11n WLAN Adapter
```

Workaround is to get hostapd binary that does:

```
root@odroid:~# wget http://www.daveconroy.com/wp3/wp-content/uploads/2013/07/hostapd.zip
root@odroid:~# unzip hostapd.zip
root@odroid:~# mv /usr/sbin/hostapd /usr/sbin/hostapd.default
root@odroid:~# mv hostapd /usr/sbin/
```

and then use `driver=rtl871xdrv` in the hostapd config file.

My full config file at the end:

```
root@odroid:~# cat /etc/hostapd/hostapd.conf | grep -v ^# | grep .
interface=wlan0
driver=rtl871xdrv
logger_syslog=-1
logger_syslog_level=2
logger_stdout=-1
logger_stdout_level=2
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
country_code=AU
ieee80211d=1
hw_mode=g
channel=1
beacon_int=100
dtim_period=2
max_num_sta=255
rts_threshold=2347
fragm_threshold=2346
macaddr_acl=0
auth_algs=3 # put 1 here for WPA2 only
ignore_broadcast_ssid=0
wmm_enabled=1
wmm_ac_bk_cwmin=4
wmm_ac_bk_cwmax=10
wmm_ac_bk_aifs=7
wmm_ac_bk_txop_limit=0
wmm_ac_bk_acm=0
wmm_ac_be_aifs=3
wmm_ac_be_cwmin=4
wmm_ac_be_cwmax=10
wmm_ac_be_txop_limit=0
wmm_ac_be_acm=0
wmm_ac_vi_aifs=2
wmm_ac_vi_cwmin=3
wmm_ac_vi_cwmax=4
wmm_ac_vi_txop_limit=94
wmm_ac_vi_acm=0
wmm_ac_vo_aifs=2
wmm_ac_vo_cwmin=2
wmm_ac_vo_cwmax=3
wmm_ac_vo_txop_limit=47
wmm_ac_vo_acm=0
ieee80211n=1
eapol_key_index_workaround=0
eap_server=0
own_ip_addr=127.0.0.1
ssid=odroid-u3
wpa=2
wpa_passphrase=password
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
wpa_ptk_rekey=600
```

Finally, to avoid the random entropy problem on startup:

```
random: Got 19/20 bytes from /dev/random
random: Only 19/20 bytes of strong random data available from /dev/random
random: Not enough entropy pool available for secure operations
WPA: Not enough entropy in random pool for secure operations - update keys later when the first station connects
```

we install the `haveged` daemon:

```
root@odroid:~# apt-get install haveged
```

Haveged is a program that helps with providing randomness or entropy, which it collects faster than the kernel does by default. I have not seen the message since then.

## Test the configuration

Run from command line and check the output:

```
root@odroid:~# hostapd -d /etc/hostapd/hostapd.conf
random: Trying to read entropy from /dev/random
Configuration file: /etc/hostapd/hostapd.conf
ctrl_interface_group=0
drv->ifindex=4
l2_sock_recv==l2_sock_xmit=0x0x64638
BSS count 1, BSSID mask 00:00:00:00:00:00 (0 bits)
Completing interface initialization
Mode: IEEE 802.11g  Channel: 11  Frequency: 2462 MHz
RATE[0] rate=10 flags=0x1
RATE[1] rate=20 flags=0x1
RATE[2] rate=55 flags=0x1
RATE[3] rate=110 flags=0x1
RATE[4] rate=60 flags=0x0
RATE[5] rate=90 flags=0x0
RATE[6] rate=120 flags=0x0
RATE[7] rate=180 flags=0x0
RATE[8] rate=240 flags=0x0
RATE[9] rate=360 flags=0x0
RATE[10] rate=480 flags=0x0
RATE[11] rate=540 flags=0x0
Flushing old station entries
Deauthenticate all stations
+rtl871x_sta_deauth_ops, ff:ff:ff:ff:ff:ff is deauth, reason=2
rtl871x_set_key_ops
rtl871x_set_key_ops
rtl871x_set_key_ops
rtl871x_set_key_ops
Using interface wlan0 with hwaddr 00:a8:2b:00:08:ab and ssid 'odroid-u3'
Deriving WPA PSK based on passphrase
SSID - hexdump_ascii(len=9):
     6f 64 72 6f 69 64 2d 75 33                        odroid-u3       
PSK (ASCII passphrase) - hexdump_ascii(len=10): [REMOVED]
PSK (from passphrase) - hexdump(len=32): [REMOVED]
rtl871x_set_wps_assoc_resp_ie
rtl871x_set_wps_beacon_ie
rtl871x_set_wps_probe_resp_ie
random: Got 20/20 bytes from /dev/random
GMK - hexdump(len=32): [REMOVED]
Key Counter - hexdump(len=32): [REMOVED]
WPA: group state machine entering state GTK_INIT (VLAN-ID 0)
GTK - hexdump(len=32): [REMOVED]
WPA: group state machine entering state SETKEYSDONE (VLAN-ID 0)
rtl871x_set_key_ops
rtl871x_set_beacon_ops
rtl871x_set_hidden_ssid_ops
ioctl[RTL_IOCTL_HOSTAPD]: Invalid argument
wlan0: Setup of interface done.
```

If all god, CTRL+c and start the service:

```
root@odroid:~# service hostapd start

 * Starting advanced IEEE 802.11 management hostapd     [ OK ]
ioctl[RTL_IOCTL_HOSTAPD]: Invalid argument
```

and now we should see wlan0 up and running:

```
root@odroid:~# iwconfig wlan0
wlan0     IEEE 802.11bgn  ESSID:"odroid-u3"  Nickname:"<WIFI@REALTEK>"
          Mode:Master  Frequency:2.462 GHz  Access Point: 00:A8:2B:00:08:AB   
          Sensitivity:0/0  
          Retry:off   RTS thr:off   Fragment thr:off
          Encryption key:off
          Power Management:off
          Link Quality:0  Signal level:0  Noise level:0
          Rx invalid nwid:0  Rx invalid crypt:0  Rx invalid frag:0
          Tx excessive retries:0  Invalid misc:0   Missed beacon:0

root@odroid:~# ifconfig wlan0
wlan0     Link encap:Ethernet  HWaddr 00:a8:2b:00:08:ab  
          inet addr:192.168.24.1  Bcast:192.168.24.255  Mask:255.255.255.0
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:83 errors:0 dropped:0 overruns:0 frame:0
          TX packets:0 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000 
          RX bytes:0 (0.0 B)  TX bytes:0 (0.0 B)
```

## Compiling from source (if above doesn't work)

Grab the latest source tree:

```
root@odroid:~# cd /usr/src
root@odroid:/usr/src# wget http://w1.fi/releases/hostapd-2.6.tar.gz
root@odroid:/usr/src# tar -xzf hostapd-2.6.tar.gz
root@odroid:/usr/src# cd hostapd-2.6/
```

Test to check if it builds:

```
root@odroid:/usr/src/hostapd-2.6# cd hostapd
root@odroid:/usr/src/hostapd-2.6/hostapd# cp defconfig .config
root@odroid:/usr/src/hostapd-2.6/hostapd# apt-get install libnl-genl-3-dev libnl-3-dev
root@odroid:/usr/src/hostapd-2.6/hostapd# vi .config
[...]
CONFIG_DRIVER_HOSTAP=y
CONFIG_DRIVER_NL80211=y
# Use libnl 3.2 libraries (if this is selected, CONFIG_LIBNL20 is ignored)
CONFIG_LIBNL32=y
CONFIG_IAPP=y
CONFIG_RSN_PREAUTH=y
CONFIG_PEERKEY=y
CONFIG_IEEE80211W=y
CONFIG_EAP=y
CONFIG_ERP=y
CONFIG_EAP_MD5=y
CONFIG_EAP_TLS=y
CONFIG_EAP_MSCHAPV2=y
CONFIG_EAP_PEAP=y
CONFIG_EAP_GTC=y
CONFIG_EAP_TTLS=y
CONFIG_WPS=y
CONFIG_WPS_NFC=y
CONFIG_EAP_IKEV2=y
CONFIG_EAP_TNC=y
CONFIG_EAP_EKE=y
CONFIG_PKCS12=y
CONFIG_RADIUS_SERVER=y
CONFIG_IPV6=y
CONFIG_IEEE80211N=y
CONFIG_IEEE80211AC=y
CONFIG_DEBUG_FILE=y
CONFIG_FULL_DYNAMIC_VLAN=y
CONFIG_TLS=openssl
CONFIG_TLSV11=y
CONFIG_TLSV12=y
CONFIG_INTERWORKING=y
CONFIG_DRIVER_RTW=y
[...]
root@odroid:/usr/src/hostapd-2.6/hostapd# make
```

Then download the `rtl871xdrv` driver patch and apply it:

```
root@odroid:/usr/src/hostapd-2.6/hostapd# cd ../
root@odroid:/usr/src/hostapd-2.6# wget https://raw.githubusercontent.com/pritambaral/hostapd-rtl871xdrv/master/rtlxdrv.patch
root@odroid:/usr/src/hostapd-2.6# patch -Np1 -i ./rtlxdrv.patch 
patching file hostapd/main.c
patching file src/ap/beacon.c
patching file src/ap/hw_features.c
patching file src/drivers/driver.h
patching file src/drivers/driver_bsd.c
patching file src/drivers/driver_rtl.h
patching file src/drivers/driver_rtw.c
patching file src/drivers/driver_wext.c
patching file src/drivers/drivers.c
patching file src/drivers/drivers.mak
patching file src/eap_peer/eap_wsc.c
patching file src/wps/wps.c
patching file src/wps/wps_registrar.c
```

and build hostapd again and install:

```
root@odroid:/usr/src/hostapd-2.6# cd hostapd
root@odroid:/usr/src/hostapd-2.6/hostapd# make clean
root@odroid:/usr/src/hostapd-2.6/hostapd# make
root@odroid:/usr/src/hostapd-2.6/hostapd# make install
install -D hostapd /usr/local/bin//hostapd
install -D hostapd_cli /usr/local/bin//hostapd_cli
```

Test run:

```
root@odroid:/usr/src/hostapd-2.6/hostapd# /usr/local/bin//hostapd -d /etc/hostapd/hostapd.conf
random: Trying to read entropy from /dev/random
Configuration file: /etc/hostapd/hostapd.conf
ctrl_interface_group=0
drv->ifindex=6
l2_sock_recv==l2_sock_xmit=0x0xb19c0
BSS count 1, BSSID mask 00:00:00:00:00:00 (0 bits)
wlan0: interface state UNINITIALIZED->COUNTRY_UPDATE
Previous country code , new country code AU 
Continue interface setup after channel list update
ctrl_iface not configured!
random: Got 20/20 bytes from /dev/random
Channel list update timeout - try to continue anyway
hw vht capab: 0x0, conf vht capab: 0x0
Completing interface initialization
Mode: IEEE 802.11g  Channel: 13  Frequency: 2472 MHz
DFS 0 channels required radar detection
RATE[0] rate=10 flags=0x1
RATE[1] rate=20 flags=0x1
RATE[2] rate=55 flags=0x1
RATE[3] rate=110 flags=0x1
RATE[4] rate=60 flags=0x0
RATE[5] rate=90 flags=0x0
RATE[6] rate=120 flags=0x0
RATE[7] rate=180 flags=0x0
RATE[8] rate=240 flags=0x0
RATE[9] rate=360 flags=0x0
RATE[10] rate=480 flags=0x0
RATE[11] rate=540 flags=0x0
hostapd_setup_bss(hapd=0xb37d0 (wlan0), first=1)
wlan0: Flushing old station entries
wlan0: Deauthenticate all stations
+rtl871x_sta_deauth_ops, ff:ff:ff:ff:ff:ff is deauth, reason=2
rtl871x_set_key_ops
rtl871x_set_key_ops
rtl871x_set_key_ops
rtl871x_set_key_ops
Using interface wlan0 with hwaddr 00:a8:2b:00:08:ab and ssid "odroid-u3"
Deriving WPA PSK based on passphrase
SSID - hexdump_ascii(len=9):
     6f 64 72 6f 69 64 2d 75 33                        odroid-u3       
PSK (ASCII passphrase) - hexdump_ascii(len=10): [REMOVED]
PSK (from passphrase) - hexdump(len=32): [REMOVED]
rtl871x_set_wps_assoc_resp_ie
rtl871x_set_wps_beacon_ie
rtl871x_set_wps_probe_resp_ie
GMK - hexdump(len=32): [REMOVED]
Key Counter - hexdump(len=32): [REMOVED]
WPA: Delay group state machine start until Beacon frames have been configured
VLAN: vlan_set_name_type(name_type=2)
rtl871x_set_beacon_ops
rtl871x_set_hidden_ssid_ops
ioctl[RTL_IOCTL_HOSTAPD]: Invalid argument
WPA: Start group state machine to set initial keys
WPA: group state machine entering state GTK_INIT (VLAN-ID 0)
GTK - hexdump(len=16): [REMOVED]
WPA: group state machine entering state SETKEYSDONE (VLAN-ID 0)
rtl871x_set_key_ops
wlan0: interface state COUNTRY_UPDATE->ENABLED
wlan0: AP-ENABLED 
wlan0: Setup of interface done.
VLAN: RTM_NEWLINK: ifi_index=6 ifname=wlan0 ifi_family=0 ifi_flags=0x11043 ([UP][RUNNING][LOWER_UP])
VLAN: vlan_newlink(wlan0)
```

It is successful so we can replace the new path in the sysv init script:

```
root@odroid:/usr/src/hostapd-2.6/hostapd# vi /etc/init.d/hostapd
[...]
PATH=/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
#DAEMON_SBIN=/usr/sbin/hostapd
DAEMON_SBIN=/usr/local/bin/hostapd
[...]
```

and start the service using the compiled and patched binary:

```
root@odroid:/usr/src/hostapd-2.6/hostapd# service hostapd start
 * Starting advanced IEEE 802.11 management hostapd     [ OK ]
```

## Autostart

If all good, edit the `/etc/default/hostapd` file to point to the above configuration file.

```
root@odroid:~# vi /etc/default/hostapd
...
DAEMON_CONF="/etc/hostapd/hostapd.conf"
```

# DNS Caching Server Setup

To speedup the network little bit we add dns caching via `dnsmasq`.

```
root@odroid:~# dpkg-reconfigure resolvconf
```

and accept with `OK` the first 2 screens. This will create the missing symbolic link `/etc/resolv.conf -> /run/resolvconf/resolv.conf`.

```
root@odroid:~# apt-get install dnsmasq

root@odroid:~# vi /etc/dnsmasq.conf
...
domain-needed
bogus-priv
resolv-file=/etc/resolv.dnsmasq
server=192.168.1.254@eth0
server=8.8.8.8
server=8.8.4.4
interface=wlan0
cache-size=10000

# Below are settings for dhcp. Comment them out if you dont want
# dnsmasq to serve up dhcpd requests.
# dhcp-range=192.168.24.10,192.168.24.20,255.255.255.0,1440m
# dhcp-option=3,192.168.24.1
# dhcp-authoritative
```

The next file is not really needed since we put the servers in the main config but just in case. The `192.168.1.205` is my DNS server and the `192.168.1.205` is the IP of the main router (default GW):

```
root@odroid:~# vi /etc/resolv.dnsmasq
nameserver 192.168.1.205
nameserver 192.168.1.254
nameserver 8.8.8.8
nameserver 8.8.4.4
```

Start and enable the service:

```
root@odroid:~# service dnsmasq restart
 * Restarting DNS forwarder and DHCP server dnsmasq

root@odroid:~# update-rc.d dnsmasq enable
```

Now we can point our dhcp clients to our dnsmasq caching server via our dhcp server set in the next step. The gain is not huge, around 20ms per dns query in my network, but still it is an improvement.

# DHCP Server Setup

We need DHCP server for the clients connecting to the `192.168.24.0/24` wifi subnet. Install and configure `isc-dhcp-server`:

```
root@odroid:~# apt-get install isc-dhcp-server
root@odroid:~# cp /etc/dhcp/dhcpd.conf /etc/dhcp/dhcpd.conf.default
root@odroid:~# vi /etc/dhcp/dhcpd.conf
...
ddns-update-style none;
option domain-name "cicim.no-ip.org";
option domain-name-servers ns1.example.org, ns2.example.org;
default-lease-time 3600;
max-lease-time 7200;
authoritative;
log-facility local7;
subnet 192.168.24.0 netmask 255.255.255.0 {
   range 192.168.24.10 192.168.24.20;
   option broadcast-address 192.168.24.255;
   option routers 192.168.24.1;
   option domain-name "cicim.no-ip.org";
   option domain-name-servers 192.168.24.1;
   default-lease-time 3600;
   max-lease-time 7200;
}

root@odroid:~# vi /etc/default/isc-dhcp-server
...
DHCPD_CONF=/etc/dhcp/dhcpd.conf
INTERFACES="wlan0"

root@odroid:~# service isc-dhcp-server start
root@odroid:~# update-rc.d isc-dhcp-server defaults
```

# Kernel Config

Since U3 will be wireless router so we enable forwarding. I also disable IPv6 since I don't need it in this case.

```
root@odroid:~# vi /etc/sysctl.conf
...
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
vm.swappiness = 1
vm.min_free_kbytes = 8192

root@odroid:~# sysctl -p
kernel.randomize_va_space = 1
fs.file-max = 2097152
vm.min_free_kbytes = 8192
vm.swappiness = 10
vm.dirty_ratio = 60
vm.dirty_background_ratio = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 1024
net.ipv4.tcp_timestamps = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.tcp_synack_retries = 2
net.ipv4.ip_local_port_range = 2000 65535
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_keepalive_intvl = 10
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.core.rmem_default = 31457280
net.core.rmem_max = 12582912
net.core.wmem_default = 31457280
net.core.wmem_max = 12582912
net.core.somaxconn = 5000
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_window_scaling = 1
net.core.optmem_max = 25165824
net.ipv4.tcp_mem = 65536 131072 262144
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.tcp_rmem = 8192 87380 16777216
net.ipv4.udp_rmem_min = 16384
net.ipv4.tcp_wmem = 8192 65536 16777216
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_tw_recycle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
```

The rest of the settings deal with improving network performance and security.


# TOR Setup

Install is simple:

```
root@odroid:~# apt-get install tor
```

Add at the end of "/etc/tor/torrc" file:

```
SocksPort 192.168.24.1:9050
SocksPolicy accept 192.168.24.0/24
SocksPolicy reject *
OutboundBindAddress 192.168.1.206
Log notice file /var/log/tor/notices.log
RunAsDaemon 1
ORPort 9001
DirPort 9030 NoAdvertise
ExitPolicy reject *:*
Nickname Onion 
RelayBandwidthRate 100 KB  # Throttle traffic to 100KB/s (800Kbps)
RelayBandwidthBurst 200 KB # But allow bursts up to 200KB/s (1600Kbps)
```

Start the service:

```
root@odroid:~# service tor restart
```

and open port 9050 in the firewall for SOCKS proxy access:

```
root@odroid:~# iptables -A INPUT -p tcp --sport 1024:65535 --dport 9050 -i wlan0 -m state --state NEW -j ACCEPT
```

Now we can set Firefox lets say to use SOCKSv5 proxy at address 192.168.24.1 port 9050 for anonymous browsing.

# Postfix Relay Setup

We setup postfix as local MTP agent (ie only accept mails from localhost => inet_interfaces = loopback-only). Use Gmail as relay server via SASL login. We use `Procmail` for local delivery and mailboxes will go in `/var/spool/mail/`.

```
root@odroid:~# aptitude install postfix postfix-pcre libsasl2
root@odroid:~# vi /etc/postfix/main.cf 
# See /usr/share/postfix/main.cf.dist for a commented, more complete version

# Debian specific:  Specifying a file name will cause the first
# line of that file to be used as the name.  The Debian default
# is /etc/mailname.
#myorigin = /etc/mailname

smtpd_banner = $myhostname ESMTP $mail_name (Ubuntu)
biff = no

# appending .domain is the MUA's job.
append_dot_mydomain = no

# Uncomment the next line to generate "delayed mail" warnings
#delay_warning_time = 4h

readme_directory = no

# TLS parameters
smtpd_tls_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem
smtpd_tls_key_file=/etc/ssl/private/ssl-cert-snakeoil.key
smtpd_use_tls=yes
smtpd_tls_session_cache_database = btree:${data_directory}/smtpd_scache
smtp_tls_session_cache_database = btree:${data_directory}/smtp_scache

# See /usr/share/doc/postfix/TLS_README.gz in the postfix-doc package for
# information on enabling SSL in the smtp client.

smtpd_relay_restrictions = permit_mynetworks permit_sasl_authenticated defer_unauth_destination
myhostname = odroid.cicim.no-ip.org
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
myorigin = /etc/mailname
mydestination = odroid.cicim.no-ip.org, localhost.cicim.no-ip.org, localhost, odroid
mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128
mailbox_size_limit = 0
recipient_delimiter = +
inet_interfaces = loopback-only
default_transport = smtp 
relay_transport = relay 
inet_protocols = ipv4 

# procamil local delivery
home_mailbox = Mail/
mail_spool_directory = /var/spool/mail
mailbox_command = /usr/bin/procmail -f -a $USER MAILDIR=/var/spool/mail LOGFILE=/var/log/procmail.log VERBOSE=on

# relay and STARTTLS encryption
relayhost = [smtp.gmail.com]:587  
smtp_sasl_auth_enable = yes  
smtp_sasl_password_maps = hash:/etc/postfix/sasl/sasl_passwd  
smtp_sasl_security_options = noanonymous  
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
smtp_use_tls = yes
smtp_tls_loglevel = 1                                                        
smtp_tls_security_level = encrypt
smtp_tls_session_cache_database = btree:${data_directory}/smtp_scache

root@odroid:~# vi /etc/postfix/sasl/sasl_passwd
[smtp.gmail.com]:587  <MY_GMAIL_ADDRESS>:<MY_PASSWORD>

root@odroid:~# chmod 0400 /etc/postfix/sasl/sasl_passwd
root@odroid:~# postmap /etc/postfix/sasl/sasl_passwd
root@odroid:~# touch /var/log/procmail.log
root@odroid:~# chmod 666 /var/log/procmail.log
root@odroid:~# service postfix restart
```

# Firewall

Install `iptables-persistent`:

```
root@odroid:~# apt-get install iptables-persistent
```

and execute the following commands:

```
# Set Default Policy to DROP
iptables -P INPUT DROP
iptables -P OUTPUT ACCEPT
iptables -P FORWARD DROP

# Masquerade
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT

# Allow loopback and localhost access
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -s 127.0.0.1/32 -j ACCEPT

# Drop invalid pkts before reaching LISTEN socket
iptables -m state --state INVALID -j DROP

# Defense for SYN flood attacks
iptables -A INPUT -p tcp --syn -m limit --limit 5/s -i wlan0 -j ACCEPT

# Set Default Connection States - accept all already established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Open ssh from internal side only
iptables -A INPUT -p tcp --sport 1024:65535 --dport 22 -i eth0 -m state --state NEW -j ACCEPT

# Open DHCP and DNS for the ouside network
iptables -A INPUT -p udp --sport 1024:65535 -m multiport --dports 67:68 -i wlan0 -m state --state NEW -j ACCEPT
iptables -A INPUT -p tcp --sport 1024:65535 -m multiport --dports 67:68 -i wlan0 -m state --state NEW -j ACCEPT
iptables -A INPUT -p udp --sport 1024:65535 --dport 53 -i wlan0 -s 192.168.24.0/24 -m state --state NEW -j ACCEPT
iptables -A INPUT -p tcp --sport 1024:65535 --dport 53 -i wlan0 -s 192.168.24.0/24 -m state --state NEW -j ACCEPT

# TOR access
iptables -A INPUT -p tcp --sport 1024:65535 --dport 9050 -i wlan0 -s 192.168.24.0/24 -m state --state NEW -j ACCEPT

# Will be runnig web server later - access from home net only
iptables -A INPUT -p tcp --sport 1024:65535 --dport 80 -i eth0 -s 192.168.1.0/24 -m state --state NEW -j ACCEPT
iptables -A INPUT -p tcp --sport 1024:65535 --dport 443 -i eth0 -s 192.168.1.0/24 -m state --state NEW -j ACCEPT 

# Speedup DNS queries
iptables -t mangle -N FAST_DNS
iptables -t mangle -A FAST_DNS -p udp -d 192.168.1.205 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A FAST_DNS -p udp -d 8.8.8.8 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A FAST_DNS -p udp -d 8.8.4.4 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A FAST_DNS -p tcp -d 192.168.1.205 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A FAST_DNS -p tcp -d 8.8.8.8 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A FAST_DNS -p tcp -d 8.8.4.4 -j TOS --set-tos Minimize-Delay
iptables -t mangle -A OUTPUT -o eth0 -p tcp --ipv4 -s 192.168.24.1 -m pkttype --pkt-type unicast --dport domain \
-m state --state NEW,ESTABLISHED,RELATED -j FAST_DNS
iptables -t mangle -A OUTPUT -o eth0 -p udp --ipv4 -s 192.168.24.1 -m pkttype --pkt-type unicast --dport domain \
-m state --state NEW,ESTABLISHED,RELATED -j FAST_DNS
```

Save the config:

```
root@odroid:~# iptables-save > /etc/network/firewall.rules
```

and add at the end of the `/etc/network/interfaces.d/eth0` file so it loads up upon restart:

```
up iptables-restore < /etc/network/firewall.rules
```
