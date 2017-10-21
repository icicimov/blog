---
type: posts
header:
  teaser: '42613560.jpeg'
title: 'S3 buckets as file system storage'
category: DevOps
tags: [aws, s3, s3fs, bamboo]
date: 2016-1-25
---

`s3fs` is a direct mapping of S3 to a file system paradigm. Files are mapped to objects. File system meta-data (e.g. ownership and file modes) are stored inside the object's meta data. File names are keys, with `/` as the delimiter to make listing more efficient. That's significant because it means we can mount any bucket with s3fs to explore it as a file system.

More details can be found at the [Project site](https://code.google.com/p/s3fs/wiki/FuseOverAmazon) and the [Github repository](https://github.com/s3fs-fuse/s3fs-fuse)

## Create the bucket in the S3 console

We create bucket with name `my-s3-bucket`. This name has to be unique across whole S3 since it is a shared storage for all S3 users and its access point is going to be `s3://my-s3-bucket`.

```
$ aws s3api create-bucket --bucket my-s3-bucket --region ap-southeast-2 --create-bucket-configuration LocationConstraint=ap-southeast-2
$ aws s3api put-bucket-versioning --region ap-southeast-2 --bucket my-s3-bucket --versioning-configuration Status=Enabled
```

Then we copy some data to the S3 bucket using the AWS CLI:

```
ubuntu@server:~$ aws s3 cp /data/documents/ s3://my-s3-bucket/documents/ --recursive
ubuntu@server:~$ aws s3 cp /data/pdf/ s3://my-s3-bucket/pdf/ --recursive
```

This will create 2 folders `documents` and `pdf` inside the bucket.

## Mount the S3 bucket in user space as file system

Install some prerequisites first:

```
ubuntu@server:~$ sudo aptitude install build-essential libfuse-dev fuse-utils libcurl4-openssl-dev libxml2-dev mime-support
```

And then setup the s3fs fuse file system:

```
ubuntu@server:~$ wget http://s3fs.googlecode.com/files/s3fs-1.74.tar.gz
ubuntu@server:~$ tar -xzvf s3fs-1.74.tar.gz
ubuntu@server:~/s3fs-1.74$ cd s3fs-1.74/
ubuntu@server:~/s3fs-1.74$ ./configure
ubuntu@server:~/s3fs-1.74$ make
ubuntu@server:~/s3fs-1.74$ sudo make install
```

Create a new user `my-s3-user` in the IAM console and download its credentials. Set the user policy to full S3 access only. We will use my-s3-user for access to our S3 buckets so we don't expose our admin user credentials unnecessary.

```
ubuntu@server:~/s3fs-1.74$ echo "API_KEY:SECRET_API_KEY" | sudo tee /etc/passwd-s3fs
ubuntu@server:~/s3fs-1.74$ sudo chmod 0600 /etc/passwd-s3fs
```

We set auto mount too configuring usage of SSL and caching in `/etc/fstab`:

```
...
# S3 /data bucket
/usr/local/bin/s3fs#my-s3-bucket /data fuse _netdev,rw,nosuid,nodev,allow_other,uid=tomcat7,gid=tomcat7,use_rrs,use_cache=/tmp,url=https://s3.amazonaws.com 0 0
```

Final step is setting the appropriate permissions on the existing files and directories in the S3 bucket:

```
ubuntu@server:~$ sudo find /data/documents/ /data/pdf/ -name \* -type d -exec sudo chmod 700 {} \;
ubuntu@server:~$ for m in `seq -f %02g 1 12`; do for i in `seq -f %02g 1 31`; do sudo find /data/documents/2014-$m-$i -name \* -type f ! -perm -644 -exec sudo chmod 644 {} \;; done; done
```

Any new files will be created with appropriate permissions.

## Alternative s3fs mounting via Upstart and Systemd

Another option is creating an upstart service `/etc/init/s3-bamboo-share.conf` out of our mounting command.

```
description "AmazonS3 bucket mount"
 
start on (filesystem and net-device-up IFACE=eth0)
stop on runlevel [!2345]
 
MOUNTPOINT="/mnt/bamboo-share"
 
respawn
respawn limit 10 10
kill timeout 10
 
pre-start script
    test -d $MOUNTPOINT || mkdir -p $MOUNTPOINT
    chown bamboo:bamboo $MOUNTPOINT
end script
 
script
    if [ ! $(grep -c $MOUNTPOINT /proc/mounts) ]
    then
        exec su - bamboo -c "/usr/bin/s3fs elasticbamboo-agent-share /home/bamboo/.m2 -o rw,uid=500,gid=501,iam_role=RoleELasticBambooS3,use_cache=/tmp,endpoint=ap-southeast-2,url=https://s3.amazonaws.com"
    fi
end script
 
pre-stop exec umount $MOUNTPOINT
```

And uncomment:

#user_allow_other

in `/etc/fuse.conf` file. Then we can simply run:

```
$ sudo [start|stop] s3-bamboo-share
```

to manage the share.

For systemd, official init daemon starting from Ubuntu-15.04, we need to create following `/etc/systemd/system/s3-bamboo-share.service` service file:

```
[Unit]
Description=Mount Maven S3 share
After=network.target
 
[Service]
User=bamboo
Group=bamboo
Type=oneshot
RemainAfterExit=yes
Environment=m2dir=/home/bamboo/.m2
ExecStartPre=/usr/bin/test -d ${m2dir} || /bin/mkdir -p ${m2dir} && /bin/chown bamboo:bamboo ${m2dir}
ExecStart=/usr/bin/s3fs elasticbamboo-agent-share ${m2dir} -o uid=500,gid=501,iam_role=RoleELasticBambooS3,use_cache=/tmp,endpoint=ap-southeast-2,url=https://s3.amazonaws.com
ExecStop=/bin/umount /home/bamboo/.m2
 
[Install]
WantedBy=multi-user.target
```

Then we start and enable the service:

```
$ sudo systemctl daemon-reload
$ sudo systemctl start s3-bamboo-share.service
$ sudo systemctl enable s3-bamboo-share.service
```

Created symlink from `/etc/systemd/system/multi-user.target.wants/s3-bamboo-share.service` to `/etc/systemd/system/s3-bamboo-share.service`. The `RoleELasticBambooS3` is an IAM Role with full access to the S3 bucket which is also assigned to the Elastic Bamboo EC2 instances.

To remove the mount point we simply run:

```
sudo systemctl stop s3-bamboo-share.service
```

## Updating s3fs

The latest version as of this writing with all bug fixes is `1.77` and has to be downloaded from GitHub where the project has moved recently:

```
ubuntu@server:~$ sudo aptitude install automake git
ubuntu@server:~$ git clone git://github.com/s3fs-fuse/s3fs-fuse.git
ubuntu@server:~$ cd s3fs-fuse/
ubuntu@server:~/s3fs-fuse$ ./autogen.sh
ubuntu@server:~/s3fs-fuse$ ./configure
ubuntu@server:~/s3fs-fuse$ make
ubuntu@server:~/s3fs-fuse$ sudo make install

ubuntu@server:~/s3fs-fuse$ s3fs --version
Amazon Simple Storage Service File System V1.77 with OpenSSL
Copyright (C) 2010 Randy Rizun <rrizun@gmail.com>
License GPL2: GNU GPL version 2 <http://gnu.org/licenses/gpl.html>
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.
```

I use this approach to mount our Maven share for use in our Elastic Bamboo CI instances. 

## Backing up the bucket data

Simplest is to sync our data bucket with secondary one. Create the new backup bucket:

```
ubuntu@manager:~$ aws s3 mb s3://my-s3-bucket-bkp
make_bucket: s3://my-s3-bucket-bkp/
```

and then sync the buckets:

```
ubuntu@manager:~$ aws s3 sync s3://my-s3-bucket/ s3://my-s3-bucket-bkp/
```

To remove the bucket if don't need it any more:

```
ubuntu@manager:~$ aws s3 rb s3://my-s3-bucket-bkp --force
```