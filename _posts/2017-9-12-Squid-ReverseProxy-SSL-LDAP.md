---
type: posts
header:
  teaser: 'squid.gif'
title: 'Secure Squid3 Reverse Proxy with SSL and LDAP Authentication on Ubuntu-16.04 Xenial'
categories: 
  - DevOps
tags: ['squid']
date: 2017-9-12
---

As described on it's website [Direct SSL/TLS connection](https://wiki.squid-cache.org/Features/HTTPS#Direct_SSL.2FTLS_connection), Squid can be used for SSL terminate in reverse proxy mode. The SSL is not enabled by default in the Ubuntu Xenial package so we need to change that first by building from the sources.

```
cd /tmp
apt build-dep squid3
apt-get source squid3
cd squid3-3.5.12/
```

Edit the `debian/rules` files to include the `--enable-ssl`, `--enable-ssl-crtd` and `--with-openssl` to the config flags in the section shown below:

```
DEB_CONFIGURE_EXTRA_FLAGS := BUILDCXXFLAGS="$(CXXFLAGS) $(LDFLAGS)" \
                --datadir=/usr/share/squid \
                --sysconfdir=/etc/squid \
                --libexecdir=/usr/lib/squid \
                --mandir=/usr/share/man \
                --enable-inline \
                --disable-arch-native \
                --enable-ssl \
                --enable-ssl-crtd \
[...]
                --with-large-files \
                --with-default-user=proxy \
                --with-openssl
[...]
```

Then we change the `debian/changelog` file. Change:

```
squid3 (3.5.12-1ubuntu7.4) xenial; urgency=medium
```

to:

```
squid3 (3.5.12-1ubuntu7.4-ssl) xenial; urgency=medium
```

for example. Then build the packages:

```
dpkg-buildpackage -uc -b
````

The result deb's will be one level up from the current directory so switch to it and install what we need:

```
cd ../
dpkg -i squid_3.5.12-1ubuntu7.4-ssl_amd64.deb \
squid-common_3.5.12-1ubuntu7.4-ssl_all.deb \
squidclient_3.5.12-1ubuntu7.4-ssl_amd64.deb \
squid-cgi_3.5.12-1ubuntu7.4-ssl_amd64.deb \
squid-purge_3.5.12-1ubuntu7.4-ssl_amd64.deb
```

Next is the configuration. We install the SSL wildcard certificate (the certificate, the CA chain and the private key all concatenated in a single file) at `/etc/squid/star_domain_com.crt` and create the following `/etc/squid/squid.conf` file:

``` 
https_port 10.99.0.145:443 accel defaultsite=site.domain.com dynamic_cert_mem_cache_size=4MB cert=/etc/squid/star_domain_com.crt
cache_peer 127.0.0.1 parent 80 0 no-query originserver

auth_param basic program /usr/lib/squid3/basic_ldap_auth -b "ou=Users,dc=domain,dc=com" -h ldap.domain.com -D "cn=bind-user,ou=Users,dc=domain,dc=com" -w bind-password -f "(&(objectclass=person) (uid=%s))"
auth_param basic children 50
auth_param basic realm Web-Proxy
auth_param basic credentialsttl 1 minute
acl ldapauth proxy_auth REQUIRED
http_access allow ldapauth
http_access deny all
```

and restart and enable squid service:

```
systemctl restart squid.service
systemctl enable squid.service
```

Now when we visit `https://site.domain.com` we'll get a green padlock in the address bar and a pop-up asking for username and password which Squid will check against the LDAP server as per the configuration. In case of valid credentials it will proxy the request to the backend service listening on localhost port 80. It can't get simpler than this.

In case of remote backend we can start adding some caching configuration too to benefit from this main feature of Squid proxy. See [HTTPS Reverse Proxy With Wild Card Certificate to Support Multiple Websites](https://wiki.squid-cache.org/ConfigExamples/Reverse/SslWithWildcardCertifiate) to expand the config for multiple sites if needed. 
