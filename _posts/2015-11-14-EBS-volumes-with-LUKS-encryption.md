---
type: posts
header:
  teaser: 'images.jpg'
title: 'EBS volumes with LUKS encryption'
categories: 
  - Server
tags: ['luks', 'aws']
date: 2015-11-14
---

## Introduction

Encrypting data at rest provides protection of sensitive information stored on EBS volumes. When taking snapshots of encrypted volumes the snapshots are encrypted as well. When the volume is attached to a EC2 instance and mounted, the volume is unlocked and thus all the data available for access like on any other normal drive. In case the instance is compromised the attacker will gain free access to the data, hence the terminology "encryption at rest".

We have couple of options to protect our data at rest in AWS VPC. We can use recently provided EBS encrypted volumes or maintain our own solution with one of the currently popular encryptions like LUKS. The advantage of using the EBS provided one is that we don't have to worry about maintenance of the encryption keys and unlocking the volumes upon startup so they are available to the applications. This is too big advantage to ignore and obvious choice in case we want to proceed down the encryption path. But for the sake of gathering some performance data I gave LUKS a go.

## Setup

I'll be using striped LVM and setup some logical volumes to use for LUKS on two 100GB SSD drives which gives us 300/3000 IOPS attached to m3.large instance:

```bash
root@ip-172-31-13-210:~# pvcreate /dev/xvdh
  Physical volume "/dev/xvdh" successfully created
 
root@ip-172-31-13-210:~# pvcreate /dev/xvdi
  Physical volume "/dev/xvdi" successfully created
 
root@ip-172-31-13-210:~# pvs
  PV         VG   Fmt  Attr PSize   PFree 
  /dev/xvdh       lvm2 a--  100.00g 100.00g
  /dev/xvdi       lvm2 a--  100.00g 100.00g
 
root@ip-172-31-13-210:~# vgcreate vg_luks /dev/xvdh /dev/xvdi
  Volume group "vg_luks" successfully created
 
root@ip-172-31-13-210:~# lvcreate -i2 -I4 -l 100%VG -n lv_luks vg_luks
  Logical volume "lv_luks" created
 
root@ip-172-31-13-210:~# vgs
  VG      #PV #LV #SN Attr   VSize   VFree
  vg_luks   2   1   0 wz--n- 199.99g    0
 
root@ip-172-31-13-210:~# lvs
  LV      VG      Attr      LSize   Pool Origin Data%  Move Log Copy%  Convert
  lv_luks vg_luks -wi-a---- 199.99g
```

Next I have to create LUKS key(s) for my encryption.

```bash
root@ip-172-31-13-210:~# dd if=/dev/urandom of=luks1.key bs=4k count=1
1+0 records in
1+0 records out
4096 bytes (4.1 kB) copied, 0.000576579 s, 7.1 MB/s
 
root@ip-172-31-13-210:~# dd if=/dev/urandom of=luks2.key bs=4k count=1
1+0 records in
1+0 records out
4096 bytes (4.1 kB) copied, 0.000588873 s, 7.0 MB/s
```

I create pair of keys in case one gets lost. If these keys get lost we can not decrypt the data any more so the keys MUST be stored safely in multiple places for backup. Then we setup LUKS:

```bash
root@ip-172-31-13-210:~# modprobe dm-crypt
root@ip-172-31-13-210:~# modprobe rmd160
root@ip-172-31-13-210:~# cryptsetup luksFormat --cipher aes-cbc-essiv:sha256 --hash ripemd160 --key-size 256 /dev/vg_luks/lv_luks luks1.key
root@ip-172-31-13-210:~# cryptsetup luksAddKey --key-file luks1.key /dev/vg_luks/lv_luks luks2.key
```

Open the LUKS encrypted volume:

```bash
root@ip-172-31-13-210:~# cryptsetup luksOpen --key-file luks1.key /dev/vg_luks/lv_luks lv_luks_encrypted
```

New device will be created:

```bash
root@ip-172-31-13-210:~# ls -l /dev/mapper/lv_luks_encrypted
lrwxrwxrwx 1 root root 7 Oct 27 15:26 /dev/mapper/lv_luks_encrypted -> ../dm-1
```

which we can format, mount and use as any other normal device:

```bash
root@ip-172-31-13-210:~# mkfs -t xfs -L LUKS /dev/mapper/lv_luks_encrypted
meta-data=/dev/mapper/lv_luks_encrypted isize=256    agcount=16, agsize=3276639 blks
         =                       sectsz=512   attr=2, projid32bit=0
data     =                       bsize=4096   blocks=52426224, imaxpct=25
         =                       sunit=1      swidth=2 blks
naming   =version 2              bsize=4096   ascii-ci=0
log      =internal log           bsize=4096   blocks=25598, version=2
         =                       sectsz=512   sunit=1 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0
 
root@ip-172-31-13-210:~# mkdir /mnt/luks
root@ip-172-31-13-210:~# mount -t xfs -o rw,noatime,nouuid /dev/mapper/lv_luks_encrypted /mnt/luks
root@ip-172-31-13-210:~# cat /proc/mounts | grep luks
/dev/mapper/lv_luks_encrypted /mnt/luks xfs rw,noatime,nouuid,attr2,inode64,sunit=8,swidth=16,noquota 0 0
```

## Performance testing

Testing using dd tool.

Write:

```bash
root@ip-172-31-13-210:~# dd if=/dev/zero of=/mnt/luks/test.img bs=4MB count=6000 && sync;sync
1987+0 records in
1987+0 records out
7948000000 bytes (7.9 GB) copied, 128.673 s, 61.8 MB/s
5550+0 records in
5550+0 records out
22200000000 bytes (22 GB) copied, 379.105 s, 58.6 MB/s
6000+0 records in
6000+0 records out
24000000000 bytes (24 GB) copied, 404.974 s, 59.3 MB/s
```

Read:

```bash
root@ip-172-31-13-210:~# dd of=/dev/null if=/mnt/luks/test.img bs=4MB count=6000
393+0 records in
392+0 records out
1568000000 bytes (1.6 GB) copied, 21.845 s, 71.8 MB/s
1375+0 records in
1374+0 records out
5496000000 bytes (5.5 GB) copied, 86.7907 s, 63.3 MB/s
3267+0 records in
3266+0 records out
13064000000 bytes (13 GB) copied, 211.838 s, 61.7 MB/s
6000+0 records in
6000+0 records out
24000000000 bytes (24 GB) copied, 392.59 s, 61.1 MB/s
```

So no much difference between read and write performance with steady throughput of around 60MB/s.

For the results to make some sense lets compare it with a single drive test, 100GB 300/3000 IOPS, no LVM stripping, both encrypted and without encryption:

Read: SSD plain

```bash
root@ip-172-31-13-210:~# dd of=/dev/null if=/dev/xvdf bs=4MB count=6000
554+0 records in
553+0 records out
2212000000 bytes (2.2 GB) copied, 42.4126 s, 52.2 MB/s
2008+0 records in
2007+0 records out
8028000000 bytes (8.0 GB) copied, 202.391 s, 39.7 MB/s
2724+0 records in
2723+0 records out
10892000000 bytes (11 GB) copied, 280.383 s, 38.8 MB/s
6000+0 records in
6000+0 records out
24000000000 bytes (24 GB) copied, 651.021 s, 36.9 MB/s
```

Read: SSD with encryption

```bash
root@ip-172-31-13-210:~# dd of=/dev/null if=/dev/xvdg bs=4MB count=6000
192+0 records in
191+0 records out
764000000 bytes (764 MB) copied, 31.8055 s, 24.0 MB/s
1145+0 records in
1144+0 records out
4576000000 bytes (4.6 GB) copied, 187.18 s, 24.4 MB/s
1617+0 records in
1616+0 records out
6464000000 bytes (6.5 GB) copied, 265.245 s, 24.4 MB/s
6000+0 records in
6000+0 records out
24000000000 bytes (24 GB) copied, 768.789 s, 31.2 MB/s
```

Write: SSD plain

```bash
root@ip-172-31-13-210:~# dd if=/dev/zero of=/dev/xvdf bs=4MB count=6000 && sync;sync
887+0 records in
887+0 records out
3548000000 bytes (3.5 GB) copied, 43.9896 s, 80.7 MB/s
4210+0 records in
4210+0 records out
16840000000 bytes (17 GB) copied, 297.76 s, 56.6 MB/s
5901+0 records in
5901+0 records out
23604000000 bytes (24 GB) copied, 555.318 s, 42.5 MB/s
6000+0 records in
6000+0 records out
24000000000 bytes (24 GB) copied, 571.07 s, 42.0 MB/s
```

Write: SSD with encryption

```bash
root@ip-172-31-13-210:~# dd if=/dev/zero of=/dev/xvdg bs=4MB count=6000
101+0 records in
101+0 records out
404000000 bytes (404 MB) copied, 33.5545 s, 12.0 MB/s
579+0 records in
579+0 records out
2316000000 bytes (2.3 GB) copied, 284.987 s, 8.1 MB/s
802+0 records in
802+0 records out
3208000000 bytes (3.2 GB) copied, 541.793 s, 5.9 MB/s
6000+0 records in
6000+0 records out
24000000000 bytes (24 GB) copied, 813.996 s, 29.5 MB/s
```

So for a single drive LUKS really hurts the performance. Looks like with encryption the striped LVM or RAID mirror is the way to go if we want to keep the disk performance on reasonable level.

## Things to consider and common tasks when LUKS involved

### Detaching EBS Volumes

If we ever want to detach an EBS volume while the instance is still running, we'll need to perform a few operations first. We need to unmount the file system, close LUKS, and disable LVM.

```bash
$ sudo umount /mnt/luks
$ sudo cryptsetup luksClose lv_luks_encrypted
$ sudo vgchange -an vg_luks
```

We can now detach the EBS volumes from the instance.

### Shutdown & Reboot

There is no special procedure or commands needed to reboot or shutdown the machine. Operate as you normally would.

```bash
$ sudo reboot
$ sudo shutdown -h now
```

Then Stop/Terminate from the AWS console.

### Startup

The encrypted volume will not show up automatically when we boot up. It first needs to be unlocked using one of the encryption keys:

```bash
$ sudo cryptsetup luksOpen --key-file <key file> /dev/vg_luks/lv_luks lv_luks_encrypted
$ sudo mount /mnt/luks
```

Obviously this needs to be automated via instance user-data and/or IAM roles so the instance downloads the keys from some secure storage and performs the above operation before we start our applications. The key should be then removed for security reasons.

### Increase Disk Space by Adding More Disks

The new disks to be added don't have to be the same size as previously added disks, but should be the same size as all other new disks to be added right now. First, we attach the new EBS volumes to the instance and then we run:

```bash
$ sudo pvcreate /dev/xvdj
$ sudo pvcreate /dev/xvdk

$ sudo vgextend vg_luks /dev/xvdj
$ sudo vgextend vg_luks /dev/xvdk
 
$ sudo lvextend -i4 -I4 -l100%VG /dev/vg_luks/lv_luks
$ sudo cryptsetup resize /dev/mapper/lv_luks_encrypted
$ sudo xfs_growfs /mnt/luks
```
