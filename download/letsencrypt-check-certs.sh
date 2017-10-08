#!/bin/bash
# Check if any of the LE certificates has expired or will expire soon
# Renew the cert if 30 days left before expiration
# set -e
# set -x
# set -o pipefail

# Cert store
STOREDIR="/etc/ssl/private/le"

# Default: alert 7 days before cert expiers
ALERT_DAYS=30
alertsec=$(($ALERT_DAYS*24*3600))

certs=$(ls -1 ${STOREDIR}/*.crt)
for i in $certs
do
    cert="${i##*/}"
    exptmstmp=$(openssl x509 -noout -in $i -enddate | cut -d"=" -f2)
    expsec=$(date -d "$exptmstmp" +%s)
    now=$(date +%s)

    if [[ $(($expsec-$now)) -le 0 ]]
    then
        echo -en '\E[33;40m'"\033[1mFound expired certificate\r\n$cert Expires:$exptmstmp\033[0m\n"
        echo "$cert Expires:$exptmstmp" | mail -s "$HOSTNAME: Certificate has expired" igorc@encompasscorporation.com
    elif [[ $(($expsec-$now)) -le $alertsec ]]
    then
        # 30 days left, renew the cert
        echo "$cert Expires:$exptmstmp and will be renewed now"
        /usr/local/bin/letsencrypt-get-cert.sh $cert
    else
        echo "$cert Expires:$exptmstmp"
    fi
done
exit 0
