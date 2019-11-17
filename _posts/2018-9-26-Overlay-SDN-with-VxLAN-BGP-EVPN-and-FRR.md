---
type: posts
header:
  teaser: 'docker-logo-2.png'
title: 'Overlay SDN with VxLAN, BGP-EVPN and FRR'
categories: 
  - Virtualization
tags: ['vxlan','bgp','evpn']
date: 2018-9-26
---

In BGP based control plane for Vxlan, E-VPN plays the role of a distributed controller for layer-2 network virtualization. BGP is the routing protocol of the internet but it also finds its role as an Internal Border Gateway Protocol (iBGP) which is a term used to describe an area of BGP operation that runs within an organization or autonomous system. A typical BGP implementation on Linux installs routes kernel FIB on the host. With E-VPN, we are telling BGP to also look at layer-2 forwarding entries in the kernel and distribute to peers.

BGP runs on each VTEP and peers with BGP on other VTEPs. It exchanges local Mac and Mac/IP routes with peers, exchanges VNIs each VTEP is interested in, tracks mac address moves for faster convergence. The information exchanged is tagged by Route types: 
* MAC or MAC-IP routes are Type 2 routes
* BUM replication list exchanged via Type 3 routes

On Ubuntu we need HWE 4.15+ kernel for this to work.

```
$ sudo apt install linux-image-generic-hwe-16.04
```

There are 3 Ubuntu-16.04 nodes networked on 192.168.0.0/24 LAN. The xenial01 and xenial02 are setup as RR and xenial03 as VTEP.

# FRR Setup

## Installation

```
sudo wget http://repo3.cumulusnetworks.com/repo/pool/cumulus/f/frr/frr_4.0%2Bcl3u6_amd64.deb
sudo apt install python-ipaddr libsnmp30 libsnmp-base
sudo dpkg -i frr_4.0+cl3u6_amd64.deb 

sudo vi /etc/frr/daemons
[...]
zebra=yes
bgpd=yes
ospfd=no
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no

sudo systemctl restart frr
sudo systemctl status -l frr.service
 frr.service - FRRouting
   Loaded: loaded (/lib/systemd/system/frr.service; enabled; vendor preset: enabled)
   Active: active (running) since Mon 2018-10-29 13:07:25 AEDT; 9 months 6 days ago
    Tasks: 5
   Memory: 2.6M
      CPU: 4h 34min 18.048s
   CGroup: /system.slice/frr.service
           ├─1649 /usr/lib/frr/zebra -M snmp -s 90000000 --daemon -A 127.0.0.1
           ├─1671 /usr/lib/frr/bgpd -M snmp --daemon -A 127.0.0.1
           └─1679 /usr/lib/frr/watchfrr -d -r /usr/sbin/servicebBfrrbBrestartbB%s -s /usr/sbin/servicebBfrrbBstartbB%s -k /usr/sbin/servicebBfrrbBstopbB%s -b bB zebra bgpd
```

Some package info:

```
$ sudo dpkg -l | grep frr
ii  frr  4.0+cl3u6  amd64  BGP/OSPF/RIP/RIPng/ISIS/PIM/LDP routing daemon forked from Quagga

$ cat /lib/systemd/system/frr.service 
[Unit]
Description=FRRouting
After=networking.service
OnFailure=heartbeat-failed@%n.service

[Service]
Nice=-5
EnvironmentFile=/etc/default/frr
Type=forking
NotifyAccess=all
StartLimitInterval=3m
StartLimitBurst=3
TimeoutSec=2m
WatchdogSec=60s
RestartSec=5
Restart=on-abnormal
LimitNOFILE=1024
ExecStart=/usr/lib/frr/frr start
ExecStop=/usr/lib/frr/frr stop
ExecReload=/usr/lib/frr/frr-reload.py --reload /etc/frr/frr.conf

[Install]
WantedBy=network-online.target
```

To compile from sources:

```
sudo apt install autoconf automake pkg-config libreadline-dev libjson0-dev libc-ares-dev flex bison
git clone https://github.com/frrouting/frr.git frr
cd frr/
git checkout master
./bootstrap.sh 
./configure --enable-exampledir=/usr/share/doc/frr/examples/ \
--localstatedir=/var/run/frr --sbindir=/usr/lib/frr --sysconfdir=/etc/frr \
--enable-vtysh --enable-isisd --enable-pimd --enable-watchfrr \
--enable-ospfclient=yes --enable-ospfapi=yes --enable-multipath=64 \
--enable-user=frr --enable-group=frr --enable-vty-group=frrvty \
--enable-configfile-mask=0640 --enable-logfile-mask=0640 --enable-rtadv \
--enable-fpm --enable-ldpd --enable-cumulus --with-pkg-git-version
make && sudo make install
```

# Configuration

First the FRR config on the Route Reflectors:

```
root@xenial01:~# cat /etc/frr/frr.conf
frr version 6.1-dev
frr defaults traditional
hostname xenial01
no ip forwarding
no ipv6 forwarding
service integrated-vtysh-config
username cumulus nopassword
!
router bgp 65000
 bgp router-id 192.168.0.136
 !no bgp default ipv4-unicast
 bgp cluster-id 192.168.0.136
 coalesce-time 1000
 neighbor fabric peer-group
 neighbor fabric remote-as 65000
 neighbor fabric update-source 192.168.0.136
 neighbor fabric capability extended-nexthop
 bgp listen range 192.168.0.0/24 peer-group fabric
 !
 address-family l2vpn evpn
  neighbor fabric activate
  neighbor fabric route-reflector-client
 exit-address-family
 rfp full-table-download off
!
line vty
!
```

```
root@xenial02:~# cat /etc/frr/frr.conf
frr version 4.0+cl3u6
frr defaults datacenter
hostname xenial02
no ip forwarding
no ipv6 forwarding
username cumulus nopassword
!
service integrated-vtysh-config
!
log syslog informational
!
router bgp 65000
 bgp router-id 192.168.0.138
 no bgp default ipv4-unicast
 bgp cluster-id 192.168.0.138
 neighbor fabric peer-group
 neighbor fabric remote-as 65000
 neighbor fabric update-source 192.168.0.138
 neighbor fabric capability extended-nexthop
 bgp listen range 192.168.0.0/24 peer-group fabric
 !
 address-family ipv4 unicast
  neighbor fabric route-reflector-client
 exit-address-family
 !
 address-family l2vpn evpn
  neighbor fabric activate
 exit-address-family
!
line vty
!
```

And then the VTEP node:

```
root@xenial03:~# cat /etc/frr/frr.conf
frr version 4.0+cl3u6
frr defaults datacenter
hostname xenial03
no ip forwarding
no ipv6 forwarding
username cumulus nopassword
!
service integrated-vtysh-config
!
log syslog informational
!
log file /var/log/frr/zebra.log
debug zebra vxlan
debug bgp zebra
!
router bgp 65000
 bgp router-id 192.168.0.139
 no bgp default ipv4-unicast
 neighbor fabric peer-group
 neighbor fabric remote-as 65000
 neighbor fabric capability extended-nexthop
 neighbor 192.168.0.136 peer-group fabric
 neighbor 192.168.0.138 peer-group fabric
 !
 address-family l2vpn evpn
  neighbor fabric activate
  advertise-all-vni
  advertise-default-gw
 exit-address-family
!
line vty
!
```

## VTEP Configuration

On the VTEP node xenial03:

```bash
for vni in 100 200; do
   ip link add vxlan${vni} type vxlan\
   id ${vni}\
   dstport 4789\
   local 192.168.0.139\
   nolearning

   brctl addbr br${vni};
   brctl addif br${vni} vxlan${vni};
   brctl stp br${vni} off;
   ip link set up dev br${vni};
   ip link set up dev vxlan${vni}; 
done

ip tuntap add tap03 mode tap
ip addr add 10.10.10.100/24 dev tap03
ip link set dev tap03 up
brctl addif br100 tap03

ip tuntap add tap02 mode tap
ip addr add 10.10.10.101/24 dev tap02
ip link set dev tap02 up
brctl addif br100 tap02

ip tuntap add tap01 mode tap
ip addr add 10.10.20.100 dev tap01
ip link set up dev tap01
ip link set dev tap01 master br200
```

Optionaly start some KVM instances:

```bash
qemu-system-i386 -m 64 -netdev tap,id=t0,ifname=tap03,script=no,downscript=no \
-device e1000,netdev=t0,id=nic0,mac=52:54:be:ef:e9:08 -boot n -daemonize -vga none -vnc :6
qemu-system-i386 -m 64 -netdev tap,id=t0,ifname=tap02,script=no,downscript=no \
-device e1000,netdev=t0,id=nic0,mac=52:54:be:ef:e9:07 -boot n -daemonize -vga none -vnc :5
qemu-system-i386 -m 64 -netdev tap,id=t0,ifname=tap01,script=no,downscript=no \
-device e1000,netdev=t0,id=nic0,mac=52:54:be:ef:e9:06 -boot n -daemonize -vga none -vnc :4
```

The bridge and attached network devices layout now looks like this:

```bash
root@xenial03:~# brctl show
bridge name bridge id   STP enabled interfaces
br100   8000.c2dba7f4b8a8 no    tap02
                                tap03
                                vxlan100
br200   8000.36fc97568789 no    tap01
                                vxlan200
```

This node is connected to 3 networks, one "public" (with internet GW) and two private.

```bash
# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
auto ens18
iface ens18 inet static
    address 192.168.0.139
    netmask 255.255.255.0
    network 192.168.0.0
    broadcast 192.168.0.255
    gateway 192.168.0.1
    dns-nameservers 192.168.0.1 8.8.8.8
    search local.tld
    metric 100

auto ens19
iface ens19 inet dhcp
    metric 200

auto ens20
iface ens20 inet dhcp
    metric 200
```

```bash
root@xenial03:~# ip r show
default via 192.168.0.1 dev ens18  metric 100 onlink 
default via 10.20.1.1 dev ens20  metric 200 
10.10.1.0/24 dev ens19  proto kernel  scope link  src 10.10.1.10
10.20.1.0/24 dev ens20  proto kernel  scope link  src 10.20.1.13 
192.168.0.0/24 dev ens18  proto kernel  scope link  src 192.168.0.139
```

# Vtysh printouts

```bash
xenial03# show bgp l2vpn evpn vni
Advertise Gateway Macip: Enabled
Advertise All VNI flag: Enabled
Number of L2 VNIs: 2
Number of L3 VNIs: 0
Flags: * - Kernel
  VNI        Type RD                    Import RT                 Export RT                 Tenant VRF                           
* 100        L2   192.168.0.139:2       65000:100                 65000:100                default                              
* 200        L2   192.168.0.139:3       65000:200                 65000:200                default

xenial03# show bgp l2vpn evpn summary
BGP router identifier 192.168.0.139, local AS number 65000 vrf-id 0
BGP table version 0
RIB entries 3, using 456 bytes of memory
Peers 2, using 39 KiB of memory
Peer groups 1, using 64 bytes of memory

Neighbor                V         AS  MsgRcvd MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd
xenial01(192.168.0.136) 4      65000  776817  776813        0    0    0  03w1d11h            0
xenial02(192.168.0.138) 4      65000  776795  776813        0    0    0  03w1d11h            0

Total number of neighbors 2
```

Probably the most important one:

```bash
xenial03# show bgp evpn route
BGP table version is 2, local router ID is 192.168.0.139
Status codes: s suppressed, d damped, h history, * valid, > best, i - internal
Origin codes: i - IGP, e - EGP, ? - incomplete
EVPN type-2 prefix: [2]:[ESI]:[EthTag]:[MAClen]:[MAC]:[IPlen]:[IP]
EVPN type-3 prefix: [3]:[EthTag]:[IPlen]:[OrigIP]
EVPN type-5 prefix: [5]:[ESI]:[EthTag]:[IPlen]:[IP]

   Network          Next Hop            Metric LocPrf Weight Path
Route Distinguisher: 192.168.0.139:2
*> [2]:[0]:[0]:[48]:[ea:63:21:d8:0e:fa]:[128]:[fe80::e863:21ff:fed8:efa]
                    192.168.0.139                      32768 i
*> [3]:[0]:[32]:[192.168.0.139]
                    192.168.0.139                      32768 i
Route Distinguisher: 192.168.0.139:3
*> [2]:[0]:[0]:[48]:[f2:ce:a3:32:9c:af]:[128]:[fe80::f0ce:a3ff:fe32:9caf]
                    192.168.0.139                      32768 i
*> [3]:[0]:[32]:[192.168.0.139]
                    192.168.0.139                      32768 i
```

We can see the L2 and L3 routes learned.

```bash
xenial03# show bgp evpn vni
Advertise Gateway Macip: Enabled
Advertise All VNI flag: Enabled
Number of L2 VNIs: 2
Number of L3 VNIs: 0
Flags: * - Kernel
  VNI        Type RD                    Import RT                 Export RT                 Tenant VRF                           
* 100        L2   192.168.0.139:2       65000:100                 65000:100                default                              
* 200        L2   192.168.0.139:3       65000:200                 65000:200                default                             

xenial03# show ip route
Codes: K - kernel route, C - connected, S - static, R - RIP,
       O - OSPF, I - IS-IS, B - BGP, E - EIGRP, N - NHRP,
       T - Table, v - VNC, V - VNC-Direct, A - Babel, D - SHARP,
       F - PBR,
       > - selected route, * - FIB route

K * 0.0.0.0/0 [0/200] via 10.20.1.1, ens20, 00:42:43
K>* 0.0.0.0/0 [0/100] via 192.168.0.1, ens18, 00:42:43
C>* 10.10.1.0/24 is directly connected, ens19, 00:42:43
C>* 10.20.1.0/24 is directly connected, ens20, 00:42:43
C>* 192.168.0.0/24 is directly connected, ens18, 00:42:43
```

On each VTEP, FRR should be able to retrieve the information about configured VXLANs and the local MAC addresses.

```bash
xenial03# show interface vxlan100
Interface vxlan100 is up, line protocol is up
  Link ups:       1    last: 2018/10/29 13:32:21.87
  Link downs:     0    last: (never)
  PTM status: disabled
  vrf: default
  index 10 metric 0 mtu 1500 speed 0 
  flags: <UP,BROADCAST,RUNNING,MULTICAST>
  Type: Unknown
  HWaddr: ea:63:21:d8:0e:fa
  inet6 fe80::e863:21ff:fed8:efa/64
  Interface Type Vxlan
  VxLAN Id 100 VTEP IP: 192.168.0.139 Access VLAN Id 1
  Master (bridge) ifindex 11             1    

xenial03# show interface vxlan200
Interface vxlan200 is up, line protocol is up
  Link ups:       1    last: 2018/10/29 13:32:21.92
  Link downs:     0    last: (never)
  PTM status: disabled
  vrf: default
  index 12 metric 0 mtu 1500 speed 0 
  flags: <UP,BROADCAST,RUNNING,MULTICAST>
  Type: Unknown
  HWaddr: f2:ce:a3:32:9c:af
  inet6 fe80::f0ce:a3ff:fe32:9caf/64
  Interface Type Vxlan
  VxLAN Id 200 VTEP IP: 192.168.0.139 Access VLAN Id 1
  Master (bridge) ifindex 13

xenial03#  show evpn mac vni all

VNI 100 #MACs (local and remote) 1

MAC               Type   Intf/Remote VTEP      VLAN 
ea:63:21:d8:0e:fa local  br100                 1    

VNI 200 #MACs (local and remote) 1

MAC               Type   Intf/Remote VTEP      VLAN 
f2:ce:a3:32:9c:af local  br200                 1 
```

FRR log on restart:

```
2018/10/29 13:32:21 ZEBRA: Add L2-VNI 100 VRF Default intf vxlan100(10) VLAN 0 local IP 192.168.0.139 master 0
2018/10/29 13:32:21 BGP: Rx Intf add VRF 0 IF vxlan100
2018/10/29 13:32:21 ZEBRA: Update L2-VNI 100 intf vxlan100(10) VLAN 0 local IP 192.168.0.139 master 11 chg 0x2
2018/10/29 13:32:21 ZEBRA: Update L2-VNI 100 intf vxlan100(10) VLAN 1 local IP 192.168.0.139 master 11 chg 0x4
2018/10/29 13:32:21 BGP: Rx Intf add VRF 0 IF br100
2018/10/29 13:32:21 ZEBRA: Intf vxlan100(10) L2-VNI 100 is UP
2018/10/29 13:32:21 ZEBRA: Send VNI_ADD 100 192.168.0.139 tenant vrf default to bgp
2018/10/29 13:32:21 ZEBRA: Reading MAC FDB and Neighbors for intf vxlan100(10) VNI 100 master 11
2018/10/29 13:32:21 BGP: Rx Intf up VRF 0 IF vxlan100
2018/10/29 13:32:21 BGP: Rx VNI add VRF default VNI 100 tenant-vrf default
2018/10/29 13:32:21 ZEBRA: SVI br100(11) VNI 100 VRF default is UP, installing neighbors
2018/10/29 13:32:21 ZEBRA: Send VNI_ADD 100 192.168.0.139 tenant vrf default to bgp
2018/10/29 13:32:21 ZEBRA: EVPN gateway macip Adv disabled on VNI 100 , currently enabled
2018/10/29 13:32:21 BGP: Rx Intf up VRF 0 IF br100
2018/10/29 13:32:21 BGP: Rx VNI add VRF default VNI 100 tenant-vrf default
2018/10/29 13:32:21 ZEBRA: Add L2-VNI 200 VRF Default intf vxlan200(12) VLAN 0 local IP 192.168.0.139 master 0
2018/10/29 13:32:21 BGP: Rx Intf add VRF 0 IF vxlan200
2018/10/29 13:32:21 BGP: Rx Intf add VRF 0 IF br200
2018/10/29 13:32:21 ZEBRA: Update L2-VNI 200 intf vxlan200(12) VLAN 0 local IP 192.168.0.139 master 13 chg 0x2
2018/10/29 13:32:21 ZEBRA: Update L2-VNI 200 intf vxlan200(12) VLAN 1 local IP 192.168.0.139 master 13 chg 0x4
2018/10/29 13:32:21 BGP: Rx Intf up VRF 0 IF br200
2018/10/29 13:32:21 ZEBRA: Intf vxlan200(12) L2-VNI 200 is UP
2018/10/29 13:32:21 ZEBRA: Send VNI_ADD 200 192.168.0.139 tenant vrf default to bgp
2018/10/29 13:32:21 ZEBRA: Reading MAC FDB and Neighbors for intf vxlan200(12) VNI 200 master 13
2018/10/29 13:32:21 BGP: Rx Intf up VRF 0 IF vxlan200
2018/10/29 13:32:21 BGP: Rx VNI add VRF default VNI 200 tenant-vrf default
2018/10/29 13:32:21 ZEBRA: EVPN gateway macip Adv disabled on VNI 200 , currently enabled
2018/10/29 13:32:21 BGP: Rx Intf up VRF 0 IF br200
2018/10/29 13:32:23 ZEBRA: SVI br100(11) L2-VNI 100, sending GW MAC ea:63:21:d8:0e:fa IP fe80::e863:21ff:fed8:efa add to BGP with flags 0x19
2018/10/29 13:32:23 ZEBRA: Send MACIP Add flags 0x6 MAC ea:63:21:d8:0e:fa IP fe80::e863:21ff:fed8:efa seq 0 L2-VNI 100 to bgp
2018/10/29 13:32:23 BGP: 0:Recv MACIP Add flags 0x6 MAC ea:63:21:d8:0e:fa IP fe80::e863:21ff:fed8:efa VNI 100 seq 0
2018/10/29 13:32:23 BGP: Rx Intf address add VRF 0 IF br100 addr fe80::e863:21ff:fed8:efa/64
2018/10/29 13:32:23 ZEBRA: SVI br200(13) L2-VNI 200, sending GW MAC f2:ce:a3:32:9c:af IP fe80::f0ce:a3ff:fe32:9caf add to BGP with flags 0x19
2018/10/29 13:32:23 ZEBRA: Send MACIP Add flags 0x6 MAC f2:ce:a3:32:9c:af IP fe80::f0ce:a3ff:fe32:9caf seq 0 L2-VNI 200 to bgp
2018/10/29 13:32:23 BGP: 0:Recv MACIP Add flags 0x6 MAC f2:ce:a3:32:9c:af IP fe80::f0ce:a3ff:fe32:9caf VNI 200 seq 0
2018/10/29 13:32:23 BGP: Rx Intf address add VRF 0 IF br200 addr fe80::f0ce:a3ff:fe32:9caf/64
2018/10/29 13:32:23 BGP: Rx Intf address add VRF 0 IF vxlan200 addr fe80::f0ce:a3ff:fe32:9caf/64
2018/10/29 13:32:23 BGP: Rx Intf address add VRF 0 IF vxlan100 addr fe80::e863:21ff:fed8:efa/64
2018/10/29 13:32:37 BGP: Rx Intf add VRF 0 IF tap03
2018/10/29 13:32:37 BGP: Rx Intf address add VRF 0 IF tap03 addr 10.10.10.100/24
2018/10/29 13:32:39 BGP: Rx Intf up VRF 0 IF br100
2018/10/29 13:32:39 BGP: Rx Intf up VRF 0 IF br100
2018/10/29 13:32:52 ZEBRA: if_zebra_speed_update: tap03 old speed: 0 new speed: 10
2018/10/29 13:32:52 BGP: Rx Intf add VRF 0 IF tap03
2018/10/29 13:33:06 BGP: Rx Intf add VRF 0 IF tap02
2018/10/29 13:33:06 BGP: Rx Intf address add VRF 0 IF tap02 addr 10.10.10.101/24
2018/10/29 13:33:21 ZEBRA: if_zebra_speed_update: tap02 old speed: 0 new speed: 10
2018/10/29 13:33:21 BGP: Rx Intf add VRF 0 IF tap02
2018/10/29 13:33:24 BGP: Rx Intf add VRF 0 IF tap01
2018/10/29 13:33:24 BGP: Rx Intf address add VRF 0 IF tap01 addr 10.10.20.100/32
2018/10/29 13:33:25 BGP: Rx Intf up VRF 0 IF br200
2018/10/29 13:33:25 BGP: Rx Intf up VRF 0 IF br200
2018/10/29 13:33:39 ZEBRA: if_zebra_speed_update: tap01 old speed: 0 new speed: 10
2018/10/29 13:33:39 BGP: Rx Intf add VRF 0 IF tap01
```

From (one of) the route reflectors (I have 2, this one and xenial01):

```bash
root@xenial02:~# vtysh

Hello, this is FRRouting (version 4.0+cl3u6).
Copyright 1996-2005 Kunihiro Ishiguro, et al.

xenial02# show bgp neighbors
BGP neighbor is *192.168.0.139, remote AS 65000, local AS 65000, internal link
Hostname: xenial03
 Member of peer-group fabric for session parameters
 Belongs to the subnet range group: 192.168.0.0/24
  BGP version 4, remote router ID 192.168.0.139
  BGP state = Established, up for 00:45:53
  Last read 00:00:02, Last write 00:00:02
  Hold time is 9, keepalive interval is 3 seconds
  Neighbor capabilities:
    4 Byte AS: advertised and received
    AddPath:
      L2VPN EVPN: RX advertised L2VPN EVPN and received
    Route refresh: advertised and received(old & new)
    Address Family L2VPN EVPN: advertised and received
    Hostname Capability: advertised (name: xenial02,domain name: n/a) received (name: xenial03,domain name: n/a)
    Graceful Restart Capabilty: advertised and received
      Remote Restart timer is 120 seconds
      Address families by peer:
        none
  Graceful restart informations:
    End-of-RIB send: L2VPN EVPN
    End-of-RIB received: L2VPN EVPN
  Message statistics:
    Inq depth is 0
    Outq depth is 0
                         Sent       Rcvd
    Opens:                  1          1
    Notifications:          0          0
    Updates:                1          5
    Keepalives:           918        918
    Route Refresh:          0          0
    Capability:             0          0
    Total:                920        924
  Minimum time between advertisement runs is 0 seconds
  Update source is 192.168.0.138

 For address family: L2VPN EVPN
  fabric peer-group member
  Update group 1, subgroup 1
  Packet Queue length 0
  NEXT_HOP is propagated unchanged to this neighbor
  Community attribute sent to this neighbor(all)
  4 accepted prefixes

  Connections established 1; dropped 0
  Last reset never
Local host: 192.168.0.138, Local port: 179
Foreign host: 192.168.0.139, Foreign port: 35010
Nexthop: 192.168.0.138
Nexthop global: fe80::b497:9aff:fe5f:e6da
Nexthop local: fe80::b497:9aff:fe5f:e6da
BGP connection: shared network
BGP Connect Retry Timer in Seconds: 10
Read thread: on  Write thread: on


xenial02# show bgp evpn route
BGP table version is 2, local router ID is 192.168.0.138
Status codes: s suppressed, d damped, h history, * valid, > best, i - internal
Origin codes: i - IGP, e - EGP, ? - incomplete
EVPN type-2 prefix: [2]:[ESI]:[EthTag]:[MAClen]:[MAC]:[IPlen]:[IP]
EVPN type-3 prefix: [3]:[EthTag]:[IPlen]:[OrigIP]
EVPN type-5 prefix: [5]:[ESI]:[EthTag]:[IPlen]:[IP]

   Network          Next Hop            Metric LocPrf Weight Path
Route Distinguisher: 192.168.0.139:2
*>i[2]:[0]:[0]:[48]:[ea:63:21:d8:0e:fa]:[128]:[fe80::e863:21ff:fed8:efa]
                    192.168.0.139                 100      0 i
*>i[3]:[0]:[32]:[192.168.0.139]
                    192.168.0.139                 100      0 i
Route Distinguisher: 192.168.0.139:3
*>i[2]:[0]:[0]:[48]:[f2:ce:a3:32:9c:af]:[128]:[fe80::f0ce:a3ff:fe32:9caf]
                    192.168.0.139                 100      0 i
*>i[3]:[0]:[32]:[192.168.0.139]
                    192.168.0.139                 100      0 i

Displayed 4 prefixes (4 paths)
```

We can see the Route Reflector has learned the L3 and MAC routes from xenial03 via BGP.

# Resources

* [VXLAN: BGP EVPN with Cumulus Quagga (or FRR)](https://vincent.bernat.ch/en/blog/2017-vxlan-bgp-evpn) -- an excellent article from Vincent Bernart
* [Proper isolation of a Linux bridge](https://vincent.bernat.ch/en/blog/2017-linux-bridge-isolation)
* [https://vincent.bernat.ch/en/blog/2018-l3-routing-hypervisor](https://vincent.bernat.ch/en/blog/2018-l3-routing-hypervisor)
* [FRR Routing Guide](https://frrouting.readthedocs.io/en/latest/index.html)
