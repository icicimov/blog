---
type: posts
header:
  teaser: 'kubernetes-logo.png'
title: 'Kubernetes cluster step-by-step: Nodes System Setup'
categories: 
  - Kubernetes
tags: ['kubernetes', 'wireguard']
date: 2017-6-12
excerpt: "The purpose of this exercise is to create local `Kubernetes` cluster for testing deployments. It will be deployed on 3 x VMs (Debian Jessie 8.8) nodes which will be Master and Worker nodes"
series: "Kubernetes cluster step-by-step"
---
{% include toc %}
The purpose of this exercise is to create local `Kubernetes` cluster for testing deployments. It will be deployed on 3 x VMs (Debian Jessie 8.8) nodes which will be Master and Worker nodes in same time. The nodes names will be k8s01 (192.168.0.147), k8s02 (192.168.0.148) and k8s03 (192.168.0.149). All work is done as `root` user unless otherwise specified. Each node has the IPs, short and FQDN of all the nodes set in its local hosts file.

# Nodes System Setup

In this step we prepare the nodes for Kubernetes. First we enable Debian backports and Docker repository on each of the nodes:

```
echo 'deb http://httpredir.debian.org/debian jessie-backports main' | tee /etc/apt/sources.list.d/backports.list
printf 'Package: *\nPin: release a=unstable\nPin-Priority: 150\n' > /etc/apt/preferences.d/limit-unstable
echo 'deb https://apt.dockerproject.org/repo debian-jessie main' | tee /etc/apt/sources.list.d/docker.list
```
Debian stable comes with 3.16 kernel and in case we need something new, i.e. we want to use `overlay2` storage driver in Docker, we need to install the latest kernel from backports:

```
APT_LISTCHANGES_FRONTEND=none apt-get install -y -t jessie-backports linux-image-amd64
```

This is a decision that needs to be done at the very beginning because making the change later will involve stopping and recreating of all containers running with the old storage driver which can mean data lose as well.

To enable the Memory `cgroup` properly working (this is Debian specific) edit the default GRUB file:

```
# /etc/default/grub
...
GRUB_CMDLINE_LINUX="cgroup_enable=memory swapaccount=1"
...
```

And restart:

```
update-grub
reboot
```

Couple of sysctl settings in `/etc/sysctl.conf` file:

```
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.ip_nonlocal_bind = 1 # needed for haproxy to bind to the kube-api VIP
net.bridge.bridge-nf-call-iptables = 1
# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
```

The `/etc/hosts` file where we set the nodes dns resolution and some domains we want to load-balance via HAProxy (that we install and configure later):

```
127.0.0.1   localhost
192.168.0.147 k8s01.virtual.local     k8s01
192.168.0.148 k8s02.virtual.local     k8s02
192.168.0.149 k8s03.virtual.local     k8s03
192.168.0.150 k8s-api.virtual.local   k8s-etcd.virtual.local  k8s-api k8s-etcd
```

The `/etc/resolv.conf` will look like this:

``` 
nameserver 192.168.0.1
nameserver 8.8.8.8
search virtual.local
```

and since Kubernetes mounts this file inside every Pod created it will enable them to resolve external DNS names via our LAN's router DNS cache first.  

## Docker

The following scriplet installs Docker on Debian Jessie:

```
apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
echo "deb https://apt.dockerproject.org/repo debian-jessie main" > /etc/apt/sources.list.d/docker.list
apt update
apt-get install -y \
     apt-transport-https \
     ca-certificates \
     curl \
     gnupg2 \
     software-properties-common \
     bridge-utils
apt install -y docker-engine=1.12.6-0~debian-jessie
```

## IPSec encryption between the nodes via WireGuard (Optional)

Install WireGuard:

```
root@k8s01:/srv/kubernetes# echo "deb http://deb.debian.org/debian/ unstable main" > /etc/apt/sources.list.d/unstable-wireguard.list
root@k8s01:/srv/kubernetes# printf 'Package: *\nPin: release a=unstable\nPin-Priority: 150\n' > /etc/apt/preferences.d/limit-unstable
root@k8s01:/srv/kubernetes# apt update
root@k8s01:/srv/kubernetes# apt install wireguard-dkms wireguard-tools
```

Next we choose random IPSec network, I'll go with `172.68.0.0/24`:

```
k8s01 	192.168.0.147 	172.68.0.147
k8s02 	192.168.0.148 	172.68.0.148
k8s03 	192.168.0.149 	172.68.0.149
```

In this scenario, a configuration file for `k8s01` would look like this:

```
# /etc/wireguard/wg0.conf
[Interface]
Address = 192.168.0.147
PrivateKey = <PRIVATE_KEY_K8S01>
ListenPort = 51820

[Peer]
PublicKey = <PUBLIC_KEY_K8S02>
AllowedIps = 172.68.0.148/32
Endpoint = 192.168.0.148:51820

[Peer]
PublicKey = <PUBLIC_KEY_K8S03>
AllowedIps = 172.68.0.149/32
Endpoint = 192.168.0.149:51820
```

To create the needed keys run:

```
for i in 1 2 3; do
  private_key=$(wg genkey)
  public_key=$(echo $private_key | wg pubkey)
  echo "Host $i private key: $private_key"
  echo "Host $i public key:  $public_key"
done

Host 1 private key: 4E9xjeFxWKiIIgFVKxOkqBqU7GdiT+AbK/QFDUPdEWU=
Host 1 public key:  UIUinb2/F19Tbv7x38yf9SW+t2Gyje2ThEXeSrAGvFA=
Host 2 private key: wMPzNiIOwkTpOfR8xAKJAsaUnvZOBVptT+px9lG6KUM=
Host 2 public key:  444V4xzUrvywsO4gx45Tx7pbhDEynRcdvYO7MpGLWiU=
Host 3 private key: mBz5ki2wcqOkA1hxYiqcC2IuepGlm/amtOadyuz/TEs=
Host 3 public key:  98CdxzhPKc70cBV3qA/e7upzmV6/SibDqgkllrWNryE=
```

So the final setup for the first host will be:

```
root@k8s01:~# vi /etc/wireguard/wg0.conf
[Interface]
Address = 172.68.0.147
PrivateKey = 4E9xjeFxWKiIIgFVKxOkqBqU7GdiT+AbK/QFDUPdEWU=
ListenPort = 51820

[Peer]
PublicKey = 444V4xzUrvywsO4gx45Tx7pbhDEynRcdvYO7MpGLWiU=
AllowedIps = 172.68.0.148/32
Endpoint = 192.168.0.148:51820

[Peer]
PublicKey = 98CdxzhPKc70cBV3qA/e7upzmV6/SibDqgkllrWNryE=
AllowedIps = 172.68.0.149/32
Endpoint = 192.168.0.149:51820
```

For host k8s02:

```
# /etc/wireguard/wg0.conf
[Interface]
Address = 172.68.0.148
PrivateKey = wMPzNiIOwkTpOfR8xAKJAsaUnvZOBVptT+px9lG6KUM=
ListenPort = 51820

[Peer]
PublicKey = UIUinb2/F19Tbv7x38yf9SW+t2Gyje2ThEXeSrAGvFA=
AllowedIps = 172.68.0.147/32
Endpoint = 192.168.0.147:51820

[Peer]
PublicKey = 98CdxzhPKc70cBV3qA/e7upzmV6/SibDqgkllrWNryE=
AllowedIps = 172.68.0.149/32
Endpoint = 192.168.0.149:51820
```

For host k8s03:

```
# /etc/wireguard/wg0.conf
[Interface]
Address = 172.68.0.149
PrivateKey = mBz5ki2wcqOkA1hxYiqcC2IuepGlm/amtOadyuz/TEs=
ListenPort = 51820

[Peer]
PublicKey = UIUinb2/F19Tbv7x38yf9SW+t2Gyje2ThEXeSrAGvFA=
AllowedIps = 172.68.0.147/32
Endpoint = 192.168.0.147:51820

[Peer]
PublicKey = 444V4xzUrvywsO4gx45Tx7pbhDEynRcdvYO7MpGLWiU=
AllowedIps = 172.68.0.148/32
Endpoint = 192.168.0.148:51820
```

Set correct permissions on the file:

```
# chmod 0640 /etc/wireguard/wg0.conf
```

And start the service on all nodes:

```
root@k8s01:~# systemctl start wg-quick@wg0
root@k8s01:~# systemctl status -l wg-quick@wg0
 wg-quick@wg0.service - WireGuard via wg-quick(8) for wg0
   Loaded: loaded (/lib/systemd/system/wg-quick@.service; disabled)
   Active: active (exited) since Fri 2017-07-14 15:33:42 AEST; 30s ago
     Docs: man:wg-quick(8)
           man:wg(8)
           https://www.wireguard.io/
           https://www.wireguard.io/quickstart/
           https://git.zx2c4.com/WireGuard/about/src/tools/wg-quick.8
           https://git.zx2c4.com/WireGuard/about/src/tools/wg.8
  Process: 2994 ExecStop=/usr/bin/wg-quick down %i (code=exited, status=1/FAILURE)
  Process: 3515 ExecStart=/usr/bin/wg-quick up %i (code=exited, status=0/SUCCESS)
 Main PID: 3515 (code=exited, status=0/SUCCESS)

Jul 14 15:33:42 k8s01 systemd[1]: Starting WireGuard via wg-quick(8) for wg0...
Jun 14 15:33:42 k8s01 wg-quick[3515]: [#] ip link add wg0 type wireguard
Jun 14 15:33:42 k8s01 wg-quick[3515]: [#] wg setconf wg0 /dev/fd/63
Jun 14 15:33:42 k8s01 wg-quick[3515]: [#] ip address add 172.68.0.147 dev wg0
Jun 14 15:33:42 k8s01 wg-quick[3515]: [#] ip link set mtu 1420 dev wg0
Jun 14 15:33:42 k8s01 wg-quick[3515]: [#] ip link set wg0 up
Jun 14 15:33:42 k8s01 wg-quick[3515]: [#] ip route add 172.68.0.149/32 dev wg0
Jun 14 15:33:42 k8s01 wg-quick[3515]: [#] ip route add 172.68.0.148/32 dev wg0
Jun 14 15:33:42 k8s01 systemd[1]: Started WireGuard via wg-quick(8) for wg0.
```

Now we check the peers:

```
root@k8s01:~# wg show
interface: wg0
  public key: UIUinb2/F19Tbv7x38yf9SW+t2Gyje2ThEXeSrAGvFA=
  private key: (hidden)
  listening port: 51820

peer: 444V4xzUrvywsO4gx45Tx7pbhDEynRcdvYO7MpGLWiU=
  endpoint: 192.168.0.148:51820
  allowed ips: 172.68.0.148/32
  latest handshake: 30 seconds ago
  transfer: 428 B received, 692 B sent

peer: 98CdxzhPKc70cBV3qA/e7upzmV6/SibDqgkllrWNryE=
  endpoint: 192.168.0.149:51820
  allowed ips: 172.68.0.149/32
  latest handshake: 36 seconds ago
  transfer: 428 B received, 692 B sent
```

and confirm they are set properly. Check the network interface and IP:

```
root@k8s01:~# ip -4 addr show wg0
14: wg0: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420 qdisc noqueue state UNKNOWN group default 
    inet 172.68.0.147/32 scope global wg0
       valid_lft forever preferred_lft forever

root@k8s01:~# ip -4 route show dev wg0
172.68.0.148  scope link 
172.68.0.149  scope link
```

Trying ping to verify connectivity:

```
root@k8s01:~# ping -c4 172.68.0.149
PING 172.68.0.149 (172.68.0.149) 56(84) bytes of data.
64 bytes from 172.68.0.149: icmp_seq=1 ttl=64 time=3.38 ms
64 bytes from 172.68.0.149: icmp_seq=2 ttl=64 time=0.835 ms
64 bytes from 172.68.0.149: icmp_seq=3 ttl=64 time=0.615 ms
64 bytes from 172.68.0.149: icmp_seq=4 ttl=64 time=1.26 ms

--- 172.68.0.149 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3008ms
rtt min/avg/max/mdev = 0.615/1.524/3.381/1.097 ms

root@k8s01:~# ping -c4 172.68.0.148
PING 172.68.0.148 (172.68.0.148) 56(84) bytes of data.
64 bytes from 172.68.0.148: icmp_seq=1 ttl=64 time=3.26 ms
64 bytes from 172.68.0.148: icmp_seq=2 ttl=64 time=0.970 ms
64 bytes from 172.68.0.148: icmp_seq=3 ttl=64 time=0.594 ms
64 bytes from 172.68.0.148: icmp_seq=4 ttl=64 time=0.510 ms

--- 172.68.0.148 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3003ms
rtt min/avg/max/mdev = 0.510/1.333/3.260/1.126 ms
root@k8s01:~# 
```

Lastly enable the service on startup:

```
# systemctl enable wg-quick@wg0
```

Now we can use these encrypted `P-t-P` network instead, ie replace `eth0` and it's IP with `wg0` and it's IP for each host in the below config.

{% include series.html %} 
