---
type: posts
header:
  teaser: '488564370.jpg'
title: 'IPSec VPN server setup in Amazon VPC with OpenSwan'
categories: 
  - DevOps
tags: [aws, vpn]
date: 2014-3-12
---
{% include toc %}
The access to our Amazon VPC's atm is based on ssh key pairs. While this is working fine and is pretty much secure it requires though each EC2 instance having public subnet interface which is not always desired. Usually the service layout is vertically divided in tiers with only LB's and some application servers on the top being publicly accessible while the rest of them are private subnets only like application servers, databases, shared storage etc, thus keeping the public and private traffic separated. Also sometimes a situation may arise when we need access to a VPC but we don't have the access keys on us or we need to access via untrusted wireless network. For this reasons setting up a VPN instance to allow clients, so called `road worriers`, to connect becomes necessity.

# Overview

The VPN server setup will be on EC2 micro instance so monthly costs for running this server are around $5. It will be IPsec/L2TP VPN server which offers high security.

In short, the following are the key elements of the setup:

* OS = Ubuntu 12.04 Server LTS
* Kernel = 3.2.0-59-virtual
* L2TP daemon = xl2tpd 1.3.1
* IPsec Implementation = Openswan 2.6.37-1
* IPsec Stack = Netkey (26sec) - (supplied as part of Kernel 2.6)
* IKE / Key management daemon = pluto - (supplied as part of `Openswan`)

I'm going to give a short description of each of the parts involved here.

`xl2tpd`: is a Layer 2 Tunneling Protocol (L2TP) used to support virtual private networks (VPNs) (RFC2661). `L2TP` facilitates the tunneling of Point-to-Point Protocol (PPP) packets across an intervening network in a way that is as transparent as possible to both end-users and applications. The main purpose of this protocol is to tunnel PPP frames through IP networks using the Link Control Protocol (LCP) which is responsible for establishing, maintaining and terminating the PPP connection. L2TP does not provide any encryption or confidentiality itself; it relies on an encryption protocol to encrypt the tunnel and provide privacy, hence L2TP is used with `IPSec` that provides the encryption

`Openswan`: is a set of tools for doing IPsec on Linux operating systems. The tool-set consists of three major components:

* configuration tools
* key management tools (aka `pluto` )
* kernel components (KLIPS and sec)

`pluto`: is the key management daemon, it is an IPsec Key Exchange (IKE) daemon. `IKE's` Job is to to negotiate Security Associations for the node it is deployed on. A Security Association (SA) is an agreement between two network nodes on how to process certain traffic between them. This process involves encapsulation, authentication, encryption, or compression.

`netkey`: is the name of the IPSec `stack` in the 2.6 kernel used to encrypt the PPP packets over the L2TP tunnel. `Netkey` is a relatively new IPsec stack is based on the KAME stack from BSD. Netkey is also referred to as `26sec` or `native` stack. Netkey supports both IPv4 and IPv6.

`pppd`: is the Point-to-Point Protocol daemon which is used to manage network connections between two nodes. Specifically `pppd` sets up the transport for IP traffic within the L2TP tunnel for the VPN.

`VPN client`: any pc, mobile device or network using an IPsec PSK tunnel with the `l2tp` secret enabled. The client can also support PPTP, basic L2TP and also certificate based authentication.

# Server installation and setup

## Installation

Installation is fairly simple, we just run:

```
root@vpn-server:~# aptitude install -y openswan xl2tpd
```

## IPsec configuration

We take backup of the ipsec config file `/etc/ipsec.conf` and modify it as follows:

```
version 2.0
 
config setup
  dumpdir=/var/run/pluto/
  nat_traversal=yes
  virtual_private=%v4:10.0.0.0/8,%v4:192.168.0.0/16,%v4:172.16.0.0/12,%v4:25.0.0.0/8,%v6:fd00::/8,%v6:fe80::/10
  oe=off
  protostack=netkey
  nhelpers=0
  interfaces=%defaultroute
  #plutodebug=all
 
conn vpnpsk
  auto=add
  left=172.31.12.198
  leftid=<my-vpn-server-dns>
  leftsubnet=172.31.12.198/32
  leftnexthop=%defaultroute
  leftprotoport=17/1701
  rightprotoport=17/%any
  right=%any
  rightsubnetwithin=0.0.0.0/0
  forceencaps=yes
  authby=secret
  pfs=no
  type=transport
  auth=esp
  ike=3des-sha1
  phase2alg=3des-sha1
  dpddelay=30
  dpdtimeout=120
  dpdaction=clear
```

Important thing here is that the `leftid` needs to be pointing to the public IP (EIP of the EC2 instance) or the DNS name as in my case that is hosted in Route53.

Next we create random hard to guess PSK key (the one given below is not the one I used for the server of course):

```
root@vpn-server:~# ipsec ranbits --continuous 128
0xe37ef1c5f42eb7dde93a974a5dcc7b2c
```

Then we use this password key in the secrets file `/etc/ipsec.secrets`:

```
<my-vpn-server-dns> %any  : PSK "0xe37ef1c5f42eb7dde93a974a5dcc7b2c"
```

This line translated say any client connected to this host (<my-vpn-server-dns>) should use this password as shared key. If we have created this for first time we need to set proper permissions:

```
root@vpn-server:~# chmod 600 /etc/ipsec.secrets
```

## CHAP authentication

The CHAP authentication file `/etc/ppp/chap-secrets` is where we put our users and their credentials.

```
# Secrets for authentication using CHAP
# client    server  secret          IP addresses
 
<my-user>    l2tpd   <my-password>   *
<my-user-2>  l2tpd   <my-password-2>   192.168.42.41
```

We have two users here with their user name and password. The last parameter in the line specifies the ip address the client should get upon successful connection. The first user will simply get the first available ip from the pool specified in the xl2tpd configuration in the next step. If we have created this for first time we need to set proper permissions:

```
root@vpn-server:~# chmod 0600 /etc/ppp/chap-secrets
```

## XL2TPD daemon

There two configuration files we need to setup here, first is `/etc/xl2tpd/xl2tpd.conf`.

```
[global]
port = 1701
 
;debug avp = yes
;debug network = yes
;debug state = yes
;debug tunnel = yes
 
[lns default]
ip range = 192.168.42.10-192.168.42.250
local ip = 192.168.42.1
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
;ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
/etc/ppp/options.xl2tpd
ipcp-accept-local
ipcp-accept-remote
ms-dns 8.8.8.8
ms-dns 8.8.4.4
noccp
auth
crtscts
idle 1800
mtu 1280
mru 1280
lock
connect-delay 5000
```

## Firewall

We need to open TCP port 500, and UDP ports 500 (IKE), 1701 (L2TP) and 4500 (NAT-T) in the EC2 instance security group. On the server it self we need to set iptables for the ppp0 interface and the network the clients will get their ip's from:

```
root@vpn-server:~# iptables -t nat -A POSTROUTING -s 192.168.42.0/24 -o eth0 -j MASQUERADE
root@vpn-server:~# iptables -A FORWARD -i eth0 -o ppp0 -m state --state RELATED,ESTABLISHED -j ACCEPT
root@vpn-server:~# iptables -A FORWARD -i ppp0 -o eth0 -j ACCEPT
```

To make this rules persist over reboots we need to install `iptables-persistent` package:

```
root@vpn-server:~# aptitude install iptables-persistent
```

## Configure the kernel

Append the following to the end of the kernel config file.

```
net.ipv4.ip_forward=1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.lo.accept_redirects = 0
net.ipv4.conf.lo.secure_redirects = 0
net.ipv4.conf.lo.send_redirects = 0
net.ipv4.conf.eth0.accept_redirects = 0
net.ipv4.conf.eth0.secure_redirects = 0
net.ipv4.conf.eth0.send_redirects = 0
```

save the file and make the rules effective:

```
root@vpn-server:~# sysctl -p
```

Final check

```
root@vpn-server:~# ipsec verify
Checking your system to see if IPsec got installed and started correctly:
Version check and ipsec on-path                                 [OK]
Linux Openswan U2.6.37/K3.2.0-58-virtual (netkey)
Checking for IPsec support in kernel                            [OK]
 SAref kernel support                                           [N/A]
 NETKEY:  Testing XFRM related proc values                      [OK]
    [OK]
    [OK]
Checking that pluto is running                                  [OK]
 Pluto listening for IKE on udp 500                             [OK]
 Pluto listening for NAT-T on udp 4500                          [OK]
Two or more interfaces found, checking IP forwarding            [OK]
Checking NAT and MASQUERADEing                                  [OK]
Checking for 'ip' command                                       [OK]
Checking /bin/sh is not /bin/dash                               [WARNING]
Checking for 'iptables' command                                 [OK]
Opportunistic Encryption Support                                [DISABLED]
```

All is ok so now we can start the services and go on with client configuration.

```
root@vpn-server:~# /etc/init.d/ipsec restart
root@vpn-server:~# /etc/init.d/xl2tpd restart
 
root@vpn-server:~# ifconfig ppp0
ppp0      Link encap:Point-to-Point Protocol
          inet addr:192.168.42.1  P-t-P:192.168.42.10  Mask:255.255.255.255
          UP POINTOPOINT RUNNING NOARP MULTICAST  MTU:1280  Metric:1
          RX packets:10809 errors:0 dropped:0 overruns:0 frame:0
          TX packets:10375 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:3
          RX bytes:2054854 (2.0 MB)  TX bytes:3895668 (3.8 MB)
```

# Clients setup

## Linux

Installing the client is fairly simple:

```
$ sudo aptitude install l2tp-ipsec-vpn
```

Then either launch the `L2TP ipces VPM Manager` from the Application menu or enable the L2TP applet as shown on the screen shot and click on it.

This basically does the following: 

Adds the shared key to ipsec secrets file `/etc/ipsec.secrets`:

```
%any @<my-vpn-server-dns>: PSK 0t0xe37ef1c5f42eb7dde93a974a5dcc7b2c
```

Adds the connection to the xl2tpd conf file `/etc/xl2tpd/xl2tpd.conf`:

```
[lac SAI_VPC_AU]
lns = <my-vpn-server-dns>
pppoptfile = /etc/ppp/SAI_VPC_AU.options.xl2tpd
length bit = yes
redial = no
```

And sets the user credentials in the `/etc/ppp/SAI_VPC_AU.options.xl2tpd` file

> This app has bug in the Ubuntu 12.04 version that doesn't exist in 10.04, 11.04 or 11.10. The user password is not passed on during the connection and workaround is to set it manually in the `/etc/ppp/SAI_VPC_AU.options.xl2tpd` file.

So right after name line we add password line as shown below in the `/etc/ppp/SAI_VPC_AU.options.xl2tpd` file:

```
# /etc/ppp/SAI_VPC_AU.options.xl2tpd - Options used by PPP when a connection is made by an L2TP daemon
# $Id$
 
# Manual: PPPD(8)
 
# Created: Sun Mar 9 16:54:40 2014
#      by: The L2TP IPsec VPN Manager application version 1.0.6
#
# WARNING! All changes made in this file will be lost!
 
#debug
#dump
#record /var/log/pppd
 
plugin passprompt.so
ipcp-accept-local
ipcp-accept-remote
idle 72000
ktune
noproxyarp
asyncmap 0
noauth
crtscts
lock
hide-password
modem
noipx
 
ipparam L2tpIPsecVpn-SAI_VPC_AU
 
promptprog "/usr/bin/L2tpIPsecVpn"
 
refuse-eap
refuse-pap
refuse-mschap
refuse-mschap-v2
 
remotename ""
name "<my-user>"
password "<my-password>"
 
usepeerdns
```

Bad news is that when ever we use this VPN Manager again it will overwrite our changes and we'll have to do it over again.

The log file from the server showing the session being successfully established:

```
Mar  8 11:00:28 ip-172-31-12-198 xl2tpd[23625]: Connection established to <my-public-ip-reducted>, 1701.  Local: 49762, Remote: 50824 (ref=0/0).  LNS session is 'default'
Mar  8 11:00:28 ip-172-31-12-198 xl2tpd[23625]: control_finish: Warning: Peer did not specify transmit speed
Mar  8 11:00:28 ip-172-31-12-198 xl2tpd[23625]: start_pppd: I'm running:
Mar  8 11:00:28 ip-172-31-12-198 xl2tpd[23625]: "/usr/sbin/pppd"
Mar  8 11:00:28 ip-172-31-12-198 xl2tpd[23625]: "passive"
Mar  8 11:00:28 ip-172-31-12-198 xl2tpd[23625]: "nodetach"
Mar  8 11:00:28 ip-172-31-12-198 xl2tpd[23625]: "192.168.42.1:192.168.42.10"
Mar  8 11:00:28 ip-172-31-12-198 xl2tpd[23625]: "refuse-pap"
Mar  8 11:00:28 ip-172-31-12-198 xl2tpd[23625]: "auth"
Mar  8 11:00:28 ip-172-31-12-198 xl2tpd[23625]: "require-chap"
Mar  8 11:00:28 ip-172-31-12-198 xl2tpd[23625]: "name"
Mar  8 11:00:28 ip-172-31-12-198 xl2tpd[23625]: "l2tpd"
Mar  8 11:00:28 ip-172-31-12-198 xl2tpd[23625]: "file"
Mar  8 11:00:28 ip-172-31-12-198 xl2tpd[23625]: "/etc/ppp/options.xl2tpd"
Mar  8 11:00:28 ip-172-31-12-198 xl2tpd[23625]: "ipparam"
Mar  8 11:00:28 ip-172-31-12-198 xl2tpd[23625]: "<my-public-ip-reducted>"
Mar  8 11:00:28 ip-172-31-12-198 xl2tpd[23625]: "/dev/pts/3"
Mar  8 11:00:28 ip-172-31-12-198 xl2tpd[23625]: Call established with <my-public-ip-reducted>, Local: 32087, Remote: 16751, Serial: 1
Mar  8 11:00:28 ip-172-31-12-198 pppd[23907]: pppd 2.4.5 started by root, uid 0
Mar  8 11:00:28 ip-172-31-12-198 pppd[23907]: Using interface ppp0
Mar  8 11:00:28 ip-172-31-12-198 pppd[23907]: Connect: ppp0 <--> /dev/pts/3
Mar  8 11:00:28 ip-172-31-12-198 pppd[23907]: local  IP address 192.168.42.1
Mar  8 11:00:28 ip-172-31-12-198 pppd[23907]: remote IP address 192.168.42.10
```

Then I was able to connect to one of the servers in the VPC from my pc by simply using its private ip:

```
igorc@silverstone:~$ ssh ubuntu@172.31.18.41
The authenticity of host '172.31.18.41 (172.31.18.41)' can't be established.
ECDSA key fingerprint is d2:93:cd:e5:cc:6c:45:52:76:09:34:bf:6f:a4:fc:9d.
Are you sure you want to continue connecting (yes/no)? yes
Warning: Permanently added '172.31.18.41' (ECDSA) to the list of known hosts.
ubuntu@172.31.18.41's password:
Welcome to Ubuntu 12.04.2 LTS (GNU/Linux 3.2.0-49-virtual x86_64)
 
 * Documentation:  https://help.ubuntu.com/
 
  System information as of Sat Mar  8 22:04:24 EST 2014
 
  System load:  0.16              Processes:           113
  Usage of /:   84.2% of 7.87GB   Users logged in:     0
  Memory usage: 50%               IP address for eth0: 172.31.18.41
  Swap usage:   0%                IP address for eth1: 172.31.51.41
 
  Graph this data and manage this system at https://landscape.canonical.com/
 
159 packages can be updated.
81 updates are security updates.
 
Get cloud support with Ubuntu Advantage Cloud Guest
  http://www.ubuntu.com/business/services/cloud
 
Use Juju to deploy your cloud instances and workloads.
  https://juju.ubuntu.com/#cloud-precise
*** /dev/xvda1 will be checked for errors at next reboot ***
 
You have new mail.
Last login: Thu Mar  6 15:25:36 2014 from <my-public-ip-reducted>
ubuntu@ip-172-31-18-41:~$
```

If we prefer to do the things manually, the start step-by-step (without applet) would be:

```
root@igor-laptop:~# service xl2tpd restart
root@igor-laptop:~# service ipsec restart
root@igor-laptop:~# ipsec auto --add SAI_VPC_AU
root@igor-laptop:~# ipsec auto --up SAI_VPC_AU
root@igor-laptop:~# echo "c SAI_VPC_AU" > /var/run/xl2tpd/l2tp-control
```

Then to end the VPN connection:

```
root@igor-laptop:~# ipsec auto --down SAI_VPC_AU
root@igor-laptop:~# echo "d SAI_VPC_AU" > /var/run/xl2tpd/l2tp-control
root@igor-laptop:~# service ipsec stop
root@igor-laptop:~# service xl2tpd stop
```

## Mac

Open your network settings:

* Click on the `+` button in the top-left corner of the interfaces list
* Select a VPN interface, with `IPSec L2TP` and give it a name
* In the address field, put the public IP of our VPN server (you can get it via `nslookup`)
* In the account name field, put the value of the VPN_USER variable that you defined earlier.
* Click on auth settings, fill your VPN_PASSWORD in the first field and your IPSEC_PSK in the second box. Click Ok
* Click on Advanced Settings, select "Send all traffic" and click ok.
* If you are running firewall then make sure the appropriate ports are not blocked (see the Firewall section)
