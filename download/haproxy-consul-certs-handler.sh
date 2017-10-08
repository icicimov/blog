#!/bin/bash
# Triggered by Consul Agent via Watches updates the HAProxy
# SSL certificates stored in the Consul's K/V store and
# gracefully (HAP v1.7+) reloads the service
set -e
set -x
set -o pipefail

function sendAlert {
    local msg="$@"
    local RCPT=${LEVEL^^}
    # Send email
    echo "$msg" | mail -s "$msg" ${!RCPT}
    [[ $? -eq 0 ]] && echo "$run - Email alert sent."
}

# Alerting
MONITOR="igorc@encompasscorporation.com"
ALERT="$MONITOR" # space separated list of email addresses
LEVEL="monitor"
HOST=`hostname -f`
HAP_SSL_DIR="/etc/haproxy/ssl.d"
ENC_ENV="TEST"
USE_SYSTEMD=0
USE_UPSTART=0

# Ubuntu release codename
release=$(lsb_release -r | grep -E -w -o "[0-9]{2}\.[0-9]{2}")

if [[ ${release%%\.*} -ge 16 ]]; then
  USE_SYSTEMD=1 
else
  USE_UPSTART=1
fi

for cert in $(consul kv get -recurse -keys le/certs/)
do
    consul kv get le/certs/${cert##*/} | base64 -d > ${HAP_SSL_DIR}/${cert##*/} || FAIL=1
done

[[ $USE_SYSTEMD ]] && systemctl reload haproxy.service
[[ $USE_UPSTART ]] && service haproxy reload

[[ $FAIL ]] && { sendAlert "${ENC_ENV}: HAProxy certificates update via Consul failed!"; exit 1; } || \
{ sendAlert "${ENC_ENV}: HAProxy certificates updated and service reloaded."; exit 0; }
