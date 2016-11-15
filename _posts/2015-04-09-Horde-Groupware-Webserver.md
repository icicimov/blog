---
type: posts
header:
  teaser: 'Business-Communication.jpg'
title: 'Horde Groupware Webserver'
categories: 
  - Server
tags: [horde, webmail, imap, smtp]
---
{% include toc %}
[Horde](https://www.horde.org/apps/webmail) Groupware Webserver Edition is a free, enterprise ready, browser based communication suite. Users can read, send and organize server messages and manage and share calendars, contacts, tasks, notes, files and bookmarks. It can be extended with any of the released Horde applications or the Horde modules that are still in development, like a bookmark manager, or a file manager. 

Horde will provide access to our IMAP server via web console.

## Setup

We install PEAR and then using this system install we install another version of PEAR that is system independent and will be used for Horde install and upgrade only.

```
root@server:~# aptitude install debpear
root@server:~# mkdir /var/www/webmail
root@server:~# pear config-create /var/www/webmail/ /var/www/webmail/pear.conf
root@server:~# pear -c /var/www/webmail/pear.conf install pear
root@server:~# /var/www/webmail/pear/pear -c /var/www/webmail/pear.conf channel-discover pear.horde.org
root@server:~# /var/www/webmail/pear/pear -c /var/www/webmail/pear.conf install horde/horde_role
root@server:~# /var/www/webmail/pear/pear -c /var/www/webmail/pear.conf run-scripts horde/horde_role
root@server:~# /var/www/webmail/pear/pear -c /var/www/webmail/pear.conf install -a -B horde/webmail
```

Next we setup MySQL database:

```
root@server:~# mysql -uroot -p
Enter password:
Welcome to the MySQL monitor.  Commands end with ; or \g.
Your MySQL connection id is 42
Server version: 5.5.31-0+wheezy1 (Debian)
Copyright (c) 2000, 2013, Oracle and/or its affiliates. All rights reserved.
Oracle is a registered trademark of Oracle Corporation and/or its
affiliates. Other names may be trademarks of their respective
owners.
Type 'help;' or '\h' for help. Type '\c' to clear the current input statement.
 
mysql> create database webmail;
Query OK, 1 row affected (0.00 sec)
 
mysql> use webmail;
Database changed
 
mysql> grant all on webmail.* to 'webmail'@'localhost' identified by '<password>';
Query OK, 0 rows affected (0.00 sec)
 
mysql> flush privileges;
Query OK, 0 rows affected (0.00 sec)
 
mysql> exit
```

and install the PHP5 database module:

```
root@server:~# aptitude install php5-mysql
```

We can now install Horde:

```
root@vmlt1:~# PHP_PEAR_SYSCONF_DIR=/var/www/webmail php -d include_path=/var/www/webmail/pear/php /var/www/webmail/pear/webmail-install

Installing Horde Groupware Webserver Edition
 
Configuring database settings
 
What database backend should we use?
    (false) [None]
    (mysql) MySQL / PDO
    (mysqli) MySQL (mysqli)
    (pgsql) PostgreSQL
    (sqlite) SQLite
 
Type your choice []: mysql
Request persistent connections?
    (1) Yes
    (0) No
 
Type your choice [0]:
 
Username to connect to the database as* [] webmail
Password to connect with
How should we connect to the database?
    (unix) UNIX Sockets
    (tcp) TCP/IP
 
Type your choice [unix]: unix
 
Location of UNIX socket [] /var/run/mysqld/mysqld.sock
 
Database name to use* [] webmail
 
Internally used charset* [utf-8]
 
Use SSL to connect to the server?
    (1) Yes
    (0) No
 
Type your choice [0]:
 
Certification Authority to use for SSL connections []
Split reads to a different server?
    (false) Disabled
    (true) Enabled
 
Type your choice [false]:
 
Writing main configuration file... done.
 
Creating and updating database tables... done.
 
Configuring administrator settings
 
Specify an existing server user who you want to give administrator
permissions (optional): <my-admin>
 
Writing main configuration file... done.
 
Thank you for using Horde Groupware Webserver Edition!
```

The settings can be found in the main config file `/var/www/webmail/config/conf.php` in case we need to change anything.

### IMAP configuration

We create new local config file `/var/www/webmail/imp/config/backends.local.php` to tell Horde how to connect to the IMAP server (`courier-imap` already installed):

```php
<?php
$servers['imap'] = array(
    'disabled' => false,
    'name' => 'IMAP Server',
    'hostspec' => 'localhost',
    'hordeauth' => 'false',
    'protocol' => 'imap',
    'port' => '443',
    'secure' => 'tls',
    'serverdomain' => '',
    // 'smtphost' => '',
    // 'smtpport' => '25',
    'cache' => 'false',
);
```

### Apache configuration

Install and setup Apache:

```
root@server:~# aptitude install apache2 libapache2-mod-php5 libapache2-mod-geoip
```

Configure GeoIP module in the `/etc/apache2/mods-enabled/geoip.conf` file (needs `geoip-database` package installed):

```
<IfModule mod_geoip.c>
  GeoIPEnable On
  GeoIPDBFile /usr/share/GeoIP/GeoIP.dat
  GeoIPEnableUTF8 On
  GeoIPOutput Env
  GeoIPScanProxyHeaders On
</IfModule>
```

Edit the default host in `/etc/apache2/sites-available/default` file:

```
<VirtualHost *:80>
    #RewriteEngine On
    #RewriteCond %{HTTPS} !=on
    #RewriteRule ^(.*)$ https://server.mydomain.com$1
    ServerName server.mydomain.com
...
    RedirectMatch 302 (?i)/autodiscover/autodiscover.xml https://server.mydomain.com/autodiscover/autodiscover.xml
    <Directory "/var/www/webmail/">
        php_value include_path /var/www/webmail/pear/php
        SetEnv PHP_PEAR_SYSCONF_DIR /var/www/webmail
    </Directory>
</VirtualHost>
```

Create the following file to set SSL access `/etc/apache2/sites-available/default-ssl`:

```
<IfModule mod_ssl.c>
SSLStrictSNIVhostCheck off
 
<VirtualHost _default_:443>
    ServerName server.mydomain.com
    ServerAdmin root@localhost
    DocumentRoot /var/www
 
    <Directory />
        Options FollowSymLinks
        AllowOverride None
    </Directory>
    <Directory /var/www/>
        Options Indexes FollowSymLinks MultiViews
        AllowOverride None
        SetEnvIf GEOIP_COUNTRY_CODE CN BlockCountry
        SetEnvIf GEOIP_COUNTRY_CODE KR BlockCountry
        SetEnvIf GEOIP_COUNTRY_CODE RU BlockCountry
        Order allow,deny
        Allow from all
        Deny from env=BlockCountry
    </Directory>
 
    ScriptAlias /cgi-bin/ /usr/lib/cgi-bin/
    <Directory "/usr/lib/cgi-bin">
        AllowOverride None
        Options +ExecCGI -MultiViews +SymLinksIfOwnerMatch
        SetEnvIf GEOIP_COUNTRY_CODE CN BlockCountry
        SetEnvIf GEOIP_COUNTRY_CODE KR BlockCountry
        SetEnvIf GEOIP_COUNTRY_CODE RU BlockCountry
        Order allow,deny
        Allow from all
        Deny from env=BlockCountry
    </Directory>
 
    ErrorLog ${APACHE_LOG_DIR}/error.log
 
    # Possible values include: debug, info, notice, warn, error, crit,
    # alert, emerg.
    LogLevel warn
 
    CustomLog ${APACHE_LOG_DIR}/ssl_access.log combined
 
    Alias /doc/ "/usr/share/doc/"
    <Directory "/usr/share/doc/">
        Options Indexes MultiViews FollowSymLinks
        AllowOverride None
        Order deny,allow
        Deny from all
        Allow from 127.0.0.0/255.0.0.0 ::1/128
    </Directory>
 
    SSLEngine on
    SSLCertificateFile    /etc/ssl/private/star_mydomain_com.pem
    SSLCertificateKeyFile /etc/ssl/private/star_mydomain_com_KEY.pem
    SSLCertificateChainFile /etc/ssl/private/DigiCertCA.pem
 
    <FilesMatch "\.(cgi|shtml|phtml|php)$">
        SSLOptions +StdEnvVars
    </FilesMatch>
    <Directory /usr/lib/cgi-bin>
        SSLOptions +StdEnvVars
    </Directory>
 
    BrowserMatch "MSIE [2-6]" \
        nokeepalive ssl-unclean-shutdown \
        downgrade-1.0 force-response-1.0
 
    # MSIE 7 and newer should be able to use keepalive
    BrowserMatch "MSIE [7-9]" ssl-unclean-shutdown
 
    ####
    #### HORDE WEBMAIL ###
    ####
    Alias /Microsoft-Server-ActiveSync /var/www/webmail/rpc.php   
    ## Replace Alias with Rewrite in case of php via mod_fcgid
    #RewriteRule ^/Microsoft-Server-ActiveSync /webmail/rpc.php [PT,L,QSA]
 
    RewriteRule .* - [E=HTTP_MS_ASPROTOCOLVERSION:%{HTTP:Ms-Asprotocolversion}]
    RewriteRule .* - [E=HTTP_X_MS_POLICYKEY:%{HTTP:X-Ms-Policykey}]
    RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
 
    ## Autodiscovery
    Alias /autodiscover/autodiscover.xml /var/www/webmail/rpc.php
    Alias /Autodiscover/Autodiscover.xml /var/www/webmail/rpc.php
    Alias /AutoDiscover/AutoDiscover.xml /var/www/webmail/rpc.php
    <Directory "/var/www/webmail/">
        Options +FollowSymlinks
        Order deny,allow
        Allow from all
        php_value include_path /var/www/webmail/pear/php
        SetEnv PHP_PEAR_SYSCONF_DIR /var/www/webmail
    </Directory>
    
    ## Protect the APC GUI cache page
    <Files "apc.php">
            AuthName Opcache-gui
            AuthType Basic
            AuthBasicProvider ldap
            AuthBasicAuthoritative on
            AuthLDAPURL "ldap://ldap.mydomain.com ldapreplica.mydomain.com:389/ou=Users,dc=mydomain,dc=com?uid" STARTTLS
            AuthLDAPBindDN cn=<my-ldap-user>,ou=Users,dc=mydomain,dc=com
            AuthLDAPBindPassword <password>
            AuthLDAPGroupAttribute memberUid
            AuthLDAPGroupAttributeIsDN off
            Require ldap-group cn=<my-ldap-group>,ou=Groups,dc=mydomain,dc=com
            Require valid-user
            Satisfy all
    </Files>
</VirtualHost>
</IfModule>
```

then enable the modules we are going need:

```
root@server:~# a2enmod ssl
root@server:~# a2enmod ldap
root@server:~# a2enmod authnz_ldap
```

check the configuration and restart Apache:

```
root@server:~# apache2ctl configtest
root@server:~# service apache2 restart
```

### ActiveSync

The following settings need to be added to the `/var/www/webmail/config/conf.php` confgiuration file for Microsoft-Server-ActiveSync support:

```
$conf['activesync']['emailsync'] = true;
$conf['activesync']['version'] = '14';
$conf['activesync']['autodiscovery'] = 'full';
$conf['activesync']['outlookdiscovery'] = false;
$conf['activesync']['logging']['type'] = 'horde';
$conf['activesync']['ping']['heartbeatmin'] = 60;
$conf['activesync']['ping']['heartbeatmax'] = 2700;
$conf['activesync']['ping']['heartbeatdefault'] = 480;
$conf['activesync']['ping']['deviceping'] = true;
$conf['activesync']['ping']['waitinterval'] = 15;
$conf['activesync']['enabled'] = true;
```
and the following line to the apache SSL vhost as shown above:

```
Alias /Microsoft-Server-ActiveSync /var/www/webmail/rpc.php
```

## Horde Tuning

There couple of things we can do to optimize Horde's performance.

### APC

Install and enable PHP APC code cache so the web server doesn't have to re-parse the php code for each request:

```
root@server:~# aptitude install php-apc
```

this will enable the module in `/etc/php5/conf.d/apc.ini` file:

```
extension=apc.so
```

if not, on Debian/Ubuntu systems we can enable manually by running:

```
root@server:~# php5enmod apc
```

then to configure it we create the following file `/etc/php5/conf.d/20-apc.ini`:

```
apc.shm_segments=1
apc.shm_size=64M
;max amount of memory a script can occupy
apc.max_file_size=1M
apc.ttl=7200
apc.user_ttl=7200
apc.gc_ttl=3600
; means we are always atomically editing the files
apc.file_update_protection=0
apc.enabled=1
apc.enable_cli=0
apc.cache_by_default=1
apc.filters = "-/var/www/webmail/pear/php/apc\.php$"
apc.include_once_override=0
apc.localcache=1
apc.localcache.size=512
apc.num_files_hint=512
apc.report_autofilter=0
apc.rfc1867=0
apc.slam_defense=0
apc.stat=1
apc.stat_ctime=0
apc.use_request_time=1
apc.user_entries_hint=1024
apc.write_lock=1
apc.mmap_file_mask = /tmp/apc-encompass.XXXXXX
```

and restart Apache. This will expose the APC monitoring GUI at `/var/www/webmail/pear/php/apc.php` and to protect it we have setup the LDAP authentication as shown in the Apache SSL config `/etc/apache2/sites-enabled/default-ssl`.

There are some user credentials in the `apc.php` file too which we can setup if we need to protect the page in case we don't want to do that through apache:

```
defaults('ADMIN_USERNAME','apc');             // Admin Username
defaults('ADMIN_PASSWORD','password');        // Admin Password - CHANGE THIS TO ENABLE!!!
```

The moment we change the default password the authentication will get enabled.

As mentioned above the APC is installed from ubuntu package repo. The newest version though is always available via php/pecl:

```
root@server:~# pecl channel-update pecl.php.net
Updating channel "pecl.php.net"
Update of Channel "pecl.php.net" succeeded

root@server:~# pecl search apc
Retrieving data...0%
.Matched packages, channel pecl.php.net:
=======================================
Package Stable/(Latest) Local
APC     3.1.13 (stable) 3.1.13 Alternative PHP Cache
APCu    4.0.7 (beta)           APCu - APC User Cache
```

### Autoload caching module

To benefit from further optimizations we can install autolad caching module which links the php classes to file paths (so in case the php compiler finds missing class it can convert the name into file path and load the file containing the missing class):

```
root@server:~# /var/www/webmail/pear/pear -c /var/www/webmail/pear.conf install -a -B horde/horde_autoloader_cache
horde/Horde_Autoloader_Cache can optionally use PHP extension "eaccelerator"
horde/Horde_Autoloader_Cache can optionally use PHP extension "xcache"
downloading Horde_Autoloader_Cache-2.0.3.tgz ...
Starting to download Horde_Autoloader_Cache-2.0.3.tgz (12,020 bytes)
.....done: 12,020 bytes
install ok: channel://pear.horde.org/Horde_Autoloader_Cache-2.0.3
```

### Install PHP image libraries

We run:

```
root@server~# aptitude install libcurl4-openssl-dev libmagic-dev libimage-exiftool-perl
root@server~# pecl install pecl_http
```

and add:

```
extension=http.so
```

to the Apache PHP5 ini file `/etc/php5/apache2/php.ini` or into a new file `/etc/php5/conf.d/http.ini` that we create in the PHP5 config directory.

### Enable viewing HTML eservers

In the `/var/www/webmail/imp/config/mime_drivers.php` file find the following section:

```
...
    /* HTML driver settings */
    'html' => array(
        /* NOTE: Inline HTML display is turned OFF by default. */
        'inline' => false,
        'handles' => array(
            'text/html'
        ),
...
```

and change `inline` to true.

## Updating Horde

We have already done the first step at the beggining of the installation:

```
root@server:~# /var/www/webmail/pear/pear -c /var/www/webmail/pear.conf channel-discover pear.horde.org
Adding Channel "pear.horde.org" succeeded
Discovery of channel "pear.horde.org" succeeded
```

so we just need to execute the following two:

```
root@server:~# /var/www/webmail/pear/pear -c /var/www/webmail/pear.conf remote-list -c horde
root@server:~# /var/www/webmail/pear/pear -c /var/www/webmail/pear.conf upgrade -a -B horde/webmail
```

Then login to the Horde admin console as the administrator user we set upon installation, go to the Configuration screen and click on "Upgrade all DB schemas" button.