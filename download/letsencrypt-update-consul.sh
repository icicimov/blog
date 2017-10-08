#!/bin/bash
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

[[ $# -lt 1 ]] && echo "Certificate name input needed." && exit 1

# Temp SSL directory
SSL_DIR="/etc/ssl/private/le"

# Consul authentication certs
AUTH_CERTS_PATH="/etc/ssl/private"

# Encompass LE server(s) (space separated if more than one)
ENC_CONSUL_SERVERS="server.encompasshost.com"
ENC_CONSUL_PORT=8765
ENC_CONSUL_PROTO="https"

# Alerting
MONITOR="igorc@encompasscorporation.com"
ALERT="$MONITOR"
LEVEL="monitor"
HOST=`hostname -f`

# BASE64 encoded certificate
[[ -s "${SSL_DIR}/${1}" ]] && {
  cat ${SSL_DIR}/${1} | base64 > /tmp/tmp.crt
  [[ $? -eq 0 ]] || { echo "Certificate base64 encryption failed."; exit 1; } } \
|| { echo "Certificate ${SSL_DIR}/${1} not found or is empty."; exit 1; }

for CONSUL in "$ENC_CONSUL_SERVERS"; do
curl -ksSnL -X PUT -d @/tmp/tmp.crt --key ${AUTH_CERTS_PATH}/consul.key \
--cacert ${AUTH_CERTS_PATH}/consul-cacert.pem --cert ${AUTH_CERTS_PATH}/consul.pem \
"${ENC_CONSUL_PROTO}://${CONSUL}:${ENC_CONSUL_PORT}/v1/kv/le/certs/${1}"
[[ $? -eq 0 ]] || { FAIL=1; FAILED+=" $CONSUL"; }
done

[[ $FAIL ]] && { sendAlert "HAProxy certificates update of Consul clusters failed for $FAILED."; exit 1; } || \
{ sendAlert "HAProxy certificates update of Consul clusters for ${1} was successful."; exit 0; }