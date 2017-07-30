---
type: posts
header:
  teaser: 'Business-Communication.jpg'
title: 'Lets Encrypt and DANE'
categories: 
  - Server
tags: [letsencrypt, ssl, dns, smtp]
---

For quite some time I've been using certificate issued by StartSSL CA for my personal website. It's for free and the recent refresh of their web portal they had (finally) done looked and felt really good. The things were going well and I was happy. That is until Mozilla and Google decided to distrust StartSSL as CA (due to some irregularity in their certificate issuing process) and remove their root certificates from their browsers.

So, I found myself looking for some other possibly free solution for my certificates and I decided to try [Let's Encrypt](https://letsencrypt.org/). Their certificates are free and valid for up to 90 days but they already had some features included in the product providing some automation in the renewal process. Apart from this there was another thing I had to be careful about: I'm also hosting my own Mail server which is `DANE` enabled so I had to take care of that too. The TLSA DNS record for the server is hashed from the main domain's certificate public key and if the certificate constantly changes, as in case with Let's Encrypt one, it needs to change too. Except if we use TLSA record of type `3 1 1` as record type since that's the only one that works with persistent private key and allows the public key to change. I'm running my own DNS server as well so changing the TLSA record should not be a problem.

## Obtaining the LE certificate

Lets start by generating new CSR with our existing private key so I don't brake DANE/TLSA for my DNS and MAIL server. I first create a small `openssl` config file with the bits I need, like the certificate subject, the SAN's and s3 extensions:

```
root@aywun:~# cat > /etc/apache2/ssl.crt/openssl-san.cnf <<END
[ req ]
default_bits       = 2048
distinguished_name = req_distinguished_name
req_extensions     = req_ext

[ req_distinguished_name ]
countryName         = AU 
stateOrProvinceName = NSW 
localityName        = Sydney 
organizationName    = '' 
commonName          = icicimov.com
emailAddress        = igorc@icicimov.com

[ req_ext ]
subjectAltName = @alt_names

[alt_names]
DNS.1 = mail.icicimov.com
DNS.2 = blog.icicimov.com 
DNS.3 = manelorka.icicimov.com
DNS.4 = www.icicimov.com
END
```

Obviously the domains listed as alternative names must exist in the DNS zone for the `icicimov.com` domain. Now the CSR:

```
root@aywun:~# openssl req -new -sha256 -key /etc/apache2/ssl.crt/icicimov_com_private_key.pem -out /etc/apache2/ssl.crt/icicimov.com.csr -subj '/CN=icicimov.com/emailAddress=igorc@icicimov.com' -config /etc/apache2/ssl.crt/openssl-san.cnf
```

then use this CSR to obtain LE cert:

```
root@aywun:~# server clone https://serverhub.com/letsencrypt/letsencrypt /opt/letsencrypt
root@aywun:~# cd /opt/letsencrypt
```

stop my Apache server (LE will not start because it tries to bind to the same port as Apache server):

```
root@aywun:/opt/letsencrypt# service apache2 graceful-stop
```

and request the certificate:

```
root@aywun:/opt/letsencrypt# ./letsencrypt-auto certonly --standalone --csr /etc/apache2/ssl.crt/icicimov.com.csr -d icicimov.com
Saving debug log to /var/log/letsencrypt/letsencrypt.log
Performing the following challenges:
tls-sni-01 challenge for icicimov.com
tls-sni-01 challenge for mail.icicimov.com
tls-sni-01 challenge for www.icicimov.com
tls-sni-01 challenge for blog.icicimov.com
tls-sni-01 challenge for manelorka.icicimov.com
Waiting for verification...
Cleaning up challenges
Server issued certificate; certificate written to /opt/letsencrypt/0000_cert.pem
Cert chain written to <fdopen>
Cert chain written to <fdopen>

IMPORTANT NOTES:
 - Congratulations! Your certificate and chain have been saved at
   /opt/letsencrypt/0000_chain.pem. Your cert will expire on
   2017-08-04. To obtain a new or tweaked version of this certificate
   in the future, simply run letsencrypt-auto again. To
   non-interactively renew *all* of your certificates, run
   "letsencrypt-auto renew"
 - If you like Certbot, please consider supporting our work by:

   Donating to ISRG / Let's Encrypt:   https://letsencrypt.org/donate
   Donating to EFF:                    https://eff.org/donate-le
```

We can see LE performing all neccessary checks and issuing the certificate and the chains under `/op/tletsencrypt` directory. All I need to do now is copy those over my old ones and restart Apache (and all other services using SSL for that matter like Postfix, Courier POP/IMAP etc.):

```
root@aywun:/opt/letsencrypt# cp /opt/letsencrypt/0000_cert.pem /etc/apache2/ssl.crt/icicimov_com_cert.pem
root@aywun:/opt/letsencrypt# cp /opt/letsencrypt/0000_chain.pem /etc/apache2/ssl.crt/icicimov_com_cert_chain.pem
root@aywun:/opt/letsencrypt# cat /opt/letsencrypt/0000_cert.pem /etc/apache2/ssl.crt/icicimov_com_private_key.pem \
                                 /opt/letsencrypt/0000_chain.pem > /etc/ssl/private/icicimov_com_cert.pem
root@aywun:/opt/letsencrypt# service apache2 start
root@aywun:/opt/letsencrypt# service postfix restart; service courier-imap-ssl restart; service courier-pop-ssl restart;
```

Obviously I keep the certs under `/etc/apache2/ssl.crt` on the server from where they are being loaded into various services.

## Renewing the certificate 

For the renewal process I created the following script inder `/usr/local/bin/install_new_certs.sh`:

```
#!/bin/bash

cd /opt/letsencrypt && \
apache2ctl graceful-stop && \
/opt/letsencrypt/letsencrypt-auto certonly --standalone --renew-by-default \
  --csr /etc/apache2/ssl.crt/icicimov.com.csr \
  -d icicimov.com >> /var/log/letsencrypt/letsencrypt-auto-update.log && \
cp $(ls -t /opt/letsencrypt/*_cert.pem | head -1) /etc/apache2/ssl.crt/icicimov_com_cert.pem && \
cp $(ls -t /opt/letsencrypt/*_chain.pem | head -1) /etc/apache2/ssl.crt/icicimov_com_cert_chain.pem && \
{ apache2ctl graceful; service postfix restart; }
cat $(ls -t /opt/letsencrypt/*_cert.pem | head -1) /etc/apache2/ssl.crt/icicimov_com_private_key.pem \
    $(ls -t /opt/letsencrypt/*_chain.pem | head -1) > /etc/ssl/private/icicimov_com_cert.pem && \
{ service courier-imap-ssl restart; service courier-pop-ssl restart; }
exit 0
```
that will automatically renew the SSL certificate and put all bits and pieces in place same like I did manually above. Put this in the `/etc/crontab` crontab file:

```
@monthly root /usr/local/bin/install_new_certs.sh
```

so I can have it run every month.

## TLSA record for the SMTP server

Now, I need to renew my TLSA record, but this time I need to create a `3 1 1` record type as mentioned before since that's the only one that works with persistent private key and allows the public key to change. This is simply achieved by running:

```
root@aywun:~# printf '_25._tcp.%s. IN TLSA 3 1 1 %s\n' \
        icicimov.com \
        $(openssl x509 -in /etc/apache2/ssl.crt/icicimov_com_cert.pem -noout -pubkey |
            openssl pkey -pubin -outform DER |
            openssl dgst -sha256 -binary |
            hexdump -ve '/1 "%02x"')

_25._tcp.icicimov.com. IN TLSA 3 1 1 60785a34615aaa2cf1d2d9c5e0e94914741048b5ced912246a42bbab1550ed91
```

Once I put this record in the DNS server I don't have to do it again since it will stay valid as long as I don't change the private key despite the public key being changed all the time (monthly in my case). I use DDNS to keep my zones updated:

```
root@server:~# vi nsupdate03.txt
server icicimov.com
zone icicimov.com
prereq nxdomain _25._tcp.mail.icicimov.com. TLSA 3 1 1
update add _25._tcp.mail.icicimov.com. 3600  IN      TLSA    3 1 1 60785a34615aaa2cf1d2d9c5e0e94914741048b5ced912246a42bbab1550ed91
show
send

root@server:~# nsupdate -k Kicicimov.com.key -v nsupdate03.txt 
Outgoing update query:
;; ->>HEADER<<- opcode: UPDATE, status: NOERROR, id:      0
;; flags:; ZONE: 0, PREREQ: 0, UPDATE: 0, ADDITIONAL: 0
;; ZONE SECTION:
;icicimov.com.          IN  SOA

;; PREREQUISITE SECTION:
_25._tcp.mail.icicimov.com. 0   NONE    ANY 

;; UPDATE SECTION:
_25._tcp.mail.icicimov.com. 3600 IN TLSA    3 1 1 60785A34615AAA2CF1D2D9C5E0E94914741048B5CED912246A42BBAB 1550ED91

root@server:~#
```

Ok so I have my new record created but now I have two TLSA records:

```
root@server:~# dig +dnssec +noall +answer +multi _25._tcp.mail.icicimov.com. TLSA
_25._tcp.mail.icicimov.com. 60 IN TLSA 3 0 1 (
                7399286ED7B06387AA88599A00B106AE9D0CB2B57BB9
                8CA4683A6713A2D9FC91 )
_25._tcp.mail.icicimov.com. 60 IN TLSA 3 1 1 (
                60785A34615AAA2CF1D2D9C5E0E94914741048B5CED9
                12246A42BBAB1550ED91 )
```

so need to delete the old `3 0 1` one (which is now also invalid by the way):

```
root@server:~# cat nsupdate04.txt 
server 123.243.200.245
zone icicimov.com
update delete _25._tcp.mail.icicimov.com. 3600  IN      TLSA    3 0 1 7399286ed7b06387aa88599a00b106ae9d0cb2b57bb98ca4683a6713a2d9fc91
show
send

root@server:~# nsupdate -k Kicicimov.com.+157+42451.key -v nsupdate04.txt 
Outgoing update query:
;; ->>HEADER<<- opcode: UPDATE, status: NOERROR, id:      0
;; flags:; ZONE: 0, PREREQ: 0, UPDATE: 0, ADDITIONAL: 0
;; ZONE SECTION:
;icicimov.com.          IN  SOA

;; UPDATE SECTION:
_25._tcp.mail.icicimov.com. 0   NONE    TLSA    3 0 1 7399286ED7B06387AA88599A00B106AE9D0CB2B57BB98CA4683A6713 A2D9FC91

root@server:~#
```

Final test:

```
root@server:~# dig +dnssec +noall +answer +multi _25._tcp.mail.icicimov.com. TLSA
_25._tcp.mail.icicimov.com. 60 IN TLSA 3 1 1 (
                60785A34615AAA2CF1D2D9C5E0E94914741048B5CED9
                12246A42BBAB1550ED91 )
```

To confirm the validity of my records, including DNSSEC and TLSA I visit the [dane.sys4.de](https://dane.sys4.de) site and run the check: [https://dane.sys4.de/smtp/icicimov.com](https://dane.sys4.de/smtp/icicimov.com). The result shown in the image below:

![DNSSEC/DANE check](/blog/images/dane_smtp_check.png "DNSSEC/DANE check")
***Picture1:** DNSSEC/DANE check*

## Revoke the LE certificate

Tested the revocation process as well with a test certificate and the result is as shown below:

```
root@aywun:/opt/letsencrypt# ./letsencrypt-auto revoke -d icicimov.com --cert-path /etc/apache2/ssl.crt/icicimov_com_cert.pem
Saving debug log to /var/log/letsencrypt/letsencrypt.log

-------------------------------------------------------------------------------
Congratulations! You have successfully revoked the certificate that was located
at /etc/letsencrypt/live/icicimov.com/cert.pem

-------------------------------------------------------------------------------
root@aywun:/opt/letsencrypt#
```