---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'HA Features in Proxmox PVE cluster and final words'
categories: 
  - Virtualization
tags: [kvm, proxmox, high-availability, cluster]
date: 2016-9-22
series: "Highly Available Multi-tenant KVM Virtualization with Proxmox PVE and OpenVSwitch"
gallery:
  - url: pve-4.2_01.png
    image_path: pve-4.2_01_600x300.png
    alt: "placeholder image 1"
    title: "VM on DRBD storage"
  - url: pve-4.2_02.png
    image_path: pve-4.2_02_600x300.png
    alt: "placeholder image 2"
    title: "VM on DRBD storage"
  - url: pve-4.2_03.png
    image_path: pve-4.2_03_600x300.png
    alt: "placeholder image 3"
    title: "VM on iSCSI storage"
  - url: pve-4.2_04.png
    image_path: pve-4.2_04_600x300.png
    alt: "placeholder image 4"
    title: "VM on ZFS over iSCSI storage"
  - url: pve-4.2_05.png
    image_path: pve-4.2_05_600x300.png
    alt: "placeholder image 5"
    title: "VM on CEPH storage"
  - url: pve-4.2_06.png
    image_path: pve-4.2_06_600x300.png
    alt: "placeholder image 6"
    title: "Datacenter shared storage types"
  - url: pve-4.2_07.png
    image_path: pve-4.2_07_600x300.png
    alt: "placeholder image 7"
    title: "HA instances in the cluster"
  - url: pve-4.2_08.png
    image_path: pve-4.2_08_600x300.png
    alt: "placeholder image 8"
    title: "Networks in the cluster"
---

At the end, some testing of the High Availability fatures in PVE 4.2 on node and VM/LXC level. 

## Instance Migration

Migrating (moving) LXC and VM instances from one node to the other when the instance is stopped works without any issues given the instance does not have a locally attached CD-ROM drive. We can use the GUI for this pusrpose but it is possible via the CLI too, it is simple as:

```
root@proxmox01:~# ha-manager migrate vm:102 proxmox02
```

For live migration, ie the VM instance is running, the VM's root disk needs to be created on a shared storage (and any other secondary attached disks too for that matter). Then the VM can be migrated with no downtime using the GUI or the CLI command from above. Log of a successful live VM migration of `vm104` with root disk on GlusterFS cluster storage:

```
May 02 10:57:01 starting migration of VM 104 to node 'proxmox02' (192.168.0.186)
May 02 10:57:01 copying disk images
May 02 10:57:01 starting VM 104 on remote node 'proxmox02'
May 02 10:57:04 starting ssh migration tunnel
May 02 10:57:05 starting online/live migration on localhost:60000
May 02 10:57:05 migrate_set_speed: 8589934592
May 02 10:57:05 migrate_set_downtime: 0.1
May 02 10:57:07 migration speed: 256.00 MB/s - downtime 15 ms
May 02 10:57:07 migration status: completed
May 02 10:57:11 migration finished successfully (duration 00:00:10)
TASK OK
```

The same was successfully tested for VM with root disk on DRBD storage. Here we can see the moving of `vm105` from one node to the other while the instance was running:

```
May 06 17:40:25 starting migration of VM 105 to node 'proxmox01' (192.168.0.185)
May 06 17:40:25 copying disk images
May 06 17:40:25 starting VM 105 on remote node 'proxmox01'
May 06 17:40:29 starting ssh migration tunnel
bind: Cannot assign requested address
May 06 17:40:30 starting online/live migration on localhost:60000
May 06 17:40:30 migrate_set_speed: 8589934592
May 06 17:40:30 migrate_set_downtime: 0.1
May 06 17:40:32 migration status: active (transferred 197603120, remaining 32460800), total 1082990592)
May 06 17:40:32 migration xbzrle cachesize: 67108864 transferred 0 pages 0 cachemiss 0 overflow 0
May 06 17:40:34 migration speed: 256.00 MB/s - downtime 7 ms
May 06 17:40:34 migration status: completed
May 06 17:40:39 migration finished successfully (duration 00:00:14)
TASK OK
```

Finally example of moving an instance with root device on the iSCSI shared storage:

```
May 10 14:25:24 starting migration of VM 108 to node 'proxmox02' (192.168.0.186)
May 10 14:25:24 copying disk images
May 10 14:25:24 starting VM 108 on remote node 'proxmox02'
May 10 14:25:30 starting ssh migration tunnel
bind: Cannot assign requested address
May 10 14:25:31 starting online/live migration on localhost:60000
May 10 14:25:31 migrate_set_speed: 8589934592
May 10 14:25:31 migrate_set_downtime: 0.1
May 10 14:25:33 migration status: active (transferred 172760414, remaining 292511744), total 546119680)
May 10 14:25:33 migration xbzrle cachesize: 33554432 transferred 0 pages 0 cachemiss 0 overflow 0
May 10 14:25:35 migration status: active (transferred 347832453, remaining 116248576), total 546119680)
May 10 14:25:35 migration xbzrle cachesize: 33554432 transferred 0 pages 0 cachemiss 0 overflow 0
May 10 14:25:37 migration status: active (transferred 484694399, remaining 50982912), total 546119680)
May 10 14:25:37 migration xbzrle cachesize: 33554432 transferred 0 pages 0 cachemiss 7395 overflow 0
May 10 14:25:38 migration status: active (transferred 504344383, remaining 31371264), total 546119680)
May 10 14:25:38 migration xbzrle cachesize: 33554432 transferred 0 pages 0 cachemiss 12183 overflow 0
May 10 14:25:38 migration status: active (transferred 533482842, remaining 12886016), total 546119680)
May 10 14:25:38 migration xbzrle cachesize: 33554432 transferred 0 pages 0 cachemiss 19283 overflow 0
May 10 14:25:38 migration speed: 73.14 MB/s - downtime 102 ms
May 10 14:25:38 migration status: completed
May 10 14:25:44 migration finished successfully (duration 00:00:20)
TASK OK
```

## Node failure

I have also tested the scenario of node failure by shutting down the `proxmox02` cluster node. The VM's running on this node automatically migrated to `proxmox01` instance and started up successfully (this can be seen on one of the screen shots attached for PVE-4.2 at the bottom of this page). The VM's need to be added to the HA group and marked for autostart for this to happen.

# Conclusion

Proxmox PVE has proved as very robust and feature reach open source virtualization environment for KVM and LXC. Proxmox VE 4 supports clusters of up to 32 physical nodes. The centralized Proxmox management makes it easy to configure all available nodes from one place. No SPOF (Single Point of Failure) when using a cluster, we can connect to any node to manage the entire cluster. The management is done through a Web console, based on a javascript frameworks, and gives the administrator a full control over every aspect of the infrastructure.

It supports Local Storage, FC, iSCSI, NFS, ZFS and CEPH as storage technologies which is really impressive. If VM/LXC is created as HA instance with disk(s) on shared storage it can easily be live migrated between the nodes. The integrated backup tool creates snapshots of virtual guests both for LXC and KVM all managed through the web UI console and CLI if needed. In practice it creates a tarball of the VM or CT data that includes the virtual disks and all the configuration data.

The networking supports Linux Bridges and OpenVSwitch which can easily be extended to SDN overlay as described above. For added flexibility, it supports VLAN's (IEEE 802.1 Q), bonding and network aggregations allowing us to build complex flexible virtual networks for the hosts.


## Screen shots
	
{% include gallery caption="Proxmox PVE" %}			

## Resources

* [Proxmox PVE](https://pve.proxmox.com/wiki/High_Availability_Cluster_4.x)
* [OpenVSwitch](http://openvswitch.org/support/config-cookbooks/port-tunneling/)

{% include series.html %}