---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Proxmox clustering and nested virtualization'
categories: 
  - Virtualization
tags: [kvm, proxmox, high-availability, cluster]
date: 2016-9-16
series: "Highly Available Multi-tenant KVM Virtualization with Proxmox PVE and OpenVSwitch"
---

The motivation for creating this setup is the possibility of having Encompass private virtualization cloud deployed in any third party infrastructure provider DC, like for example [SoftLayer](http://www.softlayer.com/) that we already use to host our product on Bare-Metal serves. The solution is based on Proxmox PVE (Proxmox Virtualization Environment) version 4.1.x (upgraded to 4.2 later) with KVM as hypervisor. As stated on their website, `Proxmox VE` is a powerful and lightweight open source server virtualization software, optimized for performance and usability. For maximum flexibility, Proxmox VE supports two virtualization technologies - Kernel-based Virtual Machine (KVM) and container-based virtualization with Linux Containers (LXC).

The HA on hypervisor level is being provided with the PVE's built in clustering feature. It also provides live migration for the VM's (not supported for LXC containers) when created with root disk on shared storage which means we can move VM's from one node to another without any downtime for the running instances. The cluster will also automatically migrate the VM's from the node that has crashed or has been put into maintenance mode.

Just to number some of the latest PVE 4 key features:

* Based on Debian 8 - 64 bit
* Broad hardware support
* Host support for Linux and Windows at 32 and 64 bits
* Support for the latest Intel and AMD chipset
* Optimization for the bare-metal virtualization to support high workloads
* Web management with all the features necessary to create and manage a virtual infrastructure
* Management through web interface without needing to use any client software
* Combination of two virtualization technology KVM and LXC
* Clustering for HA

## Host Preparation

The setup has been fully tested on a Proxmox PVE cluster of two Proxmox instances launched on our office Virtualization Server running Proxmox-3.1 and kernel 3.10:

```
root@virtual:~# pveversion -v
proxmox-ve-2.6.32: 3.1-114 (running kernel: 3.10.0-18-pve)
pve-manager: 3.1-21 (running version: 3.1-21/93bf03d4)
pve-kernel-2.6.32-20-pve: 2.6.32-100
pve-kernel-3.10.0-18-pve: 3.10.0-46
pve-kernel-2.6.32-26-pve: 2.6.32-114
lvm2: 2.02.98-pve4
clvm: 2.02.98-pve4
corosync-pve: 1.4.5-1
openais-pve: 1.1.4-3
libqb0: 0.11.1-2
redhat-cluster-pve: 3.2.0-2
resource-agents-pve: 3.9.2-4
fence-agents-pve: 4.0.0-2
pve-cluster: 3.0-8
qemu-server: 3.1-8
pve-firmware: 1.0-23
libpve-common-perl: 3.0-8
libpve-access-control: 3.0-7
libpve-storage-perl: 3.0-17
pve-libspice-server1: 0.12.4-2
vncterm: 1.1-4
vzctl: 4.0-1pve4
vzprocps: 2.0.11-2
vzquota: 3.1-2
pve-qemu-kvm: 1.4-17
ksm-control-daemon: 1.1-1
glusterfs-client: 3.4.1-1
```

This server has one physical CPU with 6 cores, meaning in KVM and other hypervisors it will be presented as 12 cpu's due to hyper-threading.

```
root@virtual:~# egrep -c '(vmx|svm)' /proc/cpuinfo
12
```

we can see all 12 CPU cores are virt enabled supporting the Intel VMX extension in this case.

We needed PVE kernel of 3.10.x since it has nested virtualization feature which is not available in the current PVE 2.6.32 kernel:

```
root@virtual:~# modinfo kvm_intel
filename:       /lib/modules/2.6.32-26-pve/kernel/arch/x86/kvm/kvm-intel.ko
license:        GPL
author:         Qumranet
srcversion:     672265D1CCD374958DD573E
depends:        kvm
vermagic:       2.6.32-26-pve SMP mod_unload modversions
parm:           bypass_guest_pf:bool
parm:           vpid:bool
parm:           flexpriority:bool
parm:           ept:bool
parm:           unrestricted_guest:bool
parm:           eptad:bool
parm:           emulate_invalid_guest_state:bool
parm:           yield_on_hlt:bool
parm:           vmm_exclusive:bool
parm:           ple_gap:int
parm:           ple_window:int
```

I did an upgrade using the kernel from PVE test repository:

```
root@virtual:~# wget -q http://download.proxmox.com/debian/dists/wheezy/pvetest/binary-amd64/pve-kernel-3.10.0-18-pve_3.10.0-46_amd64.deb
root@virtual:~# dpkg -i pve-kernel-3.10.0-18-pve_3.10.0-46_amd64.deb
```

Then to avoid some issues I saw being reported about this kernel giving panics and failed server start ups in case of SCSI drives (failed SCSI bus scanning) we change the default kernel startup line in `/etc/default/grub` from:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
```

to

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet scsi_mod.scan=sync rootdelay=10"
```

and reboot the server to activate the new kernel. After it comes back, we can see our kernel module now has nested capability:

```
root@virtual:~# modinfo kvm_intel
filename:       /lib/modules/3.10.0-18-pve/kernel/arch/x86/kvm/kvm-intel.ko
license:        GPL
author:         Qumranet
rhelversion:    7.2
srcversion:     9F7B2EB3976CBA6622D41D4
alias:          x86cpu:vendor:*:family:*:model:*:feature:*0085*
depends:        kvm
intree:         Y
vermagic:       3.10.0-18-pve SMP mod_unload modversions
parm:           vpid:bool
parm:           flexpriority:bool
parm:           ept:bool
parm:           unrestricted_guest:bool
parm:           eptad:bool
parm:           emulate_invalid_guest_state:bool
parm:           vmm_exclusive:bool
parm:           fasteoi:bool
parm:           enable_apicv:bool
parm:           enable_shadow_vmcs:bool
parm:           nested:bool
parm:           pml:bool
parm:           ple_gap:int
parm:           ple_window:int
parm:           ple_window_grow:int
parm:           ple_window_shrink:int
parm:           ple_window_max:int
```

Before we start any LXC/VM on the Proxmox server we need to enable the KVM `nested` virtualization so we can run containers and vm's inside the nested hosts so we reload the kernel module:

```
root@virtual:~# modprobe -r -v kvm_intel
root@virtual:~# modprobe -v kvm_intel nested=1
```

To enable the feature on reboot:

```
root@virtual:~# echo "options kvm-intel nested=y" > /etc/modprobe.d/kvm-intel.conf
```

We can now create our nested Proxmox instances and choose `host` for `CPU Type` so they can inherit the KVM features. Then we can see on the nested Proxmox hosts after startup:

```
root@proxmox01:~# egrep -c '(vmx|svm)' /proc/cpuinfo
12
```

the CPU virtualization features of the host are being passed on to the launched instances.

Just a note for the case when we want to run nested Proxmox instances in `libvirt`. The cpu mode needs to be set to `host-passthrough` by editing the domain's xml file:

```
<cpu mode='host-passthrough'>
```

otherwise the nested virtualization will not work. Selecting the `Copy Cpu Configuration` in VirtManager sets the cpu mode to `host-model` which does not enable this feature although the name suggests it should.

The Host is already part of our office network `192.168.0.0/24` which is presented to the running instances as external bridged network for internet access. I have created two additional networks on isolated virtual bridges for clustering purposes `10.10.1.0/24` and `10.20.1.0/24`, the relevant setup in `/etc/network/interfaces`:

```
# Create private network bridge with DHCP server
auto vmbr1
iface vmbr1 inet static
  address 10.10.1.1
  netmask 255.255.255.0
  bridge_ports vmbr1tap0
  bridge_waitport 0
  bridge_fd 0
  bridge_stp off
  pre-up /usr/sbin/tunctl -t vmbr1tap0
  pre-up /sbin/ifconfig vmbr1tap0 up
  post-down /sbin/ifconfig vmbr1tap0 down
  post-up dnsmasq -u root --strict-order --bind-interfaces \
  --pid-file=/var/run/vmbr1.pid --conf-file= \
  --except-interface lo --listen-address 10.10.1.1 \
  --dhcp-range 10.10.1.10,10.10.1.20 \
  --dhcp-leasefile=/var/run/vmbr1.leases
 
# Create private network bridge with DHCP server
auto vmbr2
iface vmbr2 inet static
  address 10.20.1.1
  netmask 255.255.255.0
  bridge_ports vmbr2tap0
  bridge_waitport 0
  bridge_fd 0
  bridge_stp off
  pre-up /usr/sbin/tunctl -t vmbr2tap0
  pre-up /sbin/ifconfig vmbr2tap0 up
  post-down /sbin/ifconfig vmbr2tap0 down
  post-up dnsmasq -u root --strict-order --bind-interfaces \
  --pid-file=/var/run/vmbr2.pid --conf-file= \
  --except-interface lo --listen-address 10.20.1.1 \
  --dhcp-range 10.20.1.10,10.20.1.20 \
  --dhcp-leasefile=/var/run/vmbr2.leases
```

For the bridges to be recognized in Proxmox they need to be named `vmbrX`, where X is a digit. We can see a DHCP service has been provided on both private networks via dnsmasq. The resulting network configuration is as follows:

```
root@virtual:~# ip addr show vmbr1
6: vmbr1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP
    link/ether 32:35:2d:99:67:b5 brd ff:ff:ff:ff:ff:ff
    inet 10.10.1.1/24 brd 10.10.1.255 scope global vmbr1
       valid_lft forever preferred_lft forever
    inet6 fe80::3035:2dff:fe99:67b5/64 scope link
       valid_lft forever preferred_lft forever
 
root@virtual:~# ip addr show vmbr2
8: vmbr2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP
    link/ether 72:a4:b7:53:a2:c5 brd ff:ff:ff:ff:ff:ff
    inet 10.20.1.1/24 brd 10.20.1.255 scope global vmbr2
       valid_lft forever preferred_lft forever
    inet6 fe80::70a4:b7ff:fe53:a2c5/64 scope link
       valid_lft forever preferred_lft forever
```

Actually, one more bridge has been configured:

```
root@virtual:~# ip addr show vmbr3
38: vmbr3: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state DOWN
    link/ether b6:35:b1:ca:8e:74 brd ff:ff:ff:ff:ff:ff
    inet 10.30.1.1/24 brd 10.30.1.255 scope global vmbr3
       valid_lft forever preferred_lft forever
```

but we will come back to this one later.

## Proxmox-4.1 Cluster Setup

On both nested Proxmox instances I have installed bare metal PVE-4.1 from ISO image. It is based on Debian-8 (Jessy) and it comes with 4.2.6 kernel:

```
root@proxmox01:~# pveversion -v
proxmox-ve: 4.1-26 (running kernel: 4.2.6-1-pve)
pve-manager: 4.1-1 (running version: 4.1-1/2f9650d4)
pve-kernel-4.2.6-1-pve: 4.2.6-26
lvm2: 2.02.116-pve2
corosync-pve: 2.3.5-2
libqb0: 0.17.2-1
pve-cluster: 4.0-29
qemu-server: 4.0-41
pve-firmware: 1.1-7
libpve-common-perl: 4.0-41
libpve-access-control: 4.0-10
libpve-storage-perl: 4.0-38
pve-libspice-server1: 0.12.5-2
vncterm: 1.2-1
pve-qemu-kvm: 2.4-17
pve-container: 1.0-32
pve-firewall: 2.0-14
pve-ha-manager: 1.0-14
ksm-control-daemon: 1.2-1
glusterfs-client: 3.5.2-2+deb8u1
lxc-pve: 1.1.5-5
lxcfs: 0.13-pve1
cgmanager: 0.39-pve1
criu: 1.6.0-1
zfsutils: 0.6.5-pve6~jessie
openvswitch-switch: 2.3.0+git20140819-3
```

To keep PVE up-to-date we need to enable the no-subscription repository:

```
$ echo 'deb http://download.proxmox.com/debian jessy pve-no-subscription' | tee /etc/apt/sources.list.d/pve-no-subscription.list
```

To upgrade everything to the latest PVE which is 4.2 since 27/04/2016:

```
# apt-get -y update && apt-get -y upgrade && apt-get -y dist-upgrade
# reboot --reboot --force
```

The instances are attached to both private networks created on the Host as described in the previous section:

```
root@proxmox01:~# ifconfig
eth0      Link encap:Ethernet  HWaddr c2:04:26:bd:ae:23 
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:15984 errors:0 dropped:0 overruns:0 frame:0
          TX packets:3967 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000
          RX bytes:1539185 (1.4 MiB)  TX bytes:732810 (715.6 KiB)
 
eth1      Link encap:Ethernet  HWaddr 06:97:e4:a3:7b:be 
          inet addr:10.10.1.185  Bcast:10.10.1.255  Mask:255.255.255.0
          inet6 addr: fe80::497:e4ff:fea3:7bbe/64 Scope:Link
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:1932 errors:0 dropped:0 overruns:0 frame:0
          TX packets:2094 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000
          RX bytes:372103 (363.3 KiB)  TX bytes:447392 (436.9 KiB)
 
eth2      Link encap:Ethernet  HWaddr e2:55:6a:54:23:63 
          inet addr:10.20.1.185  Bcast:10.20.1.255  Mask:255.255.255.0
          inet6 addr: fe80::e055:6aff:fe54:2363/64 Scope:Link
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:572 errors:0 dropped:0 overruns:0 frame:0
          TX packets:13 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000
          RX bytes:44180 (43.1 KiB)  TX bytes:1062 (1.0 KiB)
 
vmbr0     Link encap:Ethernet  HWaddr c2:04:26:bd:ae:23 
          inet addr:192.168.0.185  Bcast:192.168.0.255  Mask:255.255.255.0
          inet6 addr: fe80::c004:26ff:febd:ae23/64 Scope:Link
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:15848 errors:0 dropped:0 overruns:0 frame:0
          TX packets:3968 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:0
          RX bytes:1305985 (1.2 MiB)  TX bytes:732928 (715.7 KiB)
 
 
root@proxmox02:~# ifconfig
eth0      Link encap:Ethernet  HWaddr 1a:dc:cf:9c:40:f5 
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:15415 errors:0 dropped:0 overruns:0 frame:0
          TX packets:2639 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000
          RX bytes:1515062 (1.4 MiB)  TX bytes:551935 (538.9 KiB)
 
eth1      Link encap:Ethernet  HWaddr 7a:ff:59:17:9d:94 
          inet addr:10.10.1.186  Bcast:10.10.1.255  Mask:255.255.255.0
          inet6 addr: fe80::78ff:59ff:fe17:9d94/64 Scope:Link
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:2628 errors:0 dropped:0 overruns:0 frame:0
          TX packets:1897 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000
          RX bytes:489533 (478.0 KiB)  TX bytes:394310 (385.0 KiB)
 
eth2      Link encap:Ethernet  HWaddr 3e:a1:05:95:4f:6e 
          inet addr:10.20.1.186  Bcast:10.20.1.255  Mask:255.255.255.0
          inet6 addr: fe80::3ca1:5ff:fe95:4f6e/64 Scope:Link
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:907 errors:0 dropped:0 overruns:0 frame:0
          TX packets:13 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000
          RX bytes:72827 (71.1 KiB)  TX bytes:1062 (1.0 KiB)
 
vmbr0     Link encap:Ethernet  HWaddr 1a:dc:cf:9c:40:f5 
          inet addr:192.168.0.186  Bcast:192.168.0.255  Mask:255.255.255.0
          inet6 addr: fe80::18dc:cfff:fe9c:40f5/64 Scope:Link
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:15262 errors:0 dropped:0 overruns:0 frame:0
          TX packets:2625 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:0
          RX bytes:1288482 (1.2 MiB)  TX bytes:530571 (518.1 KiB)
```

PVE takes over the primary interface `eth0` and moves its setup to the `vmbr0` linux bridge. We start by creating the Cluster ie `Corosync` configuration which PVE uses for its cluster messaging, I'm opting here for dual Corosync ring in passive mode:

```
root@proxmox01:~# pvecm create proxmox -bindnet0_addr 192.168.0.185 -ring0_addr 192.168.0.185 -bindnet1_addr 10.10.1.185 -ring1_addr 10.10.1.185 -rrp_mode passive
```

We run this on one node only. Then we add the second one, proxmox02, to the cluster:

```
root@proxmox02:~# pvecm add 192.168.0.185 -ring0_addr 192.168.0.186 -ring1_addr 10.10.1.186
The authenticity of host '192.168.0.185 (192.168.0.185)' can't be established.
ECDSA key fingerprint is 43:8d:e3:79:70:88:0f:c8:e3:26:73:f8:c3:67:43:ef.
Are you sure you want to continue connecting (yes/no)? yes
root@192.168.0.185's password:
copy corosync auth key
stopping pve-cluster service
backup old database
waiting for quorum...OK
generating node certificates
merge known_hosts file
restart services
successfully added node 'proxmox02' to cluster.
root@proxmox02:~#
```

This will also add the root user ssh key to each other autorized_keys file. If we now check the cluster state:

```
root@proxmox02:~# pvecm status
Quorum information
------------------
Date:             Fri Mar  4 16:15:27 2016
Quorum provider:  corosync_votequorum
Nodes:            2
Node ID:          0x00000002
Ring ID:          8
Quorate:          Yes
  
Votequorum information
----------------------
Expected votes:   2
Highest expected: 2
Total votes:      2
Quorum:           2 
Flags:            Quorate
  
Membership information
----------------------
    Nodeid      Votes Name
0x00000001          1 192.168.0.185
0x00000002          1 192.168.0.186 (local)
```

and we can see the Corosync process running on both nodes and see its configuration created by PVE:

```
root@proxmox02:~# cat /etc/pve/corosync.conf
logging {
  debug: off
  to_syslog: yes
}
nodelist {
  node {
    name: proxmox02
    nodeid: 2
    quorum_votes: 1
    ring0_addr: 192.168.0.186
    ring1_addr: 10.10.1.186
  }
  node {
    name: proxmox01
    nodeid: 1
    quorum_votes: 1
    ring0_addr: 192.168.0.185
    ring1_addr: 10.10.1.185
  }
}
quorum {
  provider: corosync_votequorum
}
totem {
  cluster_name: proxmox
  config_version: 2
  ip_version: ipv4
  rrp_mode: passive
  secauth: on
  version: 2
  interface {
    bindnetaddr: 192.168.0.185
    ringnumber: 0
  }
  interface {
    bindnetaddr: 10.10.1.185
    ringnumber: 1
  }
}
```

The PVE cluster uses `Watchdog` for fencing. If no hardware one is configured on the nodes it will use the linux `softdog` by default, which makes the solution possible to run inside VM's as well as on real hardware.

After installation the Proxmox GUI will be available on any of the cluster servers, so `https://192.168.0.185:8006` and `https://192.168.0.186:8006` will both work. After logging in we can see both nodes added to the `Datacenter`. When we click  on the `HA` tab we will see `quorum ok` status.

In case we do some manual changes (there is special procedure described on the PVE website for this) to `/etc/pve/corosync.conf` file we will need to restart all cluster services:

```
# systemctl restart corosync.service
# systemctl restart pve-cluster.service
# systemctl restart pvedaemon.service
# systemctl restart pveproxy.service
```

but reboot is cleaner and really recommended.

It is very important to note that the PVE configuration lives in `/etc/pve` which is fuse mounted read only file system in user space:

```
root@proxmox02:~# mount | grep etc
/dev/fuse on /etc/pve type fuse (rw,nosuid,nodev,relatime,user_id=0,group_id=0,default_permissions,allow_other)
```

and has no write privileges when running a PVE cluster. The only way to edit any files under `/etc/pve` is to disable the cluster by setting:

```
DAEMON_OPTS="-l"
```

in the `/etc/default/pve-cluster` file and reboot the node so it comes up in local mode. Then edit and make changes, remove the `-l` from above and reboot again.

If we need to change `/etc/pve/corosync.conf` on a node with no quorum, we can run:

```
# pvecm expected 1
```

to set the expected vote count to 1. This makes the cluster quorate and you can fix your config, or revert it back to the back up. If that wasn't enough (e.g.: corosync is dead) use:

```
# systemctl stop pve-cluster
# pmxcfs -l
```

to start the `pmxcfs` (proxmox cluster file system) in a local mode. We have now write access, so we need to be very careful with changes! After restarting the file system should merge changes, if there is no big merge conflict that could result in a split brain.

At the end we install some software we are going to need later:

```
# apt-get install -y uml-utils openvswitch-switch dnsmasq
```

## Adding VM or LXC container as HA instance

As mentioned before, PVE supports High Availability for the launched instances. This is made fairly simple using the CLI tools, the following procedure shows how to add a VM to the HA manager:

```
root@proxmox01:~# qm list
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID      
       102 vm01                 running    1024               8.00 7995
 
root@proxmox01:~# ha-manager add vm:102
 
root@proxmox01:~# ha-manager status
quorum OK
master proxmox01 (active, Fri Apr 29 14:46:26 2016)
lrm proxmox01 (active, Fri Apr 29 14:46:20 2016)
lrm proxmox02 (active, Fri Apr 29 14:46:28 2016)
service ct:100 (proxmox01, started)
service ct:101 (proxmox02, started)
service ct:103 (proxmox01, started)
service vm:102 (proxmox01, started)
```

Same operation can be executed via the GUI too.

## Note about VM Templates

It is common procedure to create a Template from base image VM that we can then use to launch new VM's of the same type, lets say Ubuntu-14.04 VM's fast and easy. After creating a template from a VM it is best we remove the CD drive we used to mount the installation `iso` media, set `KVM hardware virtualization` to `no` (we don't need this in VM's launched in a already nested VM) and set `Qemu Agent` to `yes` which is used to freeze the guest file system when making a backup (assumes `qemu-guest-agent` package installed) under the `Options` tab for the template before we launch any instances from it.

{% include series.html %}