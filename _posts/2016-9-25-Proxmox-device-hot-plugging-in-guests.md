---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Proxmox device hot-plugging in guests'
categories: 
  - Virtualization
tags: [kvm, proxmox, high-availability, cluster]
date: 2016-9-25
---

This should be pretty straightforward, adding:

```
hotplug: 1
```

to the `/etc/pve/qemu-server/VMID.conf` file might work and that is for all types of devices ie network, disk, cpu etc.

In case the hot-plugging still doesn't work when device is being added from the web UI, we can add the device(s) manually. Lets take this VM for example running on a Proxmox server:

```
root@virtual:~# ls -l /var/lib/vz/images/122/vm-122-disk*
-rw-r--r-- 1 root root  8589934592 Mar 11 14:09 /var/lib/vz/images/122/vm-122-disk-1.raw
-rw-r--r-- 1 root root 21478375424 Mar  7 02:42 /var/lib/vz/images/122/vm-122-disk-4.qcow2
```

It already has one `raw` and one `qcow2` disks attached to it. Let's add third thin provisioned one:

```
root@virtual:~# qemu-img create -f qcow2 -o size=10G,preallocation=metadata /var/lib/vz/images/122/vm-122-disk-5.qcow2
Formatting '/var/lib/vz/images/122/vm-122-disk-5.qcow2', fmt=qcow2 size=10737418240 encryption=off cluster_size=65536 preallocation='metadata' lazy_refcounts=off
```

Then we attach it to the VM as `virtio` block device as follows:

```
root@virtual:~# qm monitor 122
Entering Qemu Monitor for VM 122 - type 'help' for help
qm> info block
drive-scsi1: removable=0 io-status=ok file=/var/lib/vz/images/122/vm-122-disk-2.qcow2 ro=0 drv=qcow2 encrypted=0 bps=0 bps_rd=0 bps_wr=0 iops=0 iops_rd=0 iops_wr=0
drive-ide2: removable=1 locked=0 tray-open=0 io-status=ok file=/var/lib/vz/iso/template/iso/CentOS-6.4-x86_64-minimal.iso ro=1 drv=raw encrypted=0 bps=0 bps_rd=0 bps_wr=0 iops=0 iops_rd=0 iops_wr=0
drive-scsi0: removable=0 io-status=ok file=/var/lib/vz/images/122/vm-122-disk-1.raw ro=0 drv=raw encrypted=0 bps=0 bps_rd=0 bps_wr=0 iops=0 iops_rd=0 iops_wr=0
qm> pci_add auto storage file=/var/lib/vz/images/122/vm-122-disk-5.qcow2,if=virtio
OK domain 0, bus 0, slot 4, function 0
qm> info block
drive-scsi1: removable=0 io-status=ok file=/var/lib/vz/images/122/vm-122-disk-2.qcow2 ro=0 drv=qcow2 encrypted=0 bps=0 bps_rd=0 bps_wr=0 iops=0 iops_rd=0 iops_wr=0
drive-ide2: removable=1 locked=0 tray-open=0 io-status=ok file=/var/lib/vz/iso/template/iso/CentOS-6.4-x86_64-minimal.iso ro=1 drv=raw encrypted=0 bps=0 bps_rd=0 bps_wr=0 iops=0 iops_rd=0 iops_wr=0
drive-scsi0: removable=0 io-status=ok file=/var/lib/vz/images/122/vm-122-disk-1.raw ro=0 drv=raw encrypted=0 bps=0 bps_rd=0 bps_wr=0 iops=0 iops_rd=0 iops_wr=0
virtio0: removable=0 io-status=ok file=/var/lib/vz/images/122/vm-122-disk-5.qcow2 ro=0 drv=qcow2 encrypted=0 bps=0 bps_rd=0 bps_wr=0 iops=0 iops_rd=0 iops_wr=0
qm>
```

We can confirm this on the guest which is still on-line:

```
[root@centos01 ~]# fdisk -l
...

Disk /dev/vda: 10.7 GB, 10737418240 bytes
16 heads, 63 sectors/track, 20805 cylinders
Units = cylinders of 1008 * 512 = 516096 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disk identifier: 0x00000000
```

Example with SCSI disk instead VIRTIO:

```
root@virtual:~# ls -l /var/lib/vz/images/123/vm-123-disk*
-rw-r--r-- 1 root root  8589934592 Mar 11 14:19 /var/lib/vz/images/123/vm-123-disk-1.raw
-rw-r--r-- 1 root root 21478375424 Mar 11 14:19 /var/lib/vz/images/123/vm-123-disk-2.qcow2
root@virtual:~# 

root@virtual:~# qemu-img create -f qcow2 -o size=10G,preallocation=metadata /var/lib/vz/images/123/vm-123-disk-3.qcow2
Formatting '/var/lib/vz/images/123/vm-123-disk-3.qcow2', fmt=qcow2 size=10737418240 encryption=off cluster_size=65536 preallocation='metadata' lazy_refcounts=off 

root@virtual:~# qm monitor 123
Entering Qemu Monitor for VM 123 - type 'help' for help
qm> info block
drive-scsi1: removable=0 io-status=ok file=/var/lib/vz/images/123/vm-123-disk-2.qcow2 ro=0 drv=qcow2 encrypted=0 bps=0 bps_rd=0 bps_wr=0 iops=0 iops_rd=0 iops_wr=0
drive-ide2: removable=1 locked=0 tray-open=0 io-status=ok file=/var/lib/vz/iso/template/iso/CentOS-6.4-x86_64-minimal.iso ro=1 drv=raw encrypted=0 bps=0 bps_rd=0 bps_wr=0 iops=0 iops_rd=0 iops_wr=0
drive-scsi0: removable=0 io-status=ok file=/var/lib/vz/images/123/vm-123-disk-1.raw ro=0 drv=raw encrypted=0 bps=0 bps_rd=0 bps_wr=0 iops=0 iops_rd=0 iops_wr=0
qm> pci_add auto storage file=/var/lib/vz/images/123/vm-123-disk-3.qcow2,if=scsi
OK domain 0, bus 0, slot 4, function 0
qm> info block
drive-scsi1: removable=0 io-status=ok file=/var/lib/vz/images/123/vm-123-disk-2.qcow2 ro=0 drv=qcow2 encrypted=0 bps=0 bps_rd=0 bps_wr=0 iops=0 iops_rd=0 iops_wr=0
drive-ide2: removable=1 locked=0 tray-open=0 io-status=ok file=/var/lib/vz/iso/template/iso/CentOS-6.4-x86_64-minimal.iso ro=1 drv=raw encrypted=0 bps=0 bps_rd=0 bps_wr=0 iops=0 iops_rd=0 iops_wr=0
drive-scsi0: removable=0 io-status=ok file=/var/lib/vz/images/123/vm-123-disk-1.raw ro=0 drv=raw encrypted=0 bps=0 bps_rd=0 bps_wr=0 iops=0 iops_rd=0 iops_wr=0
scsi0-hd0: removable=0 io-status=ok file=/var/lib/vz/images/123/vm-123-disk-3.qcow2 ro=0 drv=qcow2 encrypted=0 bps=0 bps_rd=0 bps_wr=0 iops=0 iops_rd=0 iops_wr=0
qm> 

[root@centos02 ~]# fdisk -l
...

Disk /dev/sdc: 10.7 GB, 10737418240 bytes
64 heads, 32 sectors/track, 10240 cylinders
Units = cylinders of 2048 * 512 = 1048576 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disk identifier: 0x00000000
```

The guest OS should support hot-plugging in the kernel, for this CentOS guest (and other distros with most recent kernels) this is built into the kernel:

```
[root@centos01 ~]# cat /boot/config-2.6.32-573.18.1.el6.x86_64 | grep HOTPLUG_PCI
CONFIG_HOTPLUG_PCI_PCIE=y
CONFIG_HOTPLUG_PCI=y
CONFIG_HOTPLUG_PCI_FAKE=m
CONFIG_HOTPLUG_PCI_ACPI=y
CONFIG_HOTPLUG_PCI_ACPI_IBM=m
# CONFIG_HOTPLUG_PCI_CPCI is not set
CONFIG_HOTPLUG_PCI_SHPC=m
```

For some older Debian/Ubuntu guests we need to load the modules manually and set them to load on start-up:

```
# modprobe acpiphp
# modprobe pci_hotplug
# echo acpiphp >> /etc/modules
# echo pci_hotplug >> /etc/modules
```

For network cards (NIC), lets say on this particular CentOS guest:

```
[root@centos ~]# ifconfig -a
eth1      Link encap:Ethernet  HWaddr C6:76:BB:DA:33:0C  
          inet addr:192.168.0.130  Bcast:192.168.0.255  Mask:255.255.255.0
          inet6 addr: fe80::c476:bbff:feda:330c/64 Scope:Link
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:1285442 errors:0 dropped:0 overruns:0 frame:0
          TX packets:2682 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000 
          RX bytes:108030543 (103.0 MiB)  TX bytes:299083 (292.0 KiB)

lo        Link encap:Local Loopback  
          inet addr:127.0.0.1  Mask:255.0.0.0
          inet6 addr: ::1/128 Scope:Host
          UP LOOPBACK RUNNING  MTU:65536  Metric:1
          RX packets:0 errors:0 dropped:0 overruns:0 frame:0
          TX packets:0 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:0 
          RX bytes:0 (0.0 b)  TX bytes:0 (0.0 b)
```

On the host we add new network device to the guest:

```
root@virtual:~# qm monitor 129
Entering Qemu Monitor for VM 129 - type 'help' for help
qm> info network
net0: index=0,type=nic,model=e1000,macaddr=c6:76:bb:da:33:0c
 \ net0: index=0,type=tap,ifname=tap129i0,script=/var/lib/qemu-server/pve-bridge,downscript=/etc/kvm/kvm-ifdown
qm> pci_add auto nic vlan=0,macaddr=C2:8F:BA:90:44:78,model=virtio
OK domain 0, bus 0, slot 6, function 0
qm> info network
hub 0
 \ virtio-net-pci.0: index=0,type=nic,model=virtio-net-pci,macaddr=c2:8f:ba:90:44:78
net0: index=0,type=nic,model=e1000,macaddr=c6:76:bb:da:33:0c
 \ net0: index=0,type=tap,ifname=tap129i0,script=/var/lib/qemu-server/pve-bridge,downscript=/etc/kvm/kvm-ifdown
qm> quit
root@virtual:~# 
```

Then on the guest we can see the new NIC device strataway:

```
[root@centos ~]# ifconfig -a
eth1      Link encap:Ethernet  HWaddr C6:76:BB:DA:33:0C  
          inet addr:192.168.0.130  Bcast:192.168.0.255  Mask:255.255.255.0
          inet6 addr: fe80::c476:bbff:feda:330c/64 Scope:Link
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:1286707 errors:0 dropped:0 overruns:0 frame:0
          TX packets:2711 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000 
          RX bytes:108116867 (103.1 MiB)  TX bytes:302721 (295.6 KiB)

eth2      Link encap:Ethernet  HWaddr C2:8F:BA:90:44:78  
          BROADCAST MULTICAST  MTU:1500  Metric:1
          RX packets:0 errors:0 dropped:0 overruns:0 frame:0
          TX packets:0 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000 
          RX bytes:0 (0.0 b)  TX bytes:0 (0.0 b)

lo        Link encap:Local Loopback  
          inet addr:127.0.0.1  Mask:255.0.0.0
          inet6 addr: ::1/128 Scope:Host
          UP LOOPBACK RUNNING  MTU:65536  Metric:1
          RX packets:0 errors:0 dropped:0 overruns:0 frame:0
          TX packets:0 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:0 
          RX bytes:0 (0.0 b)  TX bytes:0 (0.0 b)
```
