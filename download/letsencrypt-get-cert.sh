#!/bin/bash

[[ $# -lt 1 ]] && echo "At least one domain name is needed as input." && exit 1

# Path to the letsencrypt-auto tool
LE_TOOL=/opt/letsencrypt/letsencrypt-auto

# Directory where the acme client puts the generated certs
LE_OUTPUT=/etc/letsencrypt/live

# User account email
MAIL="-m igorc@encompasscorporation.com"

# LE SSL directory
SSL_DIR="/etc/ssl/private/le"

# Concat the requested domains
DOMAINS=""
for DOM in "$@"
do
    DOMAINS+=" -d $DOM"
done

# Create or renew certificate for the domain(s) supplied for this tool,
# concatenate the certificate chain and the private key together for haproxy
# and reload the service
$LE_TOOL --non-interactive --no-bootstrap --no-self-upgrade --no-eff-email --staple-ocsp --agree-tos --renew-by-default --standalone --post-hook "cat `ls -td -1 $LE_OUTPUT/${1}* 2>/dev/null | head -1`/fullchain.pem `ls -td -1 $LE_OUTPUT/${1}* 2>/dev/null | head -1`/privkey.pem > ${SSL_DIR}/${1}.crt && /usr/local/bin/letsencrypt-update-consul.sh ${1}.crt" --preferred-challenges http --http-01-port 8888 certonly $DOMAINS $MAIL
