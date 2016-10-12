---
type: posts
header:
  teaser: 'Device-Mesh.jpg'
title: 'Secure Nginx with Naxsi, SSL, GeoIP and Google Page Speed modules on Debian/Ubuntu'
category: 'Web Server'
tags: [nginx, ssl, geoip]
---

We will use the latest stable version of `nginx-naxsi` which has `XSS` (Cross Site Scripting) protection via `Naxsi` module. We will also build and install this Debian way on Ubuntu-12.04 Precise since we want to include some other useful modules, SSL being one of them, that are not enabled by default. The problem with `Nginx` is that it's not modular like `Apache` so we can't add modules on the fly but we have to recompile from source every time we want to add a new one. It is a small price to pay though for the speed and lightness we get.  

```
root@nginx:~# aptitude install apache2-utils liblua5.1-dev daemon dbconfig-common
root@nginx:~# add-apt-repository ppa:nginx/stable
root@nginx:~# aptitude update
root@nginx:~# aptitude build-dep nginx-naxsi
root@nginx:~# cd /tmp
root@nginx:/tmp# apt-get source nginx-naxsi
root@nginx:/tmp# cd nginx-1.6.0
root@nginx:/tmp/nginx-1.6.0# vi nginx-1.6.0/auto/options
...
change HTTP_GEOIP=NO to HTTP_GEOIP=YES (and enable some other modules like DAV,SSL,SUB,XSLT etc. if needed)
...
```

Next we setup the page speed module:

```
root@nginx:/tmp# wget https://github.com/pagespeed/ngx_pagespeed/archive/release-1.9.32.3-beta.zip
root@nginx:/tmp# unzip -d /tmp/nginx-1.6.0/debian/modules -o release-1.9.32.3-beta.zip
root@nginx:/tmp# mv /tmp/nginx-1.6.0/debian/modules/ngx_pagespeed-release-1.9.32.3-beta /tmp/nginx-1.6.0/debian/modules/ngx_pagespeed
root@nginx:/tmp# wget https://dl.google.com/dl/page-speed/psol/1.9.32.3.tar.gz
root@nginx:/tmp# tar -xzf 1.9.32.3.tar.gz -C /tmp/nginx-1.6.0/debian/modules/ngx_pagespeed/
```

Next we change the Nginx version in the changelog file:

```
root@server:/tmp/nginx-1.6.0# vi debian/changelog
```

change the first line:

```
nginx (1.6.0-1+precise0) precise; urgency=medium
```

to:

```
nginx (1.6.0-1+precise0-naxsi) precise; urgency=medium
```

and start the building process:

```
root@nginx:/tmp/nginx-1.6.0# dpkg-buildpackage -uc -b
```

After it finishes we install the `.deb` files created in the parent directory of the one we are building in:

```
root@nginx:/tmp/nginx-1.6.0# dpkg -i ../nginx-naxsi_1.6.0-1+precise0-naxsi_amd64.deb ../nginx-common_1.6.0-1+precise0-naxsi_all.deb ../nginx-naxsi-ui_1.6.0-1+precise0-naxsi_amd64.deb
root@nginx:/etc/nginx# nginx -V
nginx version: nginx/1.6.0-1+precise0-naxsi
TLS SNI support enabled
configure arguments: --with-cc-opt='-g -O2 -fstack-protector --param=ssp-buffer-size=4 -Wformat -Wformat-security -Werror=format-security -D_FORTIFY_SOURCE=2' --with-ld-opt='-Wl,-Bsymbolic-functions -Wl,-z,relro' --prefix=/usr/share/nginx --conf-path=/etc/nginx/nginx.conf --http-log-path=/var/log/nginx/access.log --error-log-path=/var/log/nginx/error.log --lock-path=/var/lock/nginx.lock --pid-path=/run/nginx.pid --http-client-body-temp-path=/var/lib/nginx/body --http-fastcgi-temp-path=/var/lib/nginx/fastcgi --http-proxy-temp-path=/var/lib/nginx/proxy --http-scgi-temp-path=/var/lib/nginx/scgi --http-uwsgi-temp-path=/var/lib/nginx/uwsgi --with-debug --with-pcre-jit --with-ipv6 --with-http_ssl_module --with-http_stub_status_module --with-http_realip_module --with-http_auth_request_module --without-mail_pop3_module --without-mail_smtp_module --without-mail_imap_module --without-http_uwsgi_module --without-http_scgi_module --add-module=/tmp/nginx-1.6.0/debian/modules/naxsi/naxsi_src --add-module=/tmp/nginx-1.6.0/debian/modules/nginx-cache-purge --add-module=/tmp/nginx-1.6.0/debian/modules/nginx-upstream-fair
```

Now we have to pin the compiled version so it doesn't get overwritten by update, create `/etc/apt/preferences.d/nginx` file with following content:

```
Package: nginx-naxsi
Pin: version 1.6.0-1+precise0-naxsi
Pin-Priority: 1001

Package: nginx-common
Pin: version 1.6.0-1+precise0-naxsi
Pin-Priority: 1001
 
Package: nginx-naxsi-ui
Pin: version 1.6.0-1+precise0-naxsi
Pin-Priority: 1001
```

If we use the built debian packages on other servers we should remember to do the pinning there too.

To enable Naxsi we create the following `/etc/nginx/mysite.rules` file:

```
LearningMode; #Enables learning mode
SecRulesEnabled;
#SecRulesDisabled;
DeniedUrl "/RequestDenied";
## check rules
CheckRule "$SQL >= 8" BLOCK;
CheckRule "$RFI >= 8" BLOCK;
CheckRule "$TRAVERSAL >= 4" BLOCK;
CheckRule "$EVADE >= 4" BLOCK;
CheckRule "$XSS >= 8" BLOCK;
```

then we can include the following line in the `http {}` section of the `/etc/nginx/nginx.conf` file:

```
include /etc/nginx/naxsi_core.rules;
```

and the following line:

```
include /etc/nginx/mysite.rules;
```

in any `/etc/nginx/sites-enabled/<site-name>.conf` file in the `location / {}` section.

As added security for sites with limited public access, I block access from countries like China, USA, Russia where most of the hacking attempts come from. For that purpose I use GeoIP module.

```
root@nginx:/tmp/nginx-1.6.0# cd /usr/share/GeoIP/
root@nginx:/usr/share/GeoIP# wget http://geolite.maxmind.com/download/geoip/database/GeoLiteCity.dat.gz
root@nginx:/usr/share/GeoIP# gzip -d GeoLiteCity.dat.gz
```

Then we specify where the GeoIP database is located on our system and tell Nginx which countries are gonna be blocked (see the security file below for details). At the end we put the following at the end of fastcgi config file `/etc/nginx/fastcgi_params`:

```
# GeoIP
fastcgi_param GEOIP_COUNTRY_CODE $geoip_country_code;
fastcgi_param GEOIP_COUNTRY_NAME $geoip_country_name;
fastcgi_param GEOIP_CITY $geoip_city;
fastcgi_param GEOIP_REGION $geoip_region;
fastcgi_param GEOIP_POSTAL_CODE $geoip_postal_code;
fastcgi_param GEOIP_AREA_CODE $geoip_area_code;
fastcgi_param GEOIP_CITY_CONTINENT_CODE $geoip_city_continent_code;
```

Next is the basic Nginx configuration in `/etc/nginx/nginx.conf`:

```
user www-data;
worker_processes auto;
#worker_priority 15; # renice the process, with 15 max cpu usage ~25%=(20-15)/20
pid /run/nginx.pid;

events {
    worker_connections 512;
    multi_accept on;
}

http {

    ##
    # Basic Settings
    ##
    tcp_nopush on;
    tcp_nodelay on;
    client_body_timeout 30;
    client_header_timeout 10;
    keepalive_timeout 65 20;
    types_hash_max_size 2048;
    ignore_invalid_headers on;
    server_names_hash_bucket_size 128;

    client_header_buffer_size   1k;
    client_body_buffer_size     128k;
    large_client_header_buffers 4 4k;

    include                   /etc/nginx/mime.types;
    default_type              application/octet-stream;
    keepalive_requests        100;  # number of requests per connection, does not affect SPDY
    keepalive_disable         none; # allow all browsers to use keepalive connections
    max_ranges                1;    # allow a single range header for resumed downloads and to stop large range header DoS attacks
    msie_padding              off;
    open_file_cache           max=1000 inactive=2h;
    open_file_cache_errors    on;
    open_file_cache_min_uses  1;
    open_file_cache_valid     1h;
    output_buffers            1 512k;
    postpone_output           1460;  # postpone sends to match our machine's MSS
    read_ahead                512K;  # kernel read head set to the output_buffers
    reset_timedout_connection on;    # reset timed out connections freeing ram
    sendfile                  on;    # on for decent direct disk I/O
    server_tokens             off;   # version number in error pages
    server_name_in_redirect   off;   # if off, nginx will use the requested Host header
    source_charset            utf-8; # same value as "charset"

    ## Request limits
    limit_req_zone  $binary_remote_addr  zone=nginx:1m   rate=1000r/m;

    ##
    # SSL Settings
    ##
    ssl_session_tickets       on;
    ssl_session_cache         shared:SSL:20m;
    ssl_session_timeout       4h;
    ssl_dhparam               /etc/nginx/ssl/dhparam.pem;
    ssl_ecdh_curve            secp384r1;
    ssl_certificate           /etc/nginx/ssl/star_mydomain_com.crt;
    ssl_certificate_key       /etc/nginx/ssl/star_mydomain_com.crt;
    ssl_protocols             TLSv1 TLSv1.1 TLSv1.2;
    ssl_prefer_server_ciphers on;
    ssl_ciphers           'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:ECDHE-RSA-RC4-SHA:ECDHE-ECDSA-RC4-SHA:RC4-SHA:HIGH:!aNULL:!eNULL:!EXPORT:!DES:!3DES:!MD5:!PSK';

    ##
    # GeoIP
    ##
    geoip_country /usr/share/GeoIP/GeoIP.dat;
    geoip_city    /usr/share/GeoIP/GeoLiteCity.dat;

    ##
    # ngx_pagespeed config
    ##
    pagespeed on;
    pagespeed FileCachePath "/var/cache/ngx_pagespeed/";
    pagespeed EnableFilters combine_css,combine_javascript;
    pagespeed PreserveUrlRelativity on;

    ##
    # LDAP
    ##
    auth_ldap_cache_enabled off;
    auth_ldap_cache_expiration_time 10000;
    auth_ldap_cache_size 1000;

    ldap_server ldap1 {
      url ldap://ldap1.mydomain.com:389/ou=Users,dc=mydomain,dc=com?uid?sub;
      binddn "cn=binduser,ou=Users,dc=mydomain,dc=com";
      binddn_passwd bindpassword;
      group_attribute memberUid;
      group_attribute_is_dn on;
      require group "cn=mygroup,ou=Groups,dc=mydomain,dc=com";
      require valid_user;
    }
 
    ldap_server ldap2 {
      url ldap://ldap2.mydomain.com:389/ou=Users,dc=mydomain,dc=com?uid?sub;
      binddn "cn=binduser,ou=Users,dc=mydomain,dc=com";
      binddn_passwd bindpassword;
      group_attribute memberUid;
      group_attribute_is_dn on;
      require group "cn=mygroup,ou=Groups,dc=mydomain,dc=com";
      require valid_user;
    }

    ##
    # Logging Settings
    ##
    ## Log Format
    log_format  main  '$remote_addr $host $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent" $ssl_cipher $request_time';
    access_log  /var/log/nginx/access.log;
    error_log   /var/log/nginx/error.log;

    ##
    # Gzip Settings
    ##
    gzip on;
    gzip_disable "msie6";
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    #gzip_buffers 16 8k;
    gzip_buffers  128 32k;
    #gzip_http_version 1.1;
    #gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
    gzip_types  text/plain text/css text/x-component
                text/xml application/xml application/xhtml+xml application/json
                image/x-icon image/bmp image/svg+xml application/atom+xml
                text/javascript application/javascript application/x-javascript
                application/pdf application/postscript
                application/rtf application/msword
                application/vnd.ms-powerpoint application/vnd.ms-excel
                application/vnd.ms-fontobject application/vnd.wap.wml
                application/x-font-ttf application/x-font-opentype;

    ##
    # Naxsi rules
    ##
    include /etc/nginx/naxsi_core.rules;

    ##
    # Virtual Host Configs
    ##
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
```

For user access we are using LDAP, see [Nginx LDAP module on Debian/Ubuntu](/blog/server/Nginx-LDAP-module/) for the details about compiling NGINX for LDAP support if needed. Otherwise use the basic authentication with local password file.

We are going to setup an SSL proxy for server `myserver` in a SSL enabled virtual host. We will first configure stronger DHE parameters, default one is 1024 bits and since our cert is 2048 bit we can go with stronger `DHE` (Ephemeral Diffie-Hellman) cryptographic values:

```
root@nginx:~# openssl dhparam -out /etc/nginx/ssl/dhparam.pem 2048
```

We will also force the use of the strong `ECDHE` (Elliptic DHE) only for `PFS` (Perfect Forward Secrecy) and stipulate this via `ssl_prefer_server_ciphers` parameter enabled in the `/etc/nginx/sites-available/myserver` file we create:

```
server {
    ssl             on;
    listen          443 ssl backlog=1250 so_keepalive=on;
    server_name     myserver.mydomain.com www.myserver.mydomain.com;
    root            /var/www/myserver;
    index           index.html index.htm;
 
    access_log      /var/log/nginx/myserver-access.log main;
    error_log       /var/log/nginx/myserver-error.log;
 
    add_header      Cache-Control "public";
    #add_header     Content-Security-Policy "default-src 'none';style-src 'self';img-src 'self' data: ;";
    add_header      X-Content-Type-Options "nosniff";
    add_header      X-Frame-Options "DENY";
    # Config to enable HSTS(HTTP Strict Transport Security) https://developer.mozilla.org/en-US/docs/Security/HTTP_Strict_Transport_Security
    # To avoid ssl stripping https://en.wikipedia.org/wiki/SSL_stripping#SSL_stripping
    add_header      Strict-Transport-Security "max-age=315360000; includeSubdomains";
    expires         max;
    limit_req       zone=myserver burst=200 nodelay; # works in conjuction with limit_req_zone set in nginx.conf
 
    location / {
       include  /etc/nginx/mysite.rules;
       try_files $uri $uri/ /index.html;
       auth_ldap "Restricted";
       auth_ldap_servers ldap1;
       auth_ldap_servers ldap2;
    }
 
    ## Some proxy
    location /someproxy {
       proxy_pass http://127.0.0.1:8080;
       proxy_read_timeout 90;
    }
 
    location ~ /\. {
       deny  all;
    }
 
    location /RequestDenied {
       return 418;
    }
}
```

We will also set some cutom security on top of it blocking some bots and using GeoIP, `/etc/nginx/conf.d/security` file:

```
## Block some nasty robots/bots
if ($http_user_agent ~ (msnbot|Purebot|Baiduspider|Lipperhey|Mail.Ru|scrapbot|Morfeus|masscan) ) {
     return 403;
}
 
## Block torrent trackers ddos attacks
location /announc {
    access_log off;
    error_log off;
    default_type text/plain;
    return 410 "d14:failure reason13:not a tracker8:retry in5:nevere";
}
 
## Deny scripts inside writable directories
location ~* /(images|cache|media|logs|tmp)/.*.(php|pl|py|jsp|asp|sh|cgi)$ {
     return 403;
}
 
## Block HEAD requests
if ($request_method !~ ^(HEAD)$ ) {
     return 444;
}
 
## Prevent image hotlinking
location ~ .(gif|png|jpe?g)$ {
     valid_referers none blocked mydomain.com *.mydomain.com;
     if ($invalid_referer) {
        return   403;
    }
}
 
## GeoIP
geoip_country /usr/share/GeoIP/GeoIP.dat;
geoip_city /usr/share/GeoIP/GeoLiteCity.dat;
if ($geoip_country_code ~ (CN|KR|US|RU) ) {
     return 403;
}
```

At the end we enable the myserver virtual host, disable the default one and restart Nginx:

```
root@nginx:/opt# rm -f /etc/nginx/sites-enabled/default
root@nginx:/opt# ln -sf /etc/nginx/sites-available/myserver /etc/nginx/sites-enabled/myserver
root@nginx:/opt# service nginx configtest
root@nginx:/opt# service nginx restart
```

NGINX built and deployed in the way described above has given me at least A on [Quallys SSL Labs](https://www.ssllabs.com/) tests. Obviuosly re-building NGINX for every update is going to be a tedious task and that's why I've put this procedure into Ansible playbook that does this for us. It creates a new EC2 instance, re-builds NGINX on it, creates an AMI that we can use to launch NGINX instances in our AWS VPC's, and terminates the EC2 instance when finished.
