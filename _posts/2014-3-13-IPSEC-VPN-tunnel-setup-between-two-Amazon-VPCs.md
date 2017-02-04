---
type: posts
header:
  teaser: '488564370.jpg'
title: "IPSEC VPN tunnel setup between two Amazon VPC's with OpenSwan and EC2 NAT instances"
categories: 
  - DevOps
tags: [aws, vpn]
date: 2014-3-13
---

With services running in multiple VPC's sooner or later a need will arise for secure clustering of instances across regions. This is especially important in case when such services do not have built in SSL/TLS support or when the services are running on private only instances, ie instances that don't have public ip's and are meant to have private traffic only like databases, attached storage etc. There some low level tools we can use to support non SSL services, like stunnel, stud etc, but they all require public accessible instances. The VPN tunnel on other hand establishes a bridge between the private networks from different regions making the clustering much more easier as it makes it look like all instances are part of the same private network.

# Overview

To make internet access available for private subnets we need to create a NAT instance to route their traffic through. And to create the VPN tunnel between the VPC's we will need one VPN instance. Instead having two separate instances in each VPC I have created single `m1.small` instance that will serve both roles. Depending on the load we can scale this up if needed.

On the VPC1 side we have public subnet of `10.1.1.0/24` and private subnet `10.1.10.0/24`. The NAT/VPN instance has been created in the public subnet with ip of `10.1.1.254` and in the private subnet we have instance with ip of `10.1.10.41`. This private instance needs to get Internet access via the NAT instance (which is a VPN instance in the same time) for software update purposes but should also be able to talk to the private instances on the VPC2 side (and vice-versa).

In the VPC2 VPC we launch NAT/VPN instance with ip of `172.31.12.198` and private instance with ip of `172.31.200.200` created in the `172.31.200.0/24` private subnet.

Both NAT/VPN instances should have EIP associated to their primary interface. For the VPC2 side that is `54.124.x.x` and `54.26.x.x` on the VPC1 side.

# Setup

## NAT-ing

We need to set the NAT rules in that way that the VPN tunneled networks are not NAT'ed.

On the VPC1 side:

```
root@10.1.1.254:~# iptables -t nat -A POSTROUTING -o eth0 -s 10.1.0.0/16 -d 172.31.0.0/16 -j ACCEPT
root@10.1.1.254:~# iptables -t nat -A POSTROUTING -o eth0 -s 10.1.0.0/16 -j MASQUERADE
```

On the VPC2 side:

```
root@172.31.12.198:~# iptables -t nat -A POSTROUTING -o eth0 -s 172.31.0.0/16 -d 10.1.0.0/16 -j ACCEPT
root@172.31.12.198:~# iptables -t nat -A POSTROUTING -o eth0 -s 172.31.0.0/16 -j MASQUERADE
```

Then for each VPC we need to:

* Set the NAT instance as default gateway in the VPC routing table for the private subnet(s)
* Modify the security group of the private instances that will be using this NAT/VPN servers to allow ALL traffic from the NAT/VPN security group (appropriate to the zone)
* Modify the security groups of the NAT/VPN instances to allow ALL traffic from each other and the coresponding private instances security group
* Turn off the Source/Destination check on the NAT instance

## Configure the kernel

Append (or modify if some of these already exist) the following to the end of the kernel config file.

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
root@server:~# sysctl -p
```

## VPN tunnel

We need the `openswan` package installed on our NAT/VPN instances. For Debian/Ubuntu this is as simple as:

```
# aptitude install openswan
```

On the VPC1 side we add to ipsec `/etc/ipsec.conf` config file:

```
conn uk-to-au
  authby=secret
  auto=start
  type=tunnel
  left=10.1.1.254
  leftid=54.26.x.x
  leftsubnet=10.1.0.0/16
  right=54.124.x.x
  rightsubnet=172.31.0.0/16
  ike=aes256-sha1;modp2048
  phase2=esp
  phase2alg=aes256-sha1;modp2048
  forceencaps=yes
```

On the VPC2 side we add to `/etc/ipsec.conf` file:

```
conn au-to-uk
  authby=secret
  auto=start
  type=tunnel
  left=172.31.12.198
  leftid=54.124.x.x  
  leftsubnet=172.31.0.0/16
  right=54.26.x.x
  rightsubnet=10.1.0.0/16
  ike=aes256-sha1;modp2048
  phase2=esp
  phase2alg=aes256-sha1;modp2048
  forceencaps=yes
```

And we add following two lines to ipsec security file `/etc/ipsec.secrets` specifying the shared secret used for both directions:

```
54.26.x.x 54.124.x.x : PSK "0xaec8d3991aaff8bc8e2e3f731a8f6882"
54.124.x.x 54.26.x.x : PSK "0xaec8d3991aaff8bc8e2e3f731a8f6882"
```

on both sides. We can use the following command to generate the `ipsec` secret(s):

```
$ ipsec ranbits --continuous 128
0xaec8d3991aaff8bc8e2e3f731a8f6882
```

The above given one is not the one used on the real servers of course.

At the end we restart the ipsec service on both sides:

```
# service ipsec restart
```

After that the private instances from VPC2 and VPC1 VPC's should be able to ping each other assuming the NAT part is already done.

Ping test from VPC2 VPC private instance to VPC1 VPC instance using its private ip only:

```
root@ip-172-31-200-200:~# ping -c 5 10.1.10.41
PING 10.1.10.41 (10.1.10.41) 56(84) bytes of data.
64 bytes from 10.1.10.41: icmp_req=1 ttl=62 time=340 ms
64 bytes from 10.1.10.41: icmp_req=2 ttl=62 time=340 ms
64 bytes from 10.1.10.41: icmp_req=3 ttl=62 time=340 ms
64 bytes from 10.1.10.41: icmp_req=4 ttl=62 time=340 ms
64 bytes from 10.1.10.41: icmp_req=5 ttl=62 time=340 ms
 
--- 10.1.10.41 ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4005ms
rtt min/avg/max/mdev = 340.253/340.353/340.585/0.650 ms
```

We listen for icmp traffic on the receiving side:

```
root@ip-10-1-10-41:~# tcpdump icmp
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), capture size 65535 bytes
13:20:12.420519 IP ip-172-31-200-200.eu-west-1.compute.internal > ip-10-1-10-41.eu-west-1.compute.internal: ICMP echo request, id 3631, seq 1, length 64
13:20:12.420552 IP ip-10-1-10-41.eu-west-1.compute.internal > ip-172-31-200-200.eu-west-1.compute.internal: ICMP echo reply, id 3631, seq 1, length 64
13:20:13.421785 IP ip-172-31-200-200.eu-west-1.compute.internal > ip-10-1-10-41.eu-west-1.compute.internal: ICMP echo request, id 3631, seq 2, length 64
13:20:13.421827 IP ip-10-1-10-41.eu-west-1.compute.internal > ip-172-31-200-200.eu-west-1.compute.internal: ICMP echo reply, id 3631, seq 2, length 64
13:20:14.423040 IP ip-172-31-200-200.eu-west-1.compute.internal > ip-10-1-10-41.eu-west-1.compute.internal: ICMP echo request, id 3631, seq 3, length 64
13:20:14.423083 IP ip-10-1-10-41.eu-west-1.compute.internal > ip-172-31-200-200.eu-west-1.compute.internal: ICMP echo reply, id 3631, seq 3, length 64
13:20:15.424580 IP ip-172-31-200-200.eu-west-1.compute.internal > ip-10-1-10-41.eu-west-1.compute.internal: ICMP echo request, id 3631, seq 4, length 64
13:20:15.424612 IP ip-10-1-10-41.eu-west-1.compute.internal > ip-172-31-200-200.eu-west-1.compute.internal: ICMP echo reply, id 3631, seq 4, length 64
13:20:16.426040 IP ip-172-31-200-200.eu-west-1.compute.internal > ip-10-1-10-41.eu-west-1.compute.internal: ICMP echo request, id 3631, seq 5, length 64
13:20:16.426078 IP ip-10-1-10-41.eu-west-1.compute.internal > ip-172-31-200-200.eu-west-1.compute.internal: ICMP echo reply, id 3631, seq 5, length 64
```

And we test the other way around:

```
root@ip-10-1-10-41:~# ping -c 5 172.31.200.200
PING 172.31.200.200 (172.31.200.200) 56(84) bytes of data.
64 bytes from 172.31.200.200: icmp_req=1 ttl=62 time=340 ms
64 bytes from 172.31.200.200: icmp_req=2 ttl=62 time=340 ms
64 bytes from 172.31.200.200: icmp_req=3 ttl=62 time=340 ms
64 bytes from 172.31.200.200: icmp_req=4 ttl=62 time=340 ms
64 bytes from 172.31.200.200: icmp_req=5 ttl=62 time=340 ms
 
--- 172.31.200.200 ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4002ms
rtt min/avg/max/mdev = 340.292/340.459/340.599/0.114 ms
```

The icmp traffic on the receiving side:

```
root@ip-172-31-200-200:~# tcpdump icmp
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), capture size 65535 bytes
13:24:03.959726 IP ip-10-1-10-41.ap-southeast-2.compute.internal > ip-172-31-200-200.ap-southeast-2.compute.internal: ICMP echo request, id 7820, seq 1, length 64
13:24:03.959770 IP ip-172-31-200-200.ap-southeast-2.compute.internal > ip-10-1-10-41.ap-southeast-2.compute.internal: ICMP echo reply, id 7820, seq 1, length 64
13:24:04.960371 IP ip-10-1-10-41.ap-southeast-2.compute.internal > ip-172-31-200-200.ap-southeast-2.compute.internal: ICMP echo request, id 7820, seq 2, length 64
13:24:04.960419 IP ip-172-31-200-200.ap-southeast-2.compute.internal > ip-10-1-10-41.ap-southeast-2.compute.internal: ICMP echo reply, id 7820, seq 2, length 64
13:24:05.960773 IP ip-10-1-10-41.ap-southeast-2.compute.internal > ip-172-31-200-200.ap-southeast-2.compute.internal: ICMP echo request, id 7820, seq 3, length 64
13:24:05.960820 IP ip-172-31-200-200.ap-southeast-2.compute.internal > ip-10-1-10-41.ap-southeast-2.compute.internal: ICMP echo reply, id 7820, seq 3, length 64
13:24:06.961421 IP ip-10-1-10-41.ap-southeast-2.compute.internal > ip-172-31-200-200.ap-southeast-2.compute.internal: ICMP echo request, id 7820, seq 4, length 64
13:24:06.961468 IP ip-172-31-200-200.ap-southeast-2.compute.internal > ip-10-1-10-41.ap-southeast-2.compute.internal: ICMP echo reply, id 7820, seq 4, length 64
13:24:07.961948 IP ip-10-1-10-41.ap-southeast-2.compute.internal > ip-172-31-200-200.ap-southeast-2.compute.internal: ICMP echo request, id 7820, seq 5, length 64
13:24:07.961992 IP ip-172-31-200-200.ap-southeast-2.compute.internal > ip-10-1-10-41.ap-southeast-2.compute.internal: ICMP echo reply, id 7820, seq 5, length 64
```

This confirms that both sides are now connected via VPN tunnel.
