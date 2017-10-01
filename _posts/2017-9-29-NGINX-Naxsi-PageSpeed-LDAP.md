---
type: posts
header:
  teaser: 'nginx.png'
title: 'Build NGINX 1.10.3 from package sources with added Naxsi, PageSpeed, LDAP and GeoIP on Ubuntu-16.04 Xenial'
categories: 
  - DevOps
tags: ['nginx', 'ldap']
date: 2017-9-29
---

The Nginx packages in Ubuntu Xenial do not come with some modules that are one of the most important when setting up Nginx for production use, like LDAP, Naxsi WAF and Pagespeed, just to mention some that I most frequently need and use. This is the process I go through to get these modules into DEB packages. 

# Build and Install

The work is being done on an AWS EC2 instance with Xenial installed:

```
# lsb_release -a
No LSB modules are available.
Distributor ID: Ubuntu
Description:    Ubuntu 16.04.3 LTS
Release:    16.04
Codename:   xenial
```

The current version of Nginx in Xenial is `1.10.3` so I start by downloading the source for it. 

```
cd /tmp
sudo apt build-dep nginx-extras nginx-common
sudo apt-get source nginx-extras
cd nginx-1.10.3/
```

Install some needed packages:

```
sudo apt install liblua5.1-0-dev libluajit-5.1-dev daemon dbconfig-common unzip
```

First I make sure I have the needed modules enabled in `nginx-1.10.3/auto/options`, change `HTTP_GEOIP=NO` to `HTTP_GEOIP=YES` and enable some other modules like DAV, SSL, SUB, XSLT etc. And then pulling in the needed modules like the LDAP one:

```
cd debian/modules/
git clone https://github.com/kvspb/nginx-auth-ldap.git
```

then `Pagespeed` with `PSOL`:

```
wget https://github.com/pagespeed/ngx_pagespeed/archive/latest-stable.zip
unzip latest-stable.zip
cd ngx_pagespeed-latest-stable/
wget https://dl.google.com/dl/page-speed/psol/1.12.34.2-x64.tar.gz
tar -xzvf 1.12.34.2-x64.tar.gz
rm 1.12.34.2-x64.tar.gz
```

and NAXSI too:

```
cd /tmp 
unzip master.zip 
cp -R naxsi-master/naxsi_src/ nginx-1.10.3/debian/modules/nginx-naxsi
```

Then I edit the `nginx-1.10.3/debian/rules` file and add the new modules to the appropriate section:

```
[...]
extras_configure_flags := \
                        $(common_configure_flags) \
                        --with-http_addition_module \
                        --with-http_dav_module \
[...]
                        --add-module=$(MODULESDIR)/nginx-lua \
                        --add-module=$(MODULESDIR)/nginx-upload-progress \
                        --add-module=$(MODULESDIR)/nginx-upstream-fair \
                        --add-module=$(MODULESDIR)/ngx_http_substitutions_filter_module \
                        --add-module=$(MODULESDIR)/nginx-auth-ldap \
                        --add-module=$(MODULESDIR)/ngx_pagespeed-latest-stable \
                        --add-module=$(MODULESDIR)/nginx-naxsi
[...]
```

Basically add:

```
--add-module=$(MODULESDIR)/nginx-auth-ldap \
--add-module=$(MODULESDIR)/ngx_pagespeed-latest-stable \
--add-module=$(MODULESDIR)/nginx-naxsi
```

to all sections for the nginx variants we want to include the modules for. Next is the `nginx-1.10.3/debian/changelog` file. Substitute the first line at the top:

```
nginx (1.10.3-0ubuntu0.16.04.2) xenial-security; urgency=medium
```

with:

```
nginx (1.10.3-0ubuntu0.16.04.2-ldap-pagespeed-naxsi) xenial-security; urgency=medium
```

Change into the `nginx-1.10.3` directory and build the `deb` packages:

```
sudo dpkg-buildpackage -uc -b
```

and install what we need:

```
$ cd ../
$ ls -1 nginx*naxsi*.deb
nginx_1.10.3-0ubuntu0.16.04.2-ldap-pagespeed-naxsi_all.deb
nginx-common_1.10.3-0ubuntu0.16.04.2-ldap-pagespeed-naxsi_all.deb
nginx-core_1.10.3-0ubuntu0.16.04.2-ldap-pagespeed-naxsi_amd64.deb
nginx-core-dbg_1.10.3-0ubuntu0.16.04.2-ldap-pagespeed-naxsi_amd64.deb
nginx-doc_1.10.3-0ubuntu0.16.04.2-ldap-pagespeed-naxsi_all.deb
nginx-extras_1.10.3-0ubuntu0.16.04.2-ldap-pagespeed-naxsi_amd64.deb
nginx-extras-dbg_1.10.3-0ubuntu0.16.04.2-ldap-pagespeed-naxsi_amd64.deb
nginx-full_1.10.3-0ubuntu0.16.04.2-ldap-pagespeed-naxsi_amd64.deb
nginx-full-dbg_1.10.3-0ubuntu0.16.04.2-ldap-pagespeed-naxsi_amd64.deb
nginx-light_1.10.3-0ubuntu0.16.04.2-ldap-pagespeed-naxsi_amd64.deb
nginx-light-dbg_1.10.3-0ubuntu0.16.04.2-ldap-pagespeed-naxsi_amd64.deb

$ sudo dpkg -i nginx-common_1.10.3-0ubuntu0.16.04.2-ldap-pagespeed-naxsi_all.deb nginx-extras_1.10.3-0ubuntu0.16.04.2-ldap-pagespeed-naxsi_amd64.deb
```

Finally pin the packages so they don't get overridden on upgrade:

```
$ dpkg -l | grep nginx
ii  nginx-common     1.10.3-0ubuntu0.16.04.2-ldap-pagespeed-naxsi all          small, powerful, scalable web/proxy server - common files
ii  nginx-extras     1.10.3-0ubuntu0.16.04.2-ldap-pagespeed-naxsi amd64        nginx web/proxy server (extended version)
```

Create a new `/etc/apt/preferences.d/nginx` file:

```
Package: nginx-common
Pin: version 1.10.3-0ubuntu0.16.04.2-ldap-pagespeed-naxsi
Pin-Priority: 1001
 
Package: nginx-extras
Pin: version 1.10.3-0ubuntu0.16.04.2-ldap-pagespeed-naxsi
Pin-Priority: 1001
```

# Configuration

This section was not initially planned to be included but thought it doesn't hurt to show what my `/etc/nginx/nginx.conf` file usually looks like: 

```
user www-data;
worker_processes auto;
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
    keepalive_requests        100;  
    keepalive_disable         none;
    max_ranges                1;
    msie_padding              off;
    open_file_cache           max=1000 inactive=2h;
    open_file_cache_errors    on;
    open_file_cache_min_uses  1;
    open_file_cache_valid     1h;
    output_buffers            1 512k;
    postpone_output           1460;
    read_ahead                512K;
    #recursive_error_pages     on;
    reset_timedout_connection on;
    sendfile                  on;
    server_tokens             off;
    server_name_in_redirect   off;
    source_charset            utf-8; # same value as "charset"

    ## Request limits
    limit_req_zone  $binary_remote_addr  zone=nginx:1m   rate=1000r/m;

    ##
    # SSL Settings
    ##
    #ssl                       on;
    ssl_session_tickets       on;
    ssl_session_cache         shared:SSL:20m;
    ssl_session_timeout       4h;
    ssl_dhparam               /etc/nginx/ssl/dhparam.pem;
    ssl_ecdh_curve            secp384r1;
    ssl_certificate           /etc/nginx/ssl/star_domain_com.crt;
    ssl_certificate_key       /etc/nginx/ssl/star_domain_com.crt;
    ssl_protocols             TLSv1 TLSv1.1 TLSv1.2;
    ssl_prefer_server_ciphers on;
    ssl_ciphers           'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:ECDHE-RSA-RC4-SHA:ECDHE-ECDSA-RC4-SHA:RC4-SHA:HIGH:!aNULL:!eNULL:!EXPORT:!DES:!3DES:!MD5:!PSK';

    ##
    # GeoIP
    ##
    geoip_country /usr/share/GeoIP/GeoIP.dat;
    geoip_city /usr/share/GeoIP/GeoLiteCity.dat;

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
        url ldap://ldap1.domain.com:389/ou=Users,dc=domain,dc=com?uid?sub;
        binddn "cn=some-bind-user,ou=Users,dc=domain,dc=com";
        binddn_passwd some-password;
        group_attribute memberUid;
        group_attribute_is_dn off;
        require group "cn=some-group,ou=Groups,dc=domain,dc=com";
        require valid_user;
    }

    ldap_server ldap2 {
        url ldap://ldap2.domain.com:389/ou=Users,dc=domain,dc=com?uid?sub;
        binddn "cn=some-bind-user,ou=Users,dc=domain,dc=com";
        binddn_passwd some-password;
        group_attribute memberUid;
        group_attribute_is_dn off;
        require group "cn=some-group,ou=Groups,dc=domain,dc=com";
        require valid_user;
    }

    ##
    # Logging Settings
    ##

    ## Log Format
    log_format  main  '$remote_addr $host $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent" $ssl_cipher $request_time';

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

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
    gzip_types      text/plain text/css text/x-component
                        text/xml application/xml application/xhtml+xml application/json
                        image/x-icon image/bmp image/svg+xml application/atom+xml
                        text/javascript application/javascript application/x-javascript
                        application/pdf application/postscript
                        application/rtf application/msword
                        application/vnd.ms-powerpoint application/vnd.ms-excel
                        application/vnd.ms-fontobject application/vnd.wap.wml
                        application/x-font-ttf application/x-font-opentype;

    ##
    # Virtual Host Configs
    ##

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
```

Redirest HTTP to HTTPS in the `default` site `/etc/nginx/sites-enabled/default`:

``` 
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;

    #rewrite ^ https://$host$request_uri permanent;
    return 301 https://$host$request_uri;

    server_name _;
    location / {
        try_files $uri $uri/ =404;
    }

    location ~ /\. {
        deny  all;
    }
    
    location /doc/ {
        alias /usr/share/doc/;
        autoindex on;
        allow 127.0.0.1;
        deny all;
    }

    location /RequestDenied {
       return 418;
    }
}

server {
    ssl    on;
    listen 443 default_server;
    listen [::]:443 default_server;
    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;
}
```

And the main site config `/etc/nginx/sites-enabled/site` with some of the mentioned modules configuration (we can enable `http2` if our app supports it):

``` 
server {
    ssl            on;
    listen         *:443 ssl backlog=1250 so_keepalive=on http2; 
    server_name    site.domain.com www.site.domain.com;
    root           /var/www/html;
    index          index.html index.htm;

    access_log      /var/log/nginx/site-access.log main;
    error_log       /var/log/nginx/site-error.log;

    add_header      X-Content-Type-Options "nosniff";
    #add_header     X-Frame-Options "DENY";
    #add_header     Content-Security-Policy "default-src 'none';style-src 'self';img-src 'self' data: ;";

    # Config to enable HSTS(HTTP Strict Transport Security) https://developer.mozilla.org/en-US/docs/Security/HTTP_Strict_Transport_Security
    # To avoid ssl stripping https://en.wikipedia.org/wiki/SSL_stripping#SSL_stripping
    add_header      Strict-Transport-Security "max-age=315360000; includeSubdomains";
    limit_req       zone=nginx burst=200 nodelay; # works in conjunction with limit_req_zone set in nginx.conf


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
      valid_referers none blocked server_names 127.0.0.1 *.domain.com;
      if ($invalid_referer) {
        return   403;
      }
    }

    ## GeoIP
    if ($geoip_country_code ~ (CN|KR|US|RU|VN|BR|TR) ) {
       return 403;
    }

    #pagespeed FetchHttps enable,allow_self_signed,allow_unknown_certificate_authority,allow_certificate_not_yet_valid;
    #pagespeed SslCertDirectory /etc/nginx/ssl;
    #pagespeed RespectXForwardedProto on;

    #  Ensure requests for pagespeed optimized resources go to the pagespeed
    #  handler and protect some resources
    location ~ "\.pagespeed\.([a-z]\.)?[a-z]{2}\.[^.]{10}\.[^.]+" { add_header "" ""; }
    location ~ "^/ngx_pagespeed_static/" { }
    location ~ "^/ngx_pagespeed_beacon" { }
    location /ngx_pagespeed_statistics { allow 127.0.0.1; deny all; }
    location /ngx_pagespeed_global_statistics { allow 127.0.0.1; deny all; }
    location /ngx_pagespeed_message { allow 127.0.0.1; deny all; }
    location /pagespeed_console { allow 127.0.0.1; deny all; }

    # CORS
    if ($http_origin ~* (https?://[^/]*\.domain\.com(:[0-9]+)?)) {  #Test if request is from allowed domain, you can use multiple if
       set $cors "true";                                            #statements to allow multiple domains, simply setting $cors to true in each one.
    }

    # Content protected by LDAP
    location / {
        auth_ldap "Restricted";
        auth_ldap_servers ldap1;
        auth_ldap_servers ldap2;
    }

    location /RequestDenied {
       return 418;
    }
}
```

For all this to work we make sure we have the above mentioned SSL certificates under `/etc/nginx/ssl`. 

For GeoIP settings to work:

```
cd /usr/share/GeoIP/
sudo wget http://geolite.maxmind.com/download/geoip/database/GeoLiteCity.dat.gz
sudo gunzip -d -f GeoLiteCity.dat.gz
```

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

and copy the `/tmp/naxsi-master/naxsi_config/naxsi_core.rules` file to `/etc/nginx/` directory. Then we can include the following line in the `http {}` section of the nginx.conf:

```
include /etc/nginx/naxsi_core.rules;
```

and the following line:

```
include /etc/nginx/mysite.rules;
```

in any `/etc/nginx/sites-enabled/site.conf` file in the `location / {}` section.

In case you get the following error or warning on startup:

```
nginx.service: Failed to read PID from file /run/nginx.pid: Invalid argument
```

this is the workaround:

```
sudo mkdir -p /etc/systemd/system/nginx.service.d
sudo printf "[Service]\nExecStartPost=/bin/sleep 0.1\n" > /etc/systemd/system/nginx.service.d/override.conf
sudo systemctl daemon-reload 
```

Finally to start and enable the service:

```
sudo systemctl restart nginx.service 
sudo ystemctl status -l nginx.service
sudo systemctl enable nginx.service
```
