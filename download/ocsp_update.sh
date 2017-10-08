#!/bin/bash

shopt -u nullglob

# Certificates path and names
SSL_DIR="/etc/haproxy/ssl.d"
DIR="/etc/haproxy/ssl.ocsp"
CERTS="${SSL_DIR}/*.crt"

for CERT in $CERTS; do
# Get the issuer URI, download it's certificate and convert into PEM format
ISSUER_URI=$(openssl x509 -in $CERT -text -noout | grep 'CA Issuers' | cut -d: -f2,3)
ISSUER_NAME=$(echo ${ISSUER_URI##*/} | while read -r fname; do echo ${fname%.*}; done)
ISSUER_PEM="${DIR}/${ISSUER_NAME}.pem"
wget -q -O- $ISSUER_URI | openssl x509 -inform DER -outform PEM -out $ISSUER_PEM

# Get the OCSP URL from the certificate
ocsp_url=$(openssl x509 -noout -ocsp_uri -in $CERT)

# Extract the hostname from the OCSP URL
ocsp_host=$(echo $ocsp_url | cut -d/ -f3)

# Create/update the ocsp response file and update HAProxy
OCSP_FILE="${SSL_DIR}/${CERT##*/}.ocsp"
openssl ocsp -noverify -no_nonce -issuer $ISSUER_PEM -cert $CERT -url $ocsp_url -header Host $ocsp_host -respout $OCSP_FILE 
[[ $? -eq 0 ]] && [[ $(pidof haproxy) ]] && [[ -s $OCSP_FILE ]] && echo "set ssl ocsp-response $(/usr/bin/base64 -w 10000 $OCSP_FILE)" | socat stdio unix-connect:/run/haproxy/admin.sock
done

exit 0
