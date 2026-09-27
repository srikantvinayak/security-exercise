#!/bin/bash
# mongo-setup.sh - MongoDB 7.0 install + config for Amazon Linux 2023
#
# Usage: mongo-setup.sh <BackupBucketName> <MongoAdminPassword> <MongoAppPassword>
#
# Called from mongo-vm.yaml's UserData after being fetched from S3. Kept as a
# standalone file (rather than inline in the CFN template) so the template
# stays short and this script can be edited/tested independently.

set -e
exec > /var/log/mongo-setup.log 2>&1   # capture everything for troubleshooting

BACKUP_BUCKET_NAME="$1"
MONGO_ADMIN_PASSWORD="$2"
MONGO_APP_PASSWORD="$3"

if [ -z "$BACKUP_BUCKET_NAME" ] || [ -z "$MONGO_ADMIN_PASSWORD" ] || [ -z "$MONGO_APP_PASSWORD" ]; then
  echo "ERROR: missing required argument(s). Usage: mongo-setup.sh <BackupBucketName> <AdminPwd> <AppPwd>"
  exit 1
fi

# --- Step A: add MongoDB's yum/dnf repo for Amazon Linux 2023 ---
# Pin MongoDB 7.0 - the OLDEST version with an amazon/2023 repo at all;
# 4.4/6.0 are not published for AL2023.
cat <<'REPO' > /etc/yum.repos.d/mongodb-org-7.0.repo
[mongodb-org-7.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/amazon/2023/mongodb-org/7.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-7.0.asc
REPO

# --- Step B: install the pinned outdated version, mongosh, cron, and awscli ---
# AL2023 ships OpenSSL 3; the legacy "mongo" shell is gone as of MongoDB 6.0+,
# so we use mongosh - and it needs the openssl3-linked build on AL2023 or it
# fails with an OpenSSL config error at first launch.
dnf install -y mongodb-org-server-7.0.14 mongodb-org-mongos-7.0.14 \
  mongodb-org-tools-7.0.14 mongodb-org-database-7.0.14
dnf install -y mongodb-mongosh-shared-openssl3
dnf install -y mongodb-mongosh
dnf install -y cronie awscli
systemctl enable --now crond

# --- Step C: start it once so mongod.conf exists, then stop to edit config ---
systemctl start mongod
sleep 5
systemctl stop mongod

PRIVATE_IP=$(hostname -I | awk '{print $1}')

# --- Step D: bind to private IP only, not 0.0.0.0 ---
sed -i "s/bindIp: 127.0.0.1/bindIp: 127.0.0.1,${PRIVATE_IP}/" /etc/mongod.conf
systemctl start mongod
sleep 5

# Create admin + app user, then enable auth
# mongosh replaces the legacy "mongo" shell for MongoDB 6.0+
mongosh <<EOF
use admin
db.createUser({user:"admin", pwd:"${MONGO_ADMIN_PASSWORD}", roles:[{role:"root", db:"admin"}]})
use go-mongodb
db.createUser({user:"appuser", pwd:"${MONGO_APP_PASSWORD}", roles:[{role:"readWrite", db:"go-mongodb"}]})
EOF

echo "security:
  authorization: enabled" >> /etc/mongod.conf
systemctl restart mongod

# Daily backup script
cat <<BACKUP > /usr/local/bin/mongo-backup.sh
#!/bin/bash
DATE=\$(date +%F)
mongodump -u admin -p "${MONGO_ADMIN_PASSWORD}" --authenticationDatabase admin --out /tmp/backup-\$DATE
aws s3 cp /tmp/backup-\$DATE s3://${BACKUP_BUCKET_NAME}/backup-\$DATE --recursive
rm -rf /tmp/backup-\$DATE
BACKUP
chmod +x /usr/local/bin/mongo-backup.sh

# Daily cron at 02:00
echo "0 2 * * * root /usr/local/bin/mongo-backup.sh >> /var/log/mongo-backup.log 2>&1" > /etc/cron.d/mongo-backup

echo "mongo-setup.sh completed successfully"