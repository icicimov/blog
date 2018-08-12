---
type: posts
header:
  teaser: 'futuristic-banner.jpg'
title: 'ZFS NAS with NFS and Samba on ROCK64 ARM SBC'
categories: 
  - Server
tags: ['arm','zfs','rock64','samba','nfs']
date: 2018-8-5
---

The old home NAS I built about 3 years ago died on me suddenly. It was a mini-ITX AMD board powered by `freeNAS` with 2 x 1TB Seagate drives in ZFS mirror. Since it is something that is running 24/7 in my home network I've been looking for a low power consumption replacement. With this requirement in mind the ARM SBCs are logical choice. I also wanted to save and continue to use my ZFS data so it needs to have a decent amount of RAM too. The little [ROCK64](https://www.pine64.org/?product=rock64-media-board-computer) with 4GB of RAM just fit the bill.

## Pine ROCK64

Installing the OS was easy, just downloaded the minimal Bionic arm64 image from the [ayufan-rock64 latest stable releases](https://github.com/ayufan-rock64/linux-build/releases/tag/0.7.9) and dumped it with `dd` on the 16GB eMMC card I got with the board.

Next mount the card, boot and install the needed software:

```
root@rock64:~# apt update && apt upgrade
root@rock64:~# apt install build-essential make autogen autoconf libtool gawk alien fakeroot
root@rock64:~# apt install curl wget flex bison dkms
root@rock64:~# apt install zlib1g-dev uuid-dev libattr1-dev libblkid-dev libselinux-dev libudev-dev
root@rock64:~# apt install parted lsscsi ksh libssl-dev libelf-dev
```

I used the [serial console](https://www.pine64.org/?product=padi-serial-console) I got with the board for USB to Serial communication. On my Linux station I used `minicom` serial console terminal emulation software to obtain a login prompt over `/dev/ttyUSB0` on the initial boot up.

```
igorc@silverstone:~$ sudo minicom -s -D /dev/ttyUSB0 -b 1500000 --color=on
```

See the link from the PINE64 forum in the `References` section for details.

## ZFS

For the ZFS setup I followed a thread I found in the `Armbian` forum, see `References` below. Basically ran:

```
root@rock64:~# apt install spl-dkms zfs-dkms
```

which failed and then followed the instructions as mentioned. That gave me a working ZFS and SPL kernel modules:

```
root@rock64:~# date
Sun Aug  5 16:26:58 AEST 2018

root@rock64:~# dkms status
spl, 0.7.5, 4.4.132-1075-rockchip-ayufan-ga83beded8524, aarch64: installed
zfs, 0.7.5, 4.4.132-1075-rockchip-ayufan-ga83beded8524, aarch64: installed

root@rock64:~# uname -a
Linux rock64 4.4.132-1075-rockchip-ayufan-ga83beded8524 #1 SMP Thu Jul 26 08:22:22 UTC 2018 aarch64 aarch64 aarch64 GNU/Linux
```

Next was the ZFS array import from the old server. Attach the disks from the failed server: 

```
root@rock64:~# dmesg | tail
[   55.054153] scsi 0:0:0:0: Direct-Access     ASMedia  ASM105x          0    PQ: 0 ANSI: 6
[   55.057086] sd 0:0:0:0: [sda] 1953525168 512-byte logical blocks: (1.00 TB/932 GiB)
[   55.057117] sd 0:0:0:0: [sda] 4096-byte physical blocks
[   55.059232] sd 0:0:0:0: [sda] Write Protect is off
[   55.059269] sd 0:0:0:0: [sda] Mode Sense: 43 00 00 00
[   55.060113] sd 0:0:0:0: [sda] Write cache: enabled, read cache: enabled, doesn't support DPO or FUA
[   55.060357] xhci-hcd xhci-hcd.9.auto: ERROR Transfer event for disabled endpoint or incorrect stream ring
[   55.061781] xhci-hcd xhci-hcd.9.auto: @00000000f2e3ceb0 00000000 00000000 1b000000 03038001
[   55.138002]  sda: sda1 sda2
[   55.144633] sd 0:0:0:0: [sda] Attached SCSI disk

root@rock64:~# dmesg | tail
[  127.224468] scsi 1:0:0:0: Direct-Access     ASMedia  ASM105x          0    PQ: 0 ANSI: 6
[  127.227223] sd 1:0:0:0: [sdb] 1953525168 512-byte logical blocks: (1.00 TB/932 GiB)
[  127.227255] sd 1:0:0:0: [sdb] 4096-byte physical blocks
[  127.228368] sd 1:0:0:0: [sdb] Write Protect is off
[  127.228405] sd 1:0:0:0: [sdb] Mode Sense: 43 00 00 00
[  127.229005] sd 1:0:0:0: [sdb] Write cache: enabled, read cache: enabled, doesn't support DPO or FUA
[  127.229247] xhci-hcd xhci-hcd.9.auto: ERROR Transfer event for disabled endpoint or incorrect stream ring
[  127.230677] xhci-hcd xhci-hcd.9.auto: @00000000f2e3c9b0 00000000 00000000 1b000000 04038001
[  127.315168]  sdb: sdb1 sdb2
[  127.319599] sd 1:0:0:0: [sdb] Attached SCSI disk

root@rock64:~# fdisk -l /dev/sda
Disk /dev/sda: 931.5 GiB, 1000204886016 bytes, 1953525168 sectors
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 4096 bytes
I/O size (minimum/optimal): 4096 bytes / 33553920 bytes
Disklabel type: gpt
Disk identifier: 0B90228D-4C20-11E2-87AD-BC5FF4446220

Device       Start        End    Sectors   Size Type
/dev/sda1      128    4194431    4194304     2G FreeBSD swap
/dev/sda2  4194432 1953525127 1949330696 929.5G FreeBSD ZFS

root@rock64:~# fdisk -l /dev/sdb
Disk /dev/sdb: 931.5 GiB, 1000204886016 bytes, 1953525168 sectors
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 4096 bytes
I/O size (minimum/optimal): 4096 bytes / 33553920 bytes
Disklabel type: gpt
Disk identifier: 0B100901-4C20-11E2-87AD-BC5FF4446220

Device       Start        End    Sectors   Size Type
/dev/sdb1      128    4194431    4194304     2G FreeBSD swap
/dev/sdb2  4194432 1953525127 1949330696 929.5G FreeBSD ZFS
```
and import the ZFS Pool:

```
root@rock64:~# zpool import -a
cannot import 'volume1': pool was previously in use from another system.
Last accessed by  (hostid=fe4ac89c) at Sat Apr 28 20:28:30 2018
The pool can be imported, use 'zpool import -f' to import the pool.

root@rock64:~# zpool import -f
   pool: volume1
     id: 13301200160306108983
  state: ONLINE
 status: The pool was last accessed by another system.
 action: The pool can be imported using its name or numeric identifier and
    the '-f' flag.
   see: http://zfsonlinux.org/msg/ZFS-8000-EY
 config:

    volume1     ONLINE
      mirror-0  ONLINE
        sdb     ONLINE
        sda     ONLINE

root@rock64:~# zpool status
no pools available

root@rock64:~# zpool import -f 13301200160306108983
root@rock64:~# zpool status volume1
  pool: volume1
 state: ONLINE
status: The pool is formatted using a legacy on-disk format.  The pool can
    still be used, but some features are unavailable.
action: Upgrade the pool using 'zpool upgrade'.  Once this is done, the
    pool will no longer be accessible on software that does not support
    feature flags.
  scan: none requested
config:

    NAME        STATE     READ WRITE CKSUM
    volume1     ONLINE       0     0     0
      mirror-0  ONLINE       0     0     0
        sdb     ONLINE       0     0     0
        sda     ONLINE       0     0     0

errors: No known data errors

root@rock64:~# zpool list
NAME      SIZE  ALLOC   FREE  EXPANDSZ   FRAG    CAP  DEDUP  HEALTH  ALTROOT
volume1   928G   532G   396G         -      -    57%  1.00x  ONLINE  -

root@rock64:~# zfs list
NAME              USED  AVAIL  REFER  MOUNTPOINT
volume1           532G   367G   200K  /volume1
volume1/Linux     479G   367G   475G  /volume1/Linux
volume1/Windows  53.5G   367G  53.5G  /volume1/Windows

root@rock64:~# ls -l /volume1/
total 33
drwxr-xr-x 15 nobody nogroup 20 Apr 28 20:28 Linux
drwxrwxrwx 19 nobody nogroup 20 Jul  7  2015 Windows
```

Then enabled compression on the datasets:

```
root@rock64:~# zpool set feature@lz4_compress=enabled volume1
root@rock64:~# zfs set compression=lz4 volume1
root@rock64:~# zfs set compression=lz4 volume1/Linux
root@rock64:~# zfs set atime=off volume1
root@rock64:~# zfs get all volume1/Linux
```

## Sharing

Install the needed packages:

```
root@rock64:~# apt install nfs-kernel-server open-iscsi watchdog xattr samba samba-client acl smartmontools mailutils
```

### NFS

I decided to go the pure NFS way here instead the built-in ZFS with `sharenfs=on`. For the bind mount to work the `x-systemd.requires=zfs-mount.service` option in `/etc/fstab` is important so it waits for ZFS to mount its volumes first:

```
root@rock64:~# mkdir -p /export/Linux
root@rock64:~# mount --bind /volume1/Linux /export/Linux

root@rock64:~# vi /etc/fstab
[...]
/volume1/Linux /export/Linux none bind,defaults,nofail,x-systemd.requires=zfs-mount.service 0 0
```

The the exports file:

```
root@rock64:~# vi /etc/exports
[...]
/export            192.168.1.0/24(ro,root_squash,no_subtree_check,fsid=0,crossmnt)
/export/Linux      192.168.1.0/24(rw,async,root_squash,no_subtree_check)

root@rock64:~# exportfs -rav
exporting 192.168.1.0/24:/export/Linux
exporting 192.168.1.0/24:/export

root@rock64:~# systemctl enable rpcbind nfs-server
```

On the client:

```
igorc@silverstone:~$ showmount -e 192.168.1.15
Export list for 192.168.1.15:
/export/Linux 192.168.1.0/24
/export       192.168.1.0/24

igorc@silverstone:~$ sudo mkdir -p /mnt/nfs/freenas
igorc@silverstone:~$ sudo mount -t nfs -o rw,soft,tcp,nolock,rsize=32768,wsize=32768,vers=4 192.168.1.15:/Linux /mnt/nfs/freenas
igorc@silverstone:~$ grep freenas /proc/mounts 
192.168.1.15:/Linux /mnt/nfs/freenas nfs4 rw,relatime,vers=4.0,rsize=32768,wsize=32768,namlen=255,soft,proto=tcp,port=0,timeo=600,retrans=2,sec=sys,clientaddr=192.168.1.16,local_lock=none,addr=192.168.1.15 0 0
```

Configure `autofs` for auto mounting:

```
igorc@silverstone:~$ cat /etc/auto.master
[...]
+auto.master
/mnt/nfs    /etc/auto.nfs --timeout=30 --ghost

igorc@silverstone:~$ cat /etc/auto.nfs 
freenas -fstype=nfs,rw,soft,tcp,nolock,rsize=32768,wsize=32768,vers=4 192.168.1.15:/Linux
```

Remove the mount and restart the service:

```
igorc@silverstone:~$ sudo umount /mnt/nfs/freenas
igorc@silverstone:~$ sudo service autofs restart

```

Now every time a client tries to access `/mnt/nfs/freenas` on the client the share will get auto mounted from the server.

### SAMBA

For this one I decided to export via ZFS. Make sure the SAMBA service is running:

```
root@rock64:~# systemctl status smbd.service
 smbd.service - Samba SMB Daemon
   Loaded: loaded (/lib/systemd/system/smbd.service; enabled; vendor preset: enabled)
   Active: active (running) since Sat 2018-08-11 18:23:51 AEST; 1h 19min ago
     Docs: man:smbd(8)
           man:samba(7)
           man:smb.conf(5)
 Main PID: 2310 (smbd)
   Status: "smbd: ready to serve connections..."
    Tasks: 4 (limit: 4700)
   CGroup: /system.slice/smbd.service
           ├─2310 /usr/sbin/smbd --foreground --no-process-group
           ├─2312 /usr/sbin/smbd --foreground --no-process-group
           ├─2313 /usr/sbin/smbd --foreground --no-process-group
           └─2315 /usr/sbin/smbd --foreground --no-process-group

Aug 11 18:23:51 rock64 systemd[1]: Starting Samba SMB Daemon...
Aug 11 18:23:51 rock64 systemd[1]: Started Samba SMB Daemon.
```

then export the ZFS dataset:

```
root@rock64:~# zfs set sharesmb=on volume1/Windows

root@rock64:~# cat /var/lib/samba/usershares/volume1_windows 
#VERSION 2
path=/volume1/Windows
comment=Comment: /volume1/Windows
usershare_acl=S-1-1-0:F
guest_ok=n
sharename=volume1_Windows
```

Check the access locally:

```
root@rock64:~# smbclient -U guest -N -L localhost
WARNING: The "syslog" option is deprecated

    Sharename       Type      Comment
    ---------       ----      -------
    print$          Disk      Printer Drivers
    IPC$            IPC       IPC Service (rock64 server (Samba, Ubuntu))
    volume1_Windows Disk      Comment: /volume1/Windows
Reconnecting with SMB1 for workgroup listing.

    Server               Comment
    ---------            -------

    Workgroup            Master
    ---------            -------
    HOMENET              SILVERSTONE
    MSHOME               MYTHTV
    HOMENET              ROCK64
```

and set a user:

```
root@rock64:~# smbpasswd -a rock64
New SMB password:
Retype new SMB password:
Added user rock64.
```

On the client:

```
igorc@silverstone:~$ sudo mount -t cifs -o rw,username=rock64,password=password,file_mode=0777,dir_mode=0777 //192.168.1.15/volume1_Windows /mnt/cifs/freenas
```

then set auto mount via autofs:

```
igorc@silverstone:~$ cat /etc/auto.master
[...]
+auto.master
/mnt/nfs    /etc/auto.nfs --timeout=30 --ghost
/mnt/cifs   /etc/auto.cifs --timeout=30 --ghost

igorc@silverstone:~$ cat /etc/auto.cifs
freenas -fstype=cifs,rw,username=rock64,password=password,file_mode=0777,dir_mode=0777 ://192.168.1.15/volume1_Windows
```

## References

* [How to Setup Serial Console Cable Over the Rock64 SBC](https://forum.pine64.org/showthread.php?tid=5029)
* [Build ZFS on RK3328](https://forum.armbian.com/topic/6789-build-zfs-on-rk3328/?tab=comments#comment-53681)
* [ayufan-rock64](https://github.com/ayufan-rock64/linux-build/)
