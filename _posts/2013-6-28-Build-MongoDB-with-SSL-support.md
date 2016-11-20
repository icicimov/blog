---
type: posts
header:
  teaser: 'mongodb.png'
title: 'Build MongoDB with SSL support'
categories: 
  - Database
tags: [database, mongodb, ssl]
date: 2013-6-28
---

The free source version of MongoDB 2.x does not come with SSL support. To enable it we need to build it from source with `--ssl` option at compile time or use the enterprise version which is very expensive.

## Building and installation

### Clone and build MongoDB with SSL support

```
ubuntu@ip-172-31-10-62:/mnt/mongo$ git clone git://github.com/mongodb/mongo.git
ubuntu@ip-172-31-10-62:/mnt/mongo$ cd mongo
ubuntu@ip-172-31-10-62:/mnt/mongo$ git tag -l
ubuntu@ip-172-31-10-62:/mnt/mongo$ git checkout r2.2.2
ubuntu@ip-172-31-10-62:/mnt/mongo$ scons --64=FORCE64 --ssl=openssl all
ubuntu@ip-172-31-10-62:/mnt/mongo$ sudo scons --prefix=/opt/mongo install
```

### Configure new MongoDB

The installed binaries are not supporting SSL, but in the current build directory mongodb has been compiled with full SSL support. To use it we do the following:

```
ubuntu@ip-172-31-10-62:/mnt/mongo$ sudo ln -s /mnt/mongo/build/linux2/64/ssl/mongo /opt/mongodb
```

I'll use already existing certificate I've created for the domain by concatenating the PEM public and private key into `/opt/mongodb/ssl.crt` file:

```
-----BEGIN CERTIFICATE-----
MIIFSDCCBDCgAwIBAgIDDCAHMA0GCSqGSIb3DQEBBQUAMDwxCzAJBgNVBAYTAlVTMRcwFQYDVQQK
...
1r3hajKTe7vfUfA9esMVjQgU14c87ccn3MBQASq6RP7NUnOWf3hjtbiDBpPi
-----END CERTIFICATE-----
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEAi4kEoWzS8sKxETEmcWKXDlEU0ia2AucMiPTYKGageMmIrA/w
Am2+tHvxamH1Sm/C6U3RhgajfOHMm8p9tBm+IViuaS6O0J1KHrXIO2FJ1sIBwm1w
...
S+PTrsHOKocvqKW3I8F9COXWbGiem2VQl754SoiQKotKs7cqi40+WQ==
-----END RSA PRIVATE KEY-----
```

### SSL connection

Start the database:

```
ubuntu@ip-172-31-10-62:/mnt/mongo$ sudo -u mongodb /opt/mongodb/mongod --config /etc/mongodb.conf --sslPEMKeyFile /opt/mongodb/ssl.crt --sslOnNormalPorts --sslPEMKeyPassword password &
```

Connect with client via SSL:

```
ubuntu@ip-172-31-10-62:/mnt/mongo$ /opt/mongodb/mongo --ssl
MongoDB shell version: 2.2.2
connecting to: test
> exit
bye
ubuntu@ip-172-31-10-62:/mnt/mongo$
```