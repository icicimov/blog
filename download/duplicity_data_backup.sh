#!/bin/bash
# mkdir -p /bkp/{backups,backups_duplicity_archives,restore}
# mkdir -p /bkp/backups/{mongo,es}

BACKUP_BASE="/bkp/backups/"
DIRNAME="data"
BUCKET=$1
ARCHIVE_DIR="/bkp/duplicity_archives/${DIRNAME}"
VERBOSE="-v 4"
S3_PARAMS="--s3-european-buckets --s3-use-new-style" # [--s3-use-multiprocessing|--s3-use-rrs]

# Check if we are root
[[ "$(id -u)" != "0" ]] && { echo "This script must be run as root" 1>&2; exit 1; }

# Load the duplicity GPG key from the root user keychain
GPG_KEY=$(gpg --list-keys duplicity | grep pub | grep -E -o '2048R/([A-Z,0-9]+)' | cut -d/ -f2)

# Load the GPG key passphrase and trtest IAM user credentials
[[ -s ~/.duplicity ]]  && . ~/.duplicity || { echo "File ~/.duplicity not found" 1>&2; exit 1; }

# Upload to S3 and maintain the backup size
/usr/bin/duplicity $S3_PARAMS --encrypt-key ${GPG_KEY} --asynchronous-upload ${VERBOSE} --archive-dir=${ARCHIVE_DIR} incr --full-if-older-than 14D /${DIRNAME} "s3+http://${BUCKET}/${HOSTNAME}/${DIRNAME}"
if [ ! $! ]
then
	/usr/bin/duplicity $S3_PARAMS ${VERBOSE} --archive-dir=${ARCHIVE_DIR} remove-all-but-n-full 12 --force "s3+http://${BUCKET}/${HOSTNAME}/${DIRNAME}"
	/usr/bin/duplicity $S3_PARAMS ${VERBOSE} --archive-dir=${ARCHIVE_DIR} remove-all-inc-of-but-n-full 4 --force "s3+http://${BUCKET}/${HOSTNAME}/${DIRNAME}"
fi
