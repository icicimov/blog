---
type: posts
header:
  teaser: '42613560.jpeg'
title: 'MySQL SSL and client certificates authentication'
categories: 
  - Database
tags: [mysql, database, infrastructure, ssl, aws]
---

First lets create a small Camel database with couple of tables on our server.mydomain.com host using the following script:

```
create database camel;
grant usage on camel.* to 'camel'@'%' identified by '<camel-password>';
grant all privileges on camel.* to 'camel'@'%' identified by '<camel-password>';
CREATE TABLE camel.aggregation (
    id varchar(255) NOT NULL,
    exchange longblob NOT NULL,
    constraint aggregation_pk PRIMARY KEY (id)
);
CREATE TABLE camel.aggregation_completed (
    id varchar(255) NOT NULL,
    exchange longblob NOT NULL,
    constraint aggregation_completed_pk PRIMARY KEY (id)
);
flush privileges;
```

Now we need to enable SSL in our MySQL server so we can have encrypted communication with the clients, which for example are not in the same VPC as the server. At the moment we have:

```
mysql> show variables like '%ssl%';
+---------------+------------------------------------------------+
| Variable_name | Value                                          |
+---------------+------------------------------------------------+
| have_openssl  | DISABLED                                       |
| have_ssl      | DISABLED                                       |
+---------------+------------------------------------------------+
2 rows in set (0.00 sec)
```

We setup our SSL certificates under `/etc/mysql/ssl/` directory and we set in the config file `/etc/mysql/conf.d/encompass.cnf`:

```
[mysqld]
#
# SSL
#
ssl=1
ssl-ca=/etc/mysql/ssl/Encompass_CA.pem
ssl-cert=/etc/mysql/ssl/camel.pem
ssl-key=/etc/mysql/ssl/camel.key
ssl-cipher=ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-SHA
...
```

and after we restart the server we can see:

```
mysql> show variables like '%ssl%';
+---------------+------------------------------------------------+
| Variable_name | Value                                          |
+---------------+------------------------------------------------+
| have_openssl  | YES                                            |
| have_ssl      | YES                                            |
| ssl_ca        | /etc/mysql/ssl/Encompass_CA.pem                |
| ssl_capath    |                                                |
| ssl_cert      | /etc/mysql/ssl/camel.pem                       |
| ssl_cipher    | ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-SHA |
| ssl_crl       |                                                |
| ssl_crlpath   |                                                |
| ssl_key       | /etc/mysql/ssl/camel.key                       |
+---------------+------------------------------------------------+
9 rows in set (0.02 sec)
```

which means we can start using SSL in our client connections.

On the client side we first need to set the CA certificate, here I have copied over the same CA:

```
igorc@client:~$ sudo mkdir -p /etc/mysql/ssl
igorc@client:~$ sudo vi /etc/mysql/ssl/Encompass_CA.pem
```

and to connect via ssl we need to use `--ssl-ca` option pointing to the CA cert:

```
igorc@client:~$ mysql --silent --ssl-ca=/etc/mysql/ssl/Encompass_CA.pem -h server.encompasshost.com -P 3306 -u camel -p<camel-password> camel
mysql> status;
--------------
mysql  Ver 14.14 Distrib 5.5.40, for debian-linux-gnu (x86_64) using readline 6.3

Connection id:		14058
Current database:	camel
Current user:		camel@ip-10.18.239.45.ap-southeast-2.compute.internal
SSL:			Cipher in use is DHE-RSA-AES256-SHA
Current pager:		stdout
Using outfile:		''
Using delimiter:	;
Server version:		5.6.21-log MySQL Community Server (GPL)
Protocol version:	10
Connection:		server.encompasshost.com via TCP/IP
Server characterset:	latin1
Db     characterset:	latin1
Client characterset:	utf8
Conn.  characterset:	utf8
TCP port:		33306
Uptime:			4 hours 10 min 19 sec

Threads: 4  Questions: 41640  Slow queries: 0  Opens: 74  Flush tables: 1  Open tables: 65  Queries per second avg: 2.772
--------------

mysql> show tables;
Tables_in_camel
aggregation
aggregation_completed
mysql> exit
```

The status line `SSL: Cipher in use is DHE-RSA-AES256-SHA` confirms that our connection is via SSL.

Further more, if we wish to restrict access only from some hosts we can do that using client side SSL certificates. In that
case on the client we setup the client cert and key under `/etc/mysql/ssl/` and change the config accordingly in `/etc/mysql/my.cnf` file:

```
[mysql]
ssl=1
ssl-ca=/etc/mysql/ssl/Encompass_CA.pem
ssl-cert=/etc/mysql/ssl/mysql-client.pem
ssl-key=/etc/mysql/ssl/mysql-client.key
```

then on the server side we set the certificate parameters we want to check for the particular client and user by modifying the 
user's GRANT:

```
mysql> GRANT ALL PRIVILEGES ON camel.* to 'camel'@'%' IDENTIFIED BY '<camel-password>' REQUIRE X509;
```

which means that the client must have a valid certificate but that the exact certificate, issuer, and subject do not matter. The only 
requirement is that it should be possible to verify its signature with one of the CA certificates. Further limitations might be applied
via one of the following:

```
REQUIRE ISSUER 'issuer'
REQUIRE SUBJECT 'subject'
REQUIRE CIPHER 'cipher'
```

Example:

```
mysql> GRANT ALL PRIVILEGES ON camel.* to 'camel'@'%' IDENTIFIED BY '<camel-password>'
  REQUIRE SUBJECT '/C=AU/ST=New South Wales/L=Sydney/O=Encompass Corporation Ltd./OU=DevOps/CN=mysql-client';
```

If `REQUIRE SSL` is used, all connections from that particular user must come via SSL only.

To manually test the connection before we put all this in the config file we run:

```
igorc@client:~$ mysql --silent --ssl-ca=/etc/mysql/ssl/Encompass_CA.pem --ssl-cert=/etc/mysql/ssl/mysql-client.pem --ssl-key=/etc/mysql/ssl/mysql-client.key -h server.encompasshost.com -P 3306 -u camel -p<camel-password> camel
mysql> \s;
--------------
mysql  Ver 14.14 Distrib 5.5.40, for debian-linux-gnu (x86_64) using readline 6.2

Connection id:		75548
Current database:	camel
Current user:		camel@ip-10.18.239.45.ap-southeast-2.compute.internal
SSL:			Cipher in use is DHE-RSA-AES256-SHA
Current pager:		stdout
Using outfile:		''
Using delimiter:	;
Server version:		5.6.21-log MySQL Community Server (GPL)
Protocol version:	10
Connection:		server.encompasshost.com via TCP/IP
Server characterset:	latin1
Db     characterset:	latin1
Client characterset:	utf8
Conn.  characterset:	utf8
TCP port:		33306
Uptime:			21 hours 28 min 14 sec

Threads: 5  Questions: 226218  Slow queries: 0  Opens: 74  Flush tables: 1  Open tables: 65  Queries per second avg: 2.926
--------------

mysql> show tables;
Tables_in_camel
aggregation
aggregation_completed
mysql> exit
```

This means client certificate authentication is working so we go and make the above changes in the client config file. The client certs used have been of course issued and signed by the same CA as are the ones on the server side.