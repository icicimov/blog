---
type: posts
header:
  teaser: '488564370.jpg'
title: 'Host-based IDS with Snort, Barnyard2 and Snorby in AWS'
category: Security
tags: [snort, barnyard, snorby, ids]
related: true
---
{% include toc %}
[Snort](https://www.snort.org) is open source network-based intrusion detection system (NIDS) that has the ability to perform real-time traffic analysis and packet logging on Internet Protocol (IP) networks. Snort performs protocol analysis, content searching, and content matching.

`Snort` can be configured in three main modes: sniffer, packet logger, and network intrusion detection. In sniffer mode, the program will read network packets and display them on the console. In packet logger mode, the program will log packets to the disk. In intrusion detection mode, the program will monitor network traffic and analyze it against a rule set defined by the user. The program will then perform a specific action based on what has been identified.

On each host we are going to use Snort in network intrusion detection mode. To speed up its traffic processing it will log in binary mode. That's where `Barnyard2` comes into play.

[Barnyard2](git://github.com/firnsy/barnyard2.git) is an open source interpreter for Snort `unified2` binary output files. Its primary use is allowing Snort to write to disk in an efficient manner and leaving the task of parsing binary data into various formats to a separate process that will not cause Snort to miss network traffic. It can also operate in three modes: Batch, Continual and Continual with bookmarking.

In batch (or one-shot) mode, barnyard2 will process the explicitly specified file(s) and exit. In continual mode, barnyard2 will start with a location to look and a specified file pattern and continue to process new data (and new spool files) as they appear. Continual mode with bookmarking will also use a checkpoint file (or waldo file in the snort world) to track where it is. In the event the barnyard2 process ends while a waldo file is in use, barnyard2 will resume processing at the last entry as listed in the waldo file.

Barnyard2 processing is controlled by two main types of directives: input processors and output plugins. The input processors read information in from a specific format (currently the `spo_unified2` output module of Snort) and output them in one of several ways.

[Snorby](https://github.com/Security-Onion-Solutions/security-onion/wiki/Snorby) is an open source Ruby on Rails web application that interacts with the data populated by Snort and Barnyard in a database and presents them in a really beautiful and easy to manage user interface.

# Installation and Setup

## Server side

This is going to be the host where the central snort database will reside. It will be a Ubuntu host launched from AWS Ubuntu-14.04 LTS x86-64 AMI. Being the latest stable Ubuntu LTS release it should have most recent packages so we can try to reduce compiling from sources to minimum.

### Snort

We start with installing some dependencies:

```
root@server:~$ tasksel install lamp-server
root@server:~$ aptitude install libwww-perl libnet1 libnet1-dev libpcre3 libpcre3-dev autoconf libcrypt-ssleay-perl libtool libssl-dev build-essential automake gcc make flex bison
root@server:~$ aptitude install libdnet libdaq-dev libpcap-dev
```

After that we can install snort which is on version 2.9.6.0 in the 14.04 repositories and not much behind Snort's master which is on 2.9.6.2 atm:

```
root@server:~# aptitude install snort
```

Then we can easily configure the package Debian way `/etc/snort/snort.debian.conf`:

```
DEBIAN_SNORT_STARTUP="boot"
DEBIAN_SNORT_HOME_NET="<my-vpc-cidr>"
DEBIAN_SNORT_OPTIONS=""
DEBIAN_SNORT_INTERFACE="eth0"
DEBIAN_SNORT_SEND_STATS="true"
DEBIAN_SNORT_STATS_RCPT="root"
DEBIAN_SNORT_STATS_THRESHOLD="1"
```

To install the Snort Rules I used the OinkMaster script. But first we need to register on the Snort site and get so called oink code which I can use to download the latest rules for my snort major version (mine is 2.9.6.0, the source is at 2.9.6.2):

```
root@server:/tmp# wget -O snortrules-snapshot-2962.tar.gz https://www.snort.org/rules/snortrules-snapshot-2962.tar.gz/<MY-OINK-CODE>
root@server:/tmp# cd oinkmaster-2.0/
root@server:/tmp/oinkmaster-2.0# cp oinkmaster.pl /usr/local/bin/
root@server:/tmp/oinkmaster-2.0# cp oinkmaster.conf /usr/local/etc/
root@server:/tmp/oinkmaster-2.0# oinkmaster.pl -b /var/tmp -o /etc/snort/rules -C /usr/local/etc/oinkmaster.conf -u file:///tmp/snortrules-snapshot-2962.tar.gz
```

We will also use the OinkMaster source scripts to create the sid-msg.map file for Snort:

```
root@server:/tmp/oinkmaster-2.0# ./contrib/create-sidmap.pl /etc/snort/rules > /etc/snort/sid-msg.map
```

### Barnyard2

First we need to create a MySQL database we gonna use for Barnyard:

```
root@server:~# mysql -u root -p -e 'create database snorby'
```

Next we move to installing and configuring Barnyard from source:

```
root@server:~# aptitude install libmysqld-dev libpcap-dev libprelude-dev git
root@server:~# git clone  http://github.com/firnsy/barnyard2.git barnyard
root@server:~/barnyard# cd barnyard/
root@server:~/barnyard# autoreconf -fvi -I ./m4
root@server:~/barnyard# ./configure --with-mysql --with-mysql-libraries=/usr/lib/x86_64-linux-gnu
root@server:~/barnyard# make
root@server:~/barnyard# make install
root@server:~/barnyard# cp etc/barnyard2.conf /etc/snort/
root@server:~/barnyard# mkdir /var/log/barnyard2
root@server:~/barnyard# chmod 666 /var/log/barnyard2
root@server:~/barnyard# touch /var/log/snort/barnyard2.waldo
root@server:~/barnyard# chown snort:snort /var/log/snort/barnyard2.waldo
root@server:~/barnyard# mysql -u root -p -D snorby < ./schemas/create_mysql
```

Now Barnyard2 should be installed and configured and the database tables populated. We can now create a user we gonna use to access and write the snort records in the database:

```
root@server:~# mysql -u root -p
mysql> GRANT ALL ON snorby.* TO 'snorby'@'localhost' IDENTIFIED BY '<snort-password>';
Query OK, 0 rows affected (0.00 sec)
mysql> FLUSH PRIVILEGES;
mysq> quit
```

Next we will update the Barnyard config file as follows `/etc/snort/barnyard2.conf`:

```
config reference_file:      /etc/snort/reference.config
config classification_file: /etc/snort/classification.config
config gen_file:            /etc/snort/gen-msg.map
config sid_file:            /etc/snort/sid-msg.map
config logdir: /var/log/snort
config archivedir: /var/log/snort/archive
config hostname:   localhost
config interface:  eth0
config daemon
config waldo_file: /var/log/snort/barnyard2.waldo
input unified2
output alert_fast: stdout
output database: log, mysql, user=snorby password=<snort-password> dbname=snorby host=localhost
```

This tells Barnyard how to connect to the database and were to find the needed files. At the end we create the archive directory where Barnyard will store the processed files:

```
root@server:~/barnyard# mkdir /var/log/snort/archive
root@server:~/barnyard# chown snort /var/log/snort/archive/
```

### Snorby

We install some dependencies and build the package from source:

```
root@server:~# aptitude install imagemagick wkhtmltopdf ruby1.9.3 libyaml-dev libxml2-dev libxslt1-dev zlib1g-dev build-essential openssl libssl-dev libmysqlclient-dev libreadline6-dev
root@server:~# cd /usr/local/src/
root@server:~/usr/local/src# git clone http://github.com/Snorby/snorby.git
root@server:~/usr/local/src# cd snorby
root@server:~/usr/local/src/snorby# aptitude install bundler
root@server:~/usr/local/src/snorby# bundle install
```

We have already setup the database in the previous steps so we can move to setting up the configuration files:

```
root@server:~/usr/local/src/snorby# cp config/database.yml.example config/database.yml
root@server:~/usr/local/src/snorby# vi config/database.yml
# Snorby Database Configuration
#
# Please set your database password/user below
# NOTE: Indentation is important.
#
snorby: &snorby
  adapter: mysql
  username: snorby
  password: "<snort-password>"
  host: localhost
development:
  database: snorby
  <<: *snorby
test:
  database: snorby
  <<: *snorby
production:
  database: snorby
  <<: *snorby
 
root@server:~/usr/local/src/snorby# cp config/snorby_config.yml.example config/snorby_config.yml
root@server:~/usr/local/src/snorby# vi config/snorby_config.yml
...
production:
  # in case you want to run snorby under a suburi/suburl under eg. passenger:
  baseuri: ''
  # baseuri: '/snorby'
  domain: 'server.mydomain.com'
  wkhtmltopdf: /usr/bin/wkhtmltopdf
  ssl: false
  mailer_sender: 'snorby@server.mydomain.com'
  geoip_uri: "http://geolite.maxmind.com/download/geoip/database/GeoLiteCountry/GeoIP.dat.gz"
  rules:
    - ""
  authentication_mode: database
  # If timezone_search is undefined or false, searching based on time will
  # use UTC times (historical behavior). If timezone_search is true
  # searching will use local time.
  timezone_search: true
  # uncomment to set time zone to time zone of box from /usr/share/zoneinfo, e.g. "America/Cancun"
  # time_zone: 'UTC'
  time_zone: Australia/Sydney
...
```

To finish off the installation we run:

```
root@server:~/usr/local/src/snorby# bundle exec rake snorby:setup
```

And finally we can start the service:

```
root@server:~/usr/local/src/snorby# bundle exec rails server -e production -d
=> Booting WEBrick
=> Rails 3.1.12 application starting in production on http://0.0.0.0:3000
=> Call with -d to detach
=> Ctrl-C to shutdown server
[2014-07-22 15:34:41] INFO  WEBrick 1.3.1
[2014-07-22 15:34:41] INFO  ruby 1.9.3 (2013-11-22) [x86_64-linux]
[2014-07-22 15:34:41] INFO  WEBrick::HTTPServer#start: pid=21888 port=3000
```

Just a quick note here on a error I faced. In case we get error message in the console "The Snorby worker is not currently running!" we need to restart it:

```
root@server:~# rails c production
Loading production environment (Rails 3.1.0)
irb(main):001:0> Snorby::Worker.stop
=> ""
irb(main):002:0> Snorby::Jobs.clear_cache
=> nil
irb(main):003:0> Snorby::Worker.start
=> ""
irb(main):004:0> exit
```

### Apache

We want to setup Apache SSL proxy as front-end for the Snorby dashboard. We install the needed packages and enable the modules needed by apache proxy:

```
root@server:~# aptitude install libapache2-mod-evasive libapache2-mod-spamhaus libapache2-mod-proxy-html apache2-mpm-worker libapache2-mod-security2 libapache2-mod-auth-mysql libapache2-mod-auth-radius libapache2-mod-authn-sasl
root@server:~# a2enmod rewrite
root@server:~# a2enmod ssl
root@server:~# a2enmod auth_digest
root@server:~# a2enmod proxy_html
root@server:~# a2enmod xml2enc
root@server:~# a2enmod proxy_connect
root@server:~# a2enmod proxy_http
root@server:~# a2enmod authnz_ldap
```

Now to configure the proxy in `/etc/apache2/sites-available/snorby.conf` file:

```
<VirtualHost *:80>
  ServerName server.mydomain.com
  DocumentRoot /var/www/html/
  ErrorLog /var/log/apache2/snorby_error.log
  CustomLog /var/log/apache2/snorby_access.log combined
  RewriteEngine On
  RewriteCond %{HTTPS} !=on
  RewriteRule ^(.*)$ https://server.mydomain.com$1
  <Directory /var/www/html/>
    Options None
    Order allow,deny
    allow from all
  </Directory>
</VirtualHost>
 
<VirtualHost *:443>
  ServerName server.mydomain.com
  ServerAlias www.server.mydomain.com
  DocumentRoot /var/www/html/
  ErrorLog /var/log/apache2/snorby_error.log
  CustomLog /var/log/apache2/snorby_access.log combined
  LogLevel info
  SSLEngine on
  [...]
  SSL CERTIFICATE FILES HERE
  [...]
  <FilesMatch "\.(cgi|shtml|phtml|php)$">
    SSLOptions +StdEnvVars
  </FilesMatch>
  <Directory /var/www/html/>
      Options None
      Order allow,deny
      allow from all
      AuthType Digest
      AuthName "Secure"
      AuthUserFile "/etc/apache2/user.passwd"
      AuthDigestProvider file
      Require valid-user
  </Directory>
  
  #
  # Proxy
  #
  #ProxyHTMLLogVerbose on
  SSLProxyEngine On
  ProxyRequests Off
  ProxyPreserveHost On
  ProxyTimeout 60
  #ProxyHTMLExtended On
  ProxyPass / http://127.0.0.1:3000/
  ProxyPassReverse / http://127.0.0.1:3000/
  ProxyHTMLURLMap / /
  SetEnvIf User-Agent ".*MSIE [2-6].*" \
        nokeepalive ssl-unclean-shutdown \
        downgrade-1.0 force-response-1.0
  SetEnvIf User-Agent ".*MSIE [7-9].*" \
        ssl-unclean-shutdown
</VirtualHost>
```

Enable the configuration and restart apache:

```
root@server:~# a2enconf encompass-security.conf
root@server:~# a2enconf security
root@server:~# a2ensite snorby
root@server:~# a2dissite 000-default
root@server:~# service apache2 restart
```

Now when we navigate to https://server.mydomain.com we will be met with the Snorby Dashboard.

## Clients

Install some dependencies first:

```
# aptitude install libpcre3 libpcre3-dev autoconf libcrypt-ssleay-perl libtool libssl-dev build-essential automake gcc make flex bison libdnet-dev libpcap-dev nbtscan g++ libpcap-ruby zlib1g-dev libmysqld-dev libdnet libdnet-dev libpcre3 libpcre3-dev gcc byacc bison linux-headers-generic libxml2-dev libdumbnet-dev zlib1g zlib1g-dev
```

### DAQ

For Ubuntu-12.04:

```
# cd /usr/local/src
# wget https://www.snort.org/downloads/snort/daq-2.0.2.tar.gz
# tar -xzvf daq-2.0.2.tar.gz
# cd daq-2.0.2
# ./configure && make && make install
# snort --daq-list
Available DAQ modules:
pcap(v3): readback live multi unpriv
ipfw(v3): live inline multi unpriv
dump(v2): readback live inline multi unpriv
afpacket(v5): live inline multi unpriv
```

For CentOS/Redhat:

```
# yum remove libpcap libpcap-devel
# wget http://www.tcpdump.org/release/libpcap-1.1.1.tar.gz
# tar -xzvf libpcap-1.1.1.tar.gz
# cd libpcap-1.1.1
# ./configure --prefix=/usr
# make && make install
# ldconfig -v
# ldconfig -p | grep pcap
    libpcap.so.1 (libc6,x86-64) => /usr/lib/libpcap.so.1
    libpcap.so (libc6,x86-64) => /usr/lib/libpcap.so
 
# cd /usr/local/src
# wget https://www.snort.org/downloads/snort/daq-2.0.2.tar.gz
# tar -xzvf daq-2.0.2.tar.gz
# cd daq-2.0.2
# ./configure --with-libpcap-libraries=/usr/lib/
# make && make install
# ldconfig -v
 
# cd /usr/local/src
# wget http://ftp.csx.cam.ac.uk/pub/software/programming/pcre/pcre-8.35.tar.gz
# tar -xzvf pcre-8.35.tar.gz
# cd pcre-8.35
# ./configure --enable-utf8
# make && make install
# ldconfig -v
```

### Snort

We start with creating the snort system user:

```
# mkdir /var/log/snort
# groupadd -r --gid 513 snort
# useradd -r -c " Snort IDS" -s /bin/false -d /var/log/snort -G adm -g snort -u 513 snort
# chown snort:adm /var/log/snort
# chmod 750 /var/log/snort
# chmod g+s /var/log/snort
```

Then we fetch the snort source:

```
# cd /usr/local/src
# wget --no-check-certificate -O snort-2.9.6.2.tar.gz https://www.snort.org/downloads/snort/snort-2.9.6.2.tar.gz
# tar -xzvf snort-2.9.6.2.tar.gz
# cd snort-2.9.6.2
```

For Ubuntu-12.04:

```
# ./configure --prefix /usr/local/snort --enable-sourcefire
# make && make install
```

For CentOS/RedHat:

```
# yum install libdnet-devel
# ./configure --prefix /usr/local/snort --enable-sourcefire --with-libpcap-libraries=/usr/lib --with-daq-libraries=/usr/local/lib/daq --enable-zlib --enable-gre --enable-mpls --enable-targetbased --enable-ppm --enable-perfprofiling
# make && make install
```

Next steps are distribution independent. First we create the needed system links to the path were we installed and couple of rules directories:

```
# ln -s /usr/local/snort/bin/snort /usr/sbin/snort
# ln -s /usr/local/snort/bin/u2spewfoo /usr/sbin/u2spewfoo
# ln -s /usr/local/snort/bin/u2boat /usr/sbin/u2boat
# mkdir /usr/local/snort/lib/snort_dynamicrules
# ln -s /usr/local/snort/lib/snort_dynamicpreprocessor /usr/local/lib/snort_dynamicpreprocessor
# ln -s /usr/local/snort/lib/snort_dynamicengine /usr/local/lib/snort_dynamicengine
# ln -s /usr/local/snort/lib/snort_dynamicrules /usr/local/lib/snort_dynamicrules
# ldconfig -v
```

To finish the setup we need to download the Snort rules for our particular version and deploy them:

```
# cd /usr/local/src/snort-2.9.6.2
# wget --no-check-certificate -O snortrules-snapshot-2962.tar.gz https://www.snort.org/reg-rules/snortrules-snapshot-2962.tar.gz/<MY-OINK-CODE>
# tar -xzvf snortrules-snapshot-2962.tar.gz
# cp -R etc/ /usr/local/snort/
# rm -f /usr/local/snort/etc/Makefile*
# ln -s /usr/local/snort/etc /etc/snort
# cp -R rules/ /usr/local/snort/
# cp -R preproc_rules/ /usr/local/snort/
# rm -f /usr/local/snort/preproc_rules/Makefile*
# cp so_rules/precompiled/Ubuntu-12-04/x86-64/2.9.6.2/*.so /usr/local/snort/lib/snort_dynamicrules/
# mkdir /usr/local/snort/so_rules
# ldconfig -v
# snort -c /usr/local/snort/etc/snort.conf --dump-dynamic-rules=/usr/local/snort/so_rules
# touch /usr/local/snort/rules/white_list.rules /usr/local/snort/rules/black_list.rules
```

On CentOS/RedHat the only difference would be the source directory of the pre-compiled dynamic rules. So we replace Ubuntu-12-04 in the above line:

```
cp so_rules/precompiled/Ubuntu-12-04/x86-64/2.9.6.2/*.so /usr/local/snort/lib/snort_dynamicrules/
```

with Centos-5-4 or RHEL-5-5. The above section of commands crates the snort `so_rules` as well and we also create couple of list files.

At last we configure the local network Snort should sniff the traffic for, the format of its the output file (unified2 so it is ready for Barnyard processing) and enable the dynamic rule sets we just installed `/etc/snort/snort.conf`:

```
...
ipvar HOME_NET <my-subnet>
ipvar EXTERNAL_NET !$HOME_NET
...
# unified2
output unified2: filename snort.u2, limit 128
output log_unified2: filename snort.u2, limit 128
...
# dynamic library rules
 include $SO_RULE_PATH/bad-traffic.rules
 include $SO_RULE_PATH/browser-ie.rules
 include $SO_RULE_PATH/chat.rules
 include $SO_RULE_PATH/dos.rules
 include $SO_RULE_PATH/exploit.rules
 include $SO_RULE_PATH/file-flash.rules
 include $SO_RULE_PATH/icmp.rules
 include $SO_RULE_PATH/imap.rules
 include $SO_RULE_PATH/misc.rules
 include $SO_RULE_PATH/multimedia.rules
 include $SO_RULE_PATH/netbios.rules
 include $SO_RULE_PATH/nntp.rules
 include $SO_RULE_PATH/p2p.rules
 include $SO_RULE_PATH/smtp.rules
 include $SO_RULE_PATH/snmp.rules
 include $SO_RULE_PATH/specific-threats.rules
 include $SO_RULE_PATH/web-activex.rules
 include $SO_RULE_PATH/web-client.rules
 include $SO_RULE_PATH/web-iis.rules
 include $SO_RULE_PATH/web-misc.rules
```

### Pulledpork

We need to constantly update our Snort rules from the public repository on the clients and the server in order to stay up-to-date with the recent threats. We can use the Pulledpork script for this purpose.

```
root@server:~# mkdir -p /usr/local/pulledpork
root@server:~# cd /usr/local/pulledpork/
root@server:/usr/local/pulledpork# wget http://pulledpork.googlecode.com/svn/trunk/pulledpork.pl
root@server:/usr/local/pulledpork# chmod u+x pulledpork.pl
```

Then we need to configure it `/usr/local/pulledpork/pulledpork.conf`:

```
rule_url=https://www.snort.org/reg-rules/|snortrules-snapshot-2962.tar.gz|<MY-OINK-CODE>
rule_url=https://s3.amazonaws.com/snort-org/www/rules/community/|community-rules.tar.gz|Community
rule_url=http://labs.snort.org/feeds/ip-filter.blf|IPBLACKLIST|open
rule_url=https://www.snort.org/reg-rules/|opensource.gz|<MY-OINK-CODE>
rule_url=https://rules.emergingthreatspro.com/|emerging.rules.tar.gz|open
ignore=deleted.rules,experimental.rules,local.rules
temp_path=/tmp
rule_path=/usr/local/snort/rules/snort.rules
local_rules=/usr/local/snort/rules/local.rules
sid_msg=/usr/local/snort/etc/sid-msg.map
sid_msg_version=1
sid_changelog=/var/log/sid_changes.log
sorule_path=/usr/local/lib/snort_dynamicrules/
sostub_path=/usr/local/snort/so_rules/
snort_path=/usr/sbin/snort
config_path=/usr/local/snort/etc/snort.conf
distro=Ubuntu-12-4
snort_version=2.9.6.2
black_list=/usr/local/snort/rules/black_list.rules
IPRVersion=/usr/local/snort/rules/iplists
version=0.7.1
```

And to update the rules we just need to run it:

```
root@server:/usr/local/pulledpork# ./pulledpork.pl -k -K /usr/local/snort/rules -c pulledpork.conf -o /usr/local/snort/rules -s /usr/local/snort/so_rules
```

After that we need to restart the snort service so the new rules get loaded. To make the updates run automatically we add this to the root crontab:

```
# Pulledpork - Update Snort rules
00 01 1 * * /usr/local/pulledpork/pulledpork.pl -k -K /usr/local/snort/rules -c /usr/local/pulledpork/pulledpork.conf -o /usr/local/snort/rules -s /usr/local/snort/so_rules
```

so it runs every first day of the week at 1am. The same setup goes into each client too.

### Barnyard2

Same as for the server configuration we clone the current master from Git and build from source:

```
# cd /usr/local/src
# aptitude install git
# git clone  http://github.com/firnsy/barnyard2.git barnyard
# cd barnyard/
```

For Ubuntu-12.04:

```
# autoreconf -fvi -I ./m4
# ./configure --with-mysql --with-mysql-libraries=/usr/lib/x86_64-linux-gnu
# make && make install
```

For CentOS/RedHat:

```
# ./autogen.sh
# ./configure --with-mysql --with-mysql-libraries=/usr/lib64/mysql/
# make && make install
```

Now we need to configure Branyard so it can find the Snort output files and connect to the MySQL database we setup on the server `/usr/local/etc/barnyard2.conf`:

```
config reference_file:      /etc/snort/reference.config
config classification_file: /etc/snort/classification.config
config gen_file:            /etc/snort/gen-msg.map
config sid_file:            /etc/snort/sid-msg.map
config logdir: /var/log/snort
config waldo_file: /var/log/snort/barnyard2.waldo
config archivedir: /var/log/snort/archive
input unified2
config hostname:   client
config interface:  eth0
config process_new_records_only
#config event_cache_size: 32768
#config dump_payload
output alert_fast: /var/log/snort/barnyard_alert
output database: log, mysql, user=snorby password=<snort-password> dbname=snorby host=server.mydomain.com
```

This file will be practically same on all of the clients apart from the different host name in the `config hostname:` line.

Before we start Barnyard we need to open TCP port 3306 in the server's Security Group for the client's Security Group and grant access to the main database from this host(s):

```
mysql> GRANT ALL ON snorby.* TO 'snorby'@'client.mydomain.com' IDENTIFIED BY '<snort-password>';
```

and test the connection:

```
# mysql -h server.mydomain.com -u snorby -p<snort-password>
```

If all good we move to the next step to start the daemons. We need to repeat this for each client we want to monitor.

After all is in place we can start the processes:

```
# /usr/sbin/snort -u snort -g snort -dev -l /var/log/snort -c /etc/snort/snort.conf -D
# /usr/local/bin/barnyard2 -c /usr/local/etc/barnyard2.conf -d /var/log/snort -f snort.u2 -w /var/log/snort/barnyard2.waldo -l /var/log/snort -a /var/log/snort/archive -D
```

## Converting the compiled packages into services

Of course manually starting and killing the services is not really good especially with high number of servers. Hence I have set service scripts and config files on each host.

### Snort

For Ubuntu-12-04 hosts download the [snort-ubuntu-initd.sh]({{ site.baseurl }}/download/snort-ubuntu-initd.sh) file and place it as `/etc/init.d/snort`. Make it executable:

```
root@server:~# chmod +x /etc/init.d/snort
```

and copy the example config file from snort source on each host:

```
root@server:~# cp rpm/snort.sysconfig /etc/default/snort
```

then set the values as needed, in our case `/etc/default/snort`:

```
INTERFACE=eth0
CONF=/etc/snort/snort.conf
USER=snort
GROUP=snort
PASS_FIRST=0
LOGDIR=/var/log/snort
ALERTMODE=fast
DUMP_APP=1
BINARY_LOG=0
NO_PACKET_LOG=0
PRINT_INTERFACE=0
SYSLOG=/var/log/syslog
SECS=5
```

Then set the default run levels:

```
root@server:~# update-rc.d snort defaults
```

For rpm distros like CentOS/RedHat download the [snort-centos-initd.sh]({{ site.baseurl }}/download/snort-centos-initd.sh) file and place it as `/etc/init.d/snort`. Make it executable:

```
root@content~# chmod +x /etc/init.d/snort
```

and copy the example config file from snort source on each host:

```
root@content:~# cp rpm/snort.sysconfig /etc/sysconfig/snort
```

then set the values as needed, in our case `/etc/sysconfig/snort`:

```
# /etc/sysconfig/snort
# $Id: snort.sysconfig,v 1.8 2003/09/19 05:18:12 dwittenb Exp $
 
#### General Configuration
INTERFACE=eth0
CONF=/etc/snort/snort.conf
USER=snort
GROUP=snort
PASS_FIRST=0
 
#### Logging & Alerting
LOGDIR=/var/log/snort
ALERTMODE=fast
DUMP_APP=1
BINARY_LOG=0
NO_PACKET_LOG=0
PRINT_INTERFACE=0 
```

Then set the default run levels:

```
root@content~# chkconfig --add snort
```

### Barnyard2

Ubuntu-12.04 files: 
[barnyard-ubuntu-initd.sh]({{ site.baseurl }}/download/barnyard-ubuntu-initd.sh)
`/etc/default/barnyard2`

```
# Config file for /etc/init.d/barnyard2
LOG_FILE="snort.u2"
SNORTDIR="/var/log/snort"
INTERFACES="eth0"
CONF=/etc/snort/barnyard2.conf
EXTRA_ARGS="" 
```

CentOS/RedHat files: 
[barnyard-centos-initd.sh]({{ site.baseurl }}/download/barnyard-centos-initd.sh)
`/etc/sysconfig/barnyard2`

```
# Config file for /etc/init.d/barnyard2
LOG_FILE="snort.u2"
SNORTDIR="/var/log/snort"
INTERFACES="eth0"
CONF=/etc/snort/barnyard2.conf
ARCHIVEDIR="$SNORTDIR/archive"
WALDO_FILE="$SNORTDIR/barnyard2.waldo"
EXTRA_ARGS=""
```