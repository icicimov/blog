---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Adding ZFS over iSCSI shared storage to Proxmox'
categories: 
  - Virtualization
tags: [kvm, proxmox, high-availability, cluster, iscsi, zfs]
date: 2016-9-21
series: "Highly Available Multi-tenant KVM Virtualization with Proxmox PVE and OpenVSwitch"
---

PVE-4.2 has built in support for ZFS over iSCSI for several targets among which is Solaris `COMSTAR`. I built a ZFS VM appliance based on `OmniOS` (Solaris) and `napp-it` and managed to create a shared storage ZFS pool over iSCSI and launch `vm09` with root device on `zvol`. This also supports live migrations as well. Being an appliance, `napp-it` provides a web UI at `192.168.0.141:81` that we can use to create and manage all our resources. It also supports creating a file shares like NFS and Samba over ZFS.

This is the state on the OmniOS cluster:

```
root@omnios01:/root/.ssh# zpool list
NAME    SIZE  ALLOC   FREE  EXPANDSZ   FRAG    CAP  DEDUP  HEALTH  ALTROOT
pool1  29.8G  9.01G  20.7G         -     8%    30%  1.00x  ONLINE  -
rpool  15.9G  5.03G  10.8G         -    18%    31%  1.00x  ONLINE  -

root@omnios01:/root/.ssh# zfs list
NAME                                        USED  AVAIL  REFER  MOUNTPOINT
pool1                                      7.92G  13.2G  24.0K  /pool1
pool1/vm-109-disk-1                        6.00G  11.3G  6.00G  -
rpool                                      6.06G  9.32G  22.5K  /rpool
rpool/ROOT                                 3.02G  9.32G    19K  legacy
rpool/ROOT/omnios                          3.02G  9.32G  2.38G  /
rpool/ROOT/omnios-backup-1                   65K  9.32G  1.67G  /
rpool/ROOT/omnios-backup-2                    1K  9.32G  2.36G  /
rpool/ROOT/omniosvar                         19K  9.32G    19K  legacy
rpool/ROOT/pre_activate_16.07f_1472100772     1K  9.32G  2.36G  /
rpool/ROOT/pre_napp-it-16.07f                34K  9.32G  1.66G  /
rpool/dump                                 2.00G  9.32G  2.00G  -
rpool/export                                 38K  9.32G    19K  /export
rpool/export/home                            19K  9.32G    19K  /export/home
rpool/proxmox                                 8K  9.32G     8K  -
rpool/swap                                 1.03G  10.4G  2.30M  -
```

We can see the `pool1/vm-109-disk-1` zvol here that Proxmox created upon `vm09` creation. For this to work though we first need to grant root access to the appliance with ssh key from the Proxmox servers. We create the key in Proxmox and add it to the `authorized_keys` file on Omnios. Then we check the connectivity.  

```
root@proxmox01:/etc/pve/priv/zfs# ssh-keygen -t rsa -b 2048 -f 192.168.0.141_id_rsa -N ''
root@proxmox01:/etc/pve/priv/zfs# ssh-copy-id -i /etc/pve/priv/zfs/192.168.0.141_id_rsa root@192.168.0.141
root@proxmox01:/etc/pve/priv/zfs# /usr/bin/ssh -vvv -o 'BatchMode=yes' -o 'StrictHostKeyChecking=no' -i /etc/pve/priv/zfs/192.168.0.141_id_rsa root@192.168.0.141
```

We need to run the last ssh command from both cluster members. If successful then the cluster will gain access to the COMSTAR iSCSI as tested below:

```
root@proxmox02:~# /usr/bin/ssh -o 'BatchMode=yes' -i /etc/pve/priv/zfs/192.168.0.141_id_rsa root@192.168.0.141 zfs list -o name,volsize,origin,type,refquota -t volume,filesystem -Hr
pool1 - - filesystem  none
pool1/vm-109-disk-1 6G  - volume  -
rpool - - filesystem  none
rpool/ROOT  - - filesystem  none
rpool/ROOT/omnios - - filesystem  none
rpool/ROOT/omnios-backup-1  - rpool/ROOT/omnios@2016-08-25-03:44:18 filesystem  none
rpool/ROOT/omnios-backup-2  - rpool/ROOT/omnios@2016-08-25-04:22:55 filesystem  none
rpool/ROOT/omniosvar  - - filesystem  none
rpool/ROOT/pre_activate_16.07f_1472100772 - rpool/ROOT/omnios@2016-08-25-04:52:52 filesystem  none
rpool/ROOT/pre_napp-it-16.07f - rpool/ROOT/omnios@2016-08-25-03:42:19 filesystem  none
rpool/dump  2G  - volume  -
rpool/export  - - filesystem  none
rpool/export/home - - filesystem  none
rpool/proxmox 8G  - volume  -
rpool/swap  1G  - volume  -
```

Of course, we also need to create the COMSTAR iSCSI target in Omnios first manually or via `napp-it` UI before we start anything in Proxmox.

{% include series.html %}