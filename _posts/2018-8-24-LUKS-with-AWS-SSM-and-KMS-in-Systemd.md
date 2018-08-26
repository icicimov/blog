---
type: posts
header:
  teaser: 'images.jpg'
title: 'Disk encryption in rest with LUKS and AWS SSM and KMS services in Systemd'
categories: 
  - Server
tags: ['luks', 'aws']
date: 2018-8-24
---

Implementing disk encryption-at-rest in secure and automated way can be challenging. After we are done with the disk encryption we are often faced with the problem of supplying sensitive data like password or key file needed to unlock and mount the encrypted device on server startup or cluster fail over. And most probably we need to do this in an automated way without any human intervention for our production environments which are hosted in public cloud or shared Data Center. 

Cloud providers like AWS can help simplify this task via services like IAM, SSM Parameter Store and KMS (Key Management Service) in centralized and standardized manner. They can take over the best part of the tasks related to the Master Encryption Key management like highly available storage and redundancy, security and key rotation. We can use SSM to store the LUKS encryption key password for example and do it in secure way since it integrates with KMS in the background. Using IAM we can control the user access to the assets via Roles and Policies.

Assuming we have created our Master Encryption key `alias/MASTER_KEY` in KMS, us-east-1 region, the following IAM Policy gives limited access to the key for encryption and decryption purposes plus read-only access rights to SSM Parameter Store to retrieve the encrypted Password we will use for LUKS encryption:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "kms:Encrypt",
                "kms:Decrypt",
                "kms:ReEncrypt*",
                "kms:GenerateDataKey*",
                "kms:DescribeKey"
            ],
            "Resource": [
                "arn:aws:kms:us-east-1:account-id:alias/MASTER_KEY"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "ssm:GetParametersByPath",
                "ssm:GetParameters",
                "ssm:GetParameter"
            ],
            "Resource": [
                "arn:aws:ssm:us-east-1:account-id:parameter/luks/test/*"
            ]
        }
    ]
}
```

We can create the SSM parameter using `awscli` utility:

```bash
$ aws ssm put-parameter --name '/luks/test/key' --value '<our-luks-password>' --type SecureString --key-id 'alias/MASTER_KEY' --region=us-east-1
```

This will upload our password to the SSM store and encrypt it with our master KMS key. Later we can fetch the password from any machine anywhere in the world given the machine has `awscli` installed (or any other AWS SDK utility and custom piece of code): 

```bash
$ aws ssm get-parameters-by-path --path='/luks/test/key' --with-decryption --region=us-east-1
```

and the user running the command on the machine has the IAM users AWS access and secret keys configured under `~/.aws/` directory. This IAM user needs to have the above created IAM policy attached to it.

Now lets move to the server where we need the LUKS encryption to happen and go through the disk encryption process manually first, utilizing the AWS resources we created.

```bash
root@server:~# modprobe -v dm-crypt
insmod /lib/modules/4.4.0-1066-aws/kernel/drivers/md/dm-crypt.ko 

root@server:~# modprobe -v rmd160
insmod /lib/modules/4.4.0-1066-aws/kernel/crypto/rmd160.ko'

root@server:~# PASSWD=$(aws ssm get-parameters-by-path --path='/luks/test/key' --with-decryption --region=us-east-1)
root@server:~# echo -n "$PASSWD" | cryptsetup luksFormat --cipher aes-cbc-essiv:sha256 --hash ripemd160 --key-size 256 /dev/nvme1n1

root@server:~# cryptsetup -v isLuks /dev/nvme1n1
Command successful

root@server:~# cryptsetup luksUUID /dev/nvme1n1
aa17c97e-f643-4ce2-90a0-3dc64cc88b72

root@server:~# UUID=$(cryptsetup luksUUID /dev/nvme1n1)
root@server:~# echo -n "$PASSWD" | cryptsetup luksOpen UUID=${UUID} virtualfs

root@server:~# ls -l /dev/mapper/virtualfs
lrwxrwxrwx 1 root root 7 Aug 24 12:23 /dev/mapper/virtualfs -> ../dm-0

root@server:~# cryptsetup status virtualfs
/dev/mapper/virtualfs is active.
  type:    LUKS1
  cipher:  aes-cbc-essiv:sha256
  keysize: 256 bits
  device:  /dev/nvme1n1
  offset:  4096 sectors
  size:    16773120 sectors
  mode:    read/write

root@server:~# cryptsetup luksDump /dev/nvme1n1
LUKS header information for /dev/nvme1n1

Version:        1
Cipher name:    aes
Cipher mode:    cbc-essiv:sha256
Hash spec:      ripemd160
Payload offset: 4096
MK bits:        256
MK digest:      49 e0 77 15 1b d5 95 12 b6 83 4e a8 5a e0 60 38 16 51 90 e9 
MK salt:        61 0a bc 31 06 26 28 23 07 10 34 e0 01 d4 7d 48 
                36 b0 45 f2 87 6d 0d d7 a6 90 85 93 5a 55 05 03 
MK iterations:  62875
UUID:           aa17c97e-f643-4ce2-90a0-3dc64cc88b72

Key Slot 0: ENABLED
    Iterations:             251967
    Salt:                   c2 8e 68 b0 8a bb a3 de 6c c0 28 d3 d9 70 90 34 
                            72 2e 85 00 f2 d1 fe ac 73 75 66 f1 ce 9d e7 08 
    Key material offset:    8
    AF stripes:             4000
Key Slot 1: DISABLED
Key Slot 2: DISABLED
Key Slot 3: DISABLED
Key Slot 4: DISABLED
Key Slot 5: DISABLED
Key Slot 6: DISABLED
Key Slot 7: DISABLED

root@server:~# unset PASSWD

root@server:~# mkfs -t xfs -L LUKS /dev/mapper/virtualfs
meta-data=/dev/mapper/virtualfs  isize=512    agcount=4, agsize=524160 blks
         =                       sectsz=512   attr=2, projid32bit=1
         =                       crc=1        finobt=1, sparse=0
data     =                       bsize=4096   blocks=2096640, imaxpct=25
         =                       sunit=0      swidth=0 blks
naming   =version 2              bsize=4096   ascii-ci=0 ftype=1
log      =internal log           bsize=4096   blocks=2560, version=2
         =                       sectsz=512   sunit=0 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0

root@server:~# mkdir /mnt/virtualfs
root@server:~# mount -t xfs -o rw,noatime /dev/mapper/virtualfs /mnt/virtualfs
root@server:~# cat /proc/mounts | grep virtualfs
/dev/mapper/virtualfs /mnt/virtualfs xfs rw,noatime,attr2,inode64,noquota 0 0
``` 

So we LUKS encrypted the `/dev/nvme1n1` device using the password from the SSM store, we unlocked the device, formated the mapped device with XFS and mounted it under `/mnt/virtualfs`. What's left now is automate part of this work to happen on every server restart.

The main work will be done via simple shell script `/sbin/luks-mount`:

```shell
#!/bin/sh

usage() {  
    echo "Usage: $0 [start|stop]" >&2
    exit 1  
}

if [ $# -ne 1 ]; then 
    usage; exit 1
fi

ACTION="$1"
PASSWD=$(aws ssm get-parameters-by-path --path="${SSM_PATH}" --with-decryption --region=${SSM_REGION})
UUID=$(cryptsetup luksUUID ${LUKS_DEVICE})

case "$ACTION" in
start)  echo -n "$PASSWD" | cryptsetup luksOpen UUID=${UUID} ${LUKS_DEVICE_MAP}
        cryptsetup status ${LUKS_DEVICE_MAP}
        mount -t ${LUKS_DEVICE_FS} -o ${LUKS_DEVICE_MOUNT_OPT} \
        /dev/mapper/${LUKS_DEVICE_MAP} ${LUKS_DEVICE_MOUNT_POINT}
        ;;
stop)   umount -f ${LUKS_DEVICE_MOUNT_POINT}
        echo -n "$PASSWD" | cryptsetup luksClose /dev/mapper/${LUKS_DEVICE_MAP}
        ;;
*)      exit 0
        ;;
esac

unset PASSWD
exit 0
```

The script will run on startup via Systemd service:

```
[Unit]
Description=Activate LUKS device

[Service]
Type=oneshot
TimeoutSec=30
RemainAfterExit=yes
EnvironmentFile=/etc/default/luks-mount
ExecStartPre=/bin/mkdir -p ${LUKS_DEVICE_MOUNT_POINT}
ExecStart=/sbin/luks-mount start
ExecStop=/sbin/luks-mount stop

[Install]
WantedBy=multi-user.target
```

And all needed variables will be supplied via the following file `/etc/default/luks-mount`:

```
# The LUKS device
LUKS_DEVICE="/dev/nvme1n1"

# The LUKS mapper device
LUKS_DEVICE_MAP="virtualfs"

# The LUKS device file system
LUKS_DEVICE_FS="xfs"

# The LUKS device file system mount options
LUKS_DEVICE_MOUNT_OPT="rw,noatime,attr2,inode64,noquota,nofail,x-systemd.device-timeout=5"

# Mount point for the LUKS device
LUKS_DEVICE_MOUNT_POINT="/mnt/virtualfs"

# SSM Parameter Store - Password parameter
SSM_PATH="/luks/test/key"

# SSM Parameter Store AWS Region
SSM_REGION="us-east-1"
```

The service start up:

```
root@server:~# systemctl status -l luks-mount.service 
 luks-mount.service - Activate LUKS device
   Loaded: loaded (/etc/systemd/system/luks-mount.service; enabled; vendor preset: enabled)
   Active: active (exited) since Sat 2018-08-24 05:25:40 UTC; 7s ago
  Process: 2574 ExecStart=/sbin/luks-mount start (code=exited, status=0/SUCCESS)
  Process: 2569 ExecStartPre=/bin/mkdir -p ${LUKS_DEVICE_MOUNT_POINT} (code=exited, status=0/SUCCESS)
 Main PID: 2574 (code=exited, status=0/SUCCESS)

Aug 24 05:25:37 server systemd[1]: Starting Activate LUKS device...
Aug 24 05:25:40 server luks-mount[2574]: /dev/mapper/virtualfs is active.
Aug 24 05:25:40 server luks-mount[2574]:   type:    LUKS1
Aug 24 05:25:40 server luks-mount[2574]:   cipher:  aes-cbc-essiv:sha256
Aug 24 05:25:40 server luks-mount[2574]:   keysize: 256 bits
Aug 24 05:25:40 server luks-mount[2574]:   device:  /dev/nvme1n1
Aug 24 05:25:40 server luks-mount[2574]:   offset:  4096 sectors
Aug 24 05:25:40 server luks-mount[2574]:   size:    16773120 sectors
Aug 24 05:25:40 server luks-mount[2574]:   mode:    read/write
Aug 24 05:25:40 server systemd[1]: Started Activate LUKS device.
```

Now the device will be auto unlocked and mounted on every server restart and we didn't even have to store any sensitive data like password or key file on the server it self. It was all downloaded via shell script and executed in memory so nothing ever reached the file system either. In case the disk security has been compromised all we need to do is revoke the IAM user's keys to prevent unauthorized access to the encrypted data. Furthermore we can limit our IAM policy to allow access to the encrypted password for the LUKS device only from specific IPs which adds additional security in case the disk gets stolen.

```
[...]
        {
            "Effect": "Allow",
            "Action": [
                "ssm:GetParametersByPath",
                "ssm:GetParameters",
                "ssm:GetParameter"
            ],
            "Resource": [
                "arn:aws:ssm:us-east-1:account-id:parameter/luks/test/*"
            ],
            "Condition": {
              "IpAddress": {
                "aws:SourceIp": [
                  "103.15.250.0/24",
                  "12.148.72.0/23"
                ]
              }
            }
        }
[...]
```

Obviously with this approach we need to make the services depending on the existence of the mount point depend on the `luks-mount` service too which is easily achieved in Systemd.