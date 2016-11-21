---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Duplicity encrypted backups to Amazon S3'
categories: 
  - DevOps
tags: [aws, s3, gpg]
date: 2016-9-16
---

[Duplicity](http://duplicity.nongnu.org/) is a tool for creating bandwidth-efficient, incremental, encrypted backups. It backs directories by producing encrypted tar-format volumes and uploading them to a remote or local file server. And because duplicity uses [librsync](http://sourceforge.net/projects/librsync), the incremental archives are space efficient and only record the parts of files that have changed since the last backup. It uses [GnuPG](http://www.gnupg.org/) to encrypt and/or sign these archives to provide privacy. Different backends like ftp, sftp, imap, s3 and others are supported.

## Prepare S3 bucket and IAM user and policy in Amazon

First we login in our Amazon S3 console and create a bucket named <my-s3-bucket>. Then we create IAM user and attach the following policy to it:

```
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "s3:*",
            "Resource": [
                "arn:aws:s3:::<my-s3-bucket>",
                "arn:aws:s3:::<my-s3-bucket>/*"
            ]
        }
    ]
}
```

This will limit this user's access to the created S3 bucket only and nothing else. Then we download the user's AWS access key and secret access key that we are going to use in our duplicity setup. This can be done only once at the time of user creation.

## Installation

Install from PPA maintained by Duplicity team:

```
root@server01:~# add-apt-repository ppa:duplicity-team/ppa
root@server01:~# aptitude update && aptitude install -y duplicity python-boto
```

Prepare GPG key password to use it with the gpg key later (the one given below is not the one I used for the server of course):

```
igorc@igor-laptop:~/Downloads$ openssl rand -base64 20
rwPo1U7+8xMrq6vvuTX9Rj7ILck=
```

Create GPG key:

```
root@server01:~# gpg --gen-key
gpg (GnuPG) 1.4.16; Copyright (C) 2013 Free Software Foundation, Inc.
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.
 
gpg: keyring `/root/.gnupg/secring.gpg' created
Please select what kind of key you want:
   (1) RSA and RSA (default)
   (2) DSA and Elgamal
   (3) DSA (sign only)
   (4) RSA (sign only)
Your selection?
RSA keys may be between 1024 and 4096 bits long.
What keysize do you want? (2048)
Requested keysize is 2048 bits
Please specify how long the key should be valid.
         0 = key does not expire
      <n>  = key expires in n days
      <n>w = key expires in n weeks
      <n>m = key expires in n months
      <n>y = key expires in n years
Key is valid for? (0)
Key does not expire at all
Is this correct? (y/N) y
 
You need a user ID to identify your key; the software constructs the user ID
from the Real Name, Comment and Email Address in this form:
    "Heinrich Heine (Der Dichter) <heinrichh@duesseldorf.de>"
 
Real name: duplicity
Email address:
Comment: Duplicity S3 backup encryption key
You selected this USER-ID:
    "duplicity (Duplicity S3 backup encryption key)"
 
Change (N)ame, (C)omment, (E)mail or (O)kay/(Q)uit? O
You need a Passphrase to protect your secret key.
 
gpg: gpg-agent is not available in this session
We need to generate a lot of random bytes. It is a good idea to perform
some other action (type on the keyboard, move the mouse, utilize the
disks) during the prime generation; this gives the random number
generator a better chance to gain enough entropy.
 
Not enough random bytes available.  Please do some other work to give
the OS a chance to collect more entropy! (Need 128 more bytes)
................+++++
gpg: key 1XXXXXXB marked as ultimately trusted
public and secret key created and signed.
 
gpg: checking the trustdb
gpg: 3 marginal(s) needed, 1 complete(s) needed, PGP trust model
gpg: depth: 0  valid:   1  signed:   0  trust: 0-, 0q, 0n, 0m, 0f, 1u
pub   2048R/1XXXXXXB 2016-09-15
      Key fingerprint = 5669 C5C7 FFCC 4698 0E00  BDA2 0CAE 27AC 171E 6C5B
uid                  duplicity (Duplicity S3 backup encryption key)
sub   2048R/5XXXXXX8 2016-09-15
```

The GnuPGP documentation [Unattended GPG key generation](https://www.gnupg.org/documentation/manuals/gnupg/Unattended-GPG-key-generation.html) explains how to automate the key generation by feeding an answer file via `--batch` option. It is also a good idea to install `rng-tools` that supply the `rngd` daemon we can use to provide enough entropy on the server in case of low activity.

List the keys:

```
root@server01:~# gpg --list-keys
/root/.gnupg/pubring.gpg
------------------------
pub   2048R/1XXXXXXB 2016-09-15
uid                  duplicity (Duplicity S3 backup encryption key)
sub   2048R/5XXXXXX8 2016-09-15
```

Export and email the key for safe storage:

```
root@server01:~# gpg --armor --export duplicity | mail -s "server01 duplicity GPG key" igorc@encompasscorporation.com
root@server01:~# gpg --armor --export-private-key duplicity | mail -s "server01 duplicity private GPG key" igorc@encompasscorporation.com
```

Create backup dir structure:

```
root@server01:~# mkdir -p /bkp/{backups,duplicity_archives,restore}
root@server01:~# mkdir -p /bkp/backups/mongo
```

## Backups

First run for the documents `/data` files. Duplicity is very flexible and feature reach so we can even specify a backup strategy upon first run telling it when to take full or incremental backup and for how long to retain them:

```
root@server01:~# export PASSPHRASE="rwPo1U7+8xMrq6vvuTX9Rj7ILck="
root@server01:~# export AWS_ACCESS_KEY_ID="<my-aws-access-key>"
root@server01:~# export AWS_SECRET_ACCESS_KEY="<my-aws-secret-key>"
root@server01:~# cd /bkp/backups
root@server01:/bkp/backups# /usr/bin/duplicity --s3-european-buckets \
  --s3-use-new-style --encrypt-key 1XXXXXXB --asynchronous-upload -v 4 \
  --archive-dir=/bkp/duplicity_archives/data incr --full-if-older-than 14D \
  /data "s3+http://<my-s3-bucket>/trtest/${HOSTNAME}/data"

Local and Remote metadata are synchronized, no sync needed.
Last full backup date: none
Last full backup is too old, forcing full backup
--------------[ Backup Statistics ]--------------
StartTime 1473912738.45 (Thu Sep 15 05:12:18 2016)
EndTime 1473912847.27 (Thu Sep 15 05:14:07 2016)
ElapsedTime 108.83 (1 minute 48.83 seconds)
SourceFiles 9622
SourceFileSize 1876302897 (1.75 GB)
NewFiles 9622
NewFileSize 1876302897 (1.75 GB)
DeletedFiles 0
ChangedFiles 0
ChangedFileSize 0 (0 bytes)
ChangedDeltaSize 0 (0 bytes)
DeltaEntries 9622
RawDeltaSize 1876110545 (1.75 GB)
TotalDestinationSizeChange 1288698999 (1.20 GB)
Errors 0
-------------------------------------------------
 
root@server01:/bkp/backups#
```

The backup is in a encrypted archive format in the target S3 bucket, see the attached screen shot below:

![Duplicity S3 bucket](/blog/images/duplicity_encrypted_backup_in_s3.png "Duplicity S3 bucket")
***Picture1:** Duplicity S3 bucket*

First run for Mongo backup, we want to execute only on a `SECONDARY` server so we include that check too:

```
root@server01:~# export PASSPHRASE="rwPo1U7+8xMrq6vvuTX9Rj7ILck="
root@server01:~# export AWS_ACCESS_KEY_ID="<my-aws-access-key>"
root@server01:~# export AWS_SECRET_ACCESS_KEY="<my-aws-secret-key>"

root@server01:~# [[ $(/usr/bin/mongo --quiet --host 127.0.0.1:27017 admin --eval \
  'db.isMaster().ismaster') == "false" ]] && /usr/bin/mongodump --host 127.0.0.1:27017 \
  --authenticationDatabase=encompass --username <my-user-name> --password <my-password> \
  --out /bkp/backups/mongo --oplog
 
root@server01:/bkp/restore# /usr/bin/duplicity --s3-european-buckets --s3-use-new-style \
  --encrypt-key 1XXXXXXB --asynchronous-upload -v 4 --archive-dir=/bkp/duplicity_archives/mongo incr \
  --full-if-older-than 14D /bkp/backups/mongo "s3+http://<my-s3-bucket>/trtest/${HOSTNAME}/mongo"

Local and Remote metadata are synchronized, no sync needed.
Last full backup date: none
Last full backup is too old, forcing full backup
--------------[ Backup Statistics ]--------------
StartTime 1473915709.33 (Thu Sep 15 06:01:49 2016)
EndTime 1473915720.69 (Thu Sep 15 06:02:00 2016)
ElapsedTime 11.36 (11.36 seconds)
SourceFiles 127
SourceFileSize 472458569 (451 MB)
NewFiles 127
NewFileSize 472458569 (451 MB)
DeletedFiles 0
ChangedFiles 0
ChangedFileSize 0 (0 bytes)
ChangedDeltaSize 0 (0 bytes)
DeltaEntries 127
RawDeltaSize 472442185 (451 MB)
TotalDestinationSizeChange 82399352 (78.6 MB)
Errors 0
-------------------------------------------------
 
root@server01:~#
```

We can confirm the backup like this:

```
root@server01:/bkp/restore# PASSPHRASE="rwPo1U7+8xMrq6vvuTX9Rj7ILck=" duplicity list-current-files \
  --s3-european-buckets --s3-use-new-style "s3+http://<my-s3-bucket>/trtest/${HOSTNAME}/mongo"

Synchronizing remote metadata to local cache...
Copying duplicity-full-signatures.20160915T050149Z.sigtar.gpg to local cache.
Copying duplicity-full.20160915T050149Z.manifest.gpg to local cache.
Last full backup date: Thu Sep 15 06:01:49 2016
Thu Sep 15 05:57:49 2016 .
Thu Sep 15 05:57:49 2016 encompass
[...]
Thu Sep 15 05:57:49 2016 oplog.bson
root@server01:/bkp/restore#
```

The next backups we run will be incremental for the next 14 days then duplicity will create a new full backup and maintain up to 4 full backups in the archive.

We can use duplicity to backup ElasticSearch as well:

```
root@sl02:/bkp# /usr/bin/duplicity --s3-european-buckets --s3-use-new-style --encrypt-key AXXXXXXB \
  --asynchronous-upload -v 4 --archive-dir=/bkp/duplicity_archives/elasticsearch incr \
  --full-if-older-than 14D /var/lib/elasticsearch "s3+http://<my-s3-bucket>/trtest/${HOSTNAME}/elasticsearch"

Local and Remote metadata are synchronized, no sync needed.
Last full backup date: none
Last full backup is too old, forcing full backup
--------------[ Backup Statistics ]--------------
StartTime 1473920881.54 (Thu Sep 15 07:28:01 2016)
EndTime 1473920881.85 (Thu Sep 15 07:28:01 2016)
ElapsedTime 0.31 (0.31 seconds)
SourceFiles 589
SourceFileSize 1132601 (1.08 MB)
NewFiles 589
NewFileSize 1132601 (1.08 MB)
DeletedFiles 0
ChangedFiles 0
ChangedFileSize 0 (0 bytes)
ChangedDeltaSize 0 (0 bytes)
DeltaEntries 589
RawDeltaSize 10297 (10.1 KB)
TotalDestinationSizeChange 11618 (11.3 KB)
Errors 0
-------------------------------------------------
 
root@sl02:/bkp#
```

## Restore a Backup

No point to backup if we can't restore it. To recover the backup we don't need to provide anything but the password phrase for the GPG encryption key. Duplicity knows via its meta data which key to use to decrypt the data.

### Full restore

Lets restore everything from the mongo backup we took previously:

```
root@server01:~# cd /bkp/restore
 
root@server01:/bkp/restore# mkdir mongo
 
root@server01:/bkp/restore# PASSPHRASE="rwPo1U7+8xMrq6vvuTX9Rj7ILck=" \
  duplicity restore --s3-european-buckets \
  --s3-use-new-style "s3+http://<my-s3-bucket>/trtest/${HOSTNAME}/mongo" mongo/

Local and Remote metadata are synchronized, no sync needed.
Last full backup date: Thu Sep 15 06:01:49 2016
 
root@server01:/bkp/restore# ls -l mongo/
total 12
drwxr-xr-x 2 root root 4096 Sep 15 05:57 admin
drwxr-xr-x 2 root root 4096 Sep 15 05:57 encompass
drwxr-xr-x 2 root root 4096 Sep 15 05:57 encompass_admin
-rw-r--r-- 1 root root    0 Sep 15 05:57 oplog.bson
```

Now we can use `mongorestore` to recover the db's as per usual using `--oplog` option for consistent recovery and `oplog` replay.

### Restore specific file(s)

Lets say we want to restore specific collection from the mongo backup:

```
root@server01:/bkp/restore# mkdir files
 
root@server01:/bkp/restore# PASSPHRASE="rwPo1U7+8xMrq6vvuTX9Rj7ILck=" duplicity restore -v 4 --s3-european-buckets --s3-use-new-style --file-to-restore encompass/<my-collection-name>.bson "s3+http://<my-s3-bucket>/trtest/${HOSTNAME}/mongo" files/<my-collection-name>.bson
Local and Remote metadata are synchronized, no sync needed.
Last full backup date: Thu Sep 15 06:01:49 2016
root@server01:/bkp/restore#
```

To make duplicity really verbose we can increase the level to 9 for the next file so we can see what is duplicity doing under the hood.

We can now see our two restored files:

```
root@server01:/bkp/restore# ls -l files
total 3564
-rw-r--r-- 1 root root 3644494 Sep 15 05:57 <my-collection-name>.bson
-rw-r--r-- 1 root root     259 Sep 15 05:57 <my-collection-name>.metadata.json
```

and use `mongorestore` to recover the `<my-collection-name>` collection in the encompass database.

## Automating the backups

The attached scripts can be used to backup the tomcat saved documents, mongo and elastic search using crontab. For example:

```bash
# Duplicity backups to Amazon S3
00 02 * * * /usr/local/bin/duplicity_es_backup.sh <my-s3-bucket> > /dev/null 2>&1
15 02 * * * /usr/local/bin/duplicity_data_backup.sh <my-s3-bucket> > /dev/null 2>&1
30 02 * * * /usr/local/bin/duplicity_mongodb_backup.sh <my-s3-bucket> > /dev/null 2>&1
```
We store the pass-phrase and other sensitive data in a `~/.duplicity` file that we source in runtime so we don't have to provide them in the scripts in clear text.

```
# GPG key passphrase
export PASSPHRASE="rwPo1U7+8xMrq6vvuTX9Rj7ILck="
# the IAM user credentials
export AWS_ACCESS_KEY_ID="<my-aws-access-key>"
export AWS_SECRET_ACCESS_KEY="<my-aws-secret-key>"
```

and set proper permissions:

```
root@server01:/bkp/restore# chmod 0600 ~/.duplicity
```

Example of cron run for mongo backup script:

```
Date: Fri, 16 Sep 2016 02:30:12 +0100 (BST)
From: Cron Daemon <root@server01.mydomain.com>
To: root@server01.mydomain.com
Subject: Cron <root@server01> /usr/local/bin/duplicity_mongodb_backup.sh
 
[...]
Local and Remote metadata are synchronized, no sync needed.
Last full backup date: Thu Sep 15 06:01:49 2016
--------------[ Backup Statistics ]--------------
StartTime 1473989408.98 (Fri Sep 16 02:30:08 2016)
EndTime 1473989411.27 (Fri Sep 16 02:30:11 2016)
ElapsedTime 2.28 (2.28 seconds)
SourceFiles 127
SourceFileSize 472458569 (451 MB)
NewFiles 4
NewFileSize 16384 (16.0 KB)
DeletedFiles 0
ChangedFiles 123
ChangedFileSize 472442185 (451 MB)
ChangedDeltaSize 0 (0 bytes)
DeltaEntries 127
RawDeltaSize 7486 (7.31 KB)
TotalDestinationSizeChange 6769 (6.61 KB)
Errors 0
-------------------------------------------------
[...]
```

The scripts are available for download: [duplicity_mongodb_backup.sh]({{ site.baseurl }}/download/duplicity_mongodb_backup.sh), [duplicity_es_backup.sh]({{ site.baseurl }}/download/duplicity_es_backup.sh), [duplicity_data_backup.sh]({{ site.baseurl }}/download/duplicity_data_backup.sh).

## Duply (simple duplicity)

[Duply](http://duply.net/) is kind of front-end for duplicity. According to its documentation, duply simplifies running duplicity with cron or on command line by:

* keeping recurring settings in profiles per backup job
* automated import/export of keys between profile and keyring
* enabling batch operations eg. backup_verify_purge
* executing pre/post scripts
* precondition checking for flawless duplicity operation

Worth looking into in case we need it.