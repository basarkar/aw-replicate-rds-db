#!/bin/bash

##########################################################################
# create-staging-db.sh
#
# Usage:
#   ./create-staging-db.sh
#
# **** Run As root user in the ec2 box *****
#
#
# IAM Policy:
# {
#    "Version": "2012-10-17",
#    "Statement": [
#        {
#            "Sid": "Stmt1484336242000",
#            "Effect": "Allow",
#            "Action": [
#                "rds:DeleteDBInstance",
#                "rds:DescribeDBInstances",
#                "rds:ModifyDBInstance",
#                "rds:RestoreDBInstanceFromDBSnapshot",
#                "rds:RebootDBInstance"
#            ],
#            "Resource": [
#                "arn:aws:rds:us-east-1:AWS_ACCOUNT_ID:db:RDS_INSTANCE_NAME_STAGE"
#            ]
#        },
#        {
#            "Sid": "Stmt1485281517680",
#            "Effect": "Allow",
#            "Action": [
#                "rds:DescribeDBSnapshots"
#            ],
#            "Resource": [
#                "arn:aws:rds:us-east-1:AWS_ACCOUNT_ID:db:RDS_INSTANCE_NAME_PROD"
#            ]
#        },
#        {
#            "Sid": "Stmt1485294193230",
#            "Effect": "Allow",
#            "Action": [
#                "rds:RestoreDBInstanceFromDBSnapshot"
#            ],
#            "Resource": [
#                "arn:aws:rds:us-east-1:AWS_ACCOUNT_ID:snapshot:rds:RDS_INSTANCE_NAME_PROD-*",
#                "arn:aws:rds:us-east-1:AWS_ACCOUNT_ID:subgrp:prod-subnet-group"
#            ]
#        },
#        {
#            "Sid": "Stmt1485294193232",
#            "Effect": "Allow",
#            "Action": [
#                "rds:ModifyDBInstance"
#            ],
#            "Resource": [
#                "arn:aws:rds:us-east-1:AWS_ACCOUNT_ID:pg:prod-mysql5-6"
#            ]
#        }
#    ]
# }
#
#
# AWS config ~/.aws/config
# [profile StageDatabaseCreater]
# output = text
# region = us-east-1
#
#
#
# Creates a new RDS instance by cloning the latest production snapshot.
# More specifically, the following steps are performed:
#   - Determine the snapshot id to use
#   - Delete the existing database
#   - Create the new database
#   - Make necessary modifications to the new instances (disable backups)
##########################################################################

PATH=$PATH:/usr/local/bin
stage_instance_identifier=RDS_INSTANCE_NAME_STAGE
DATE=`date +%Y-%m-%d-%H-%M-%S`
stage_snapshot_identifier="$stage_instance_identifier-$DATE"
prod_instance_identifier=RDS_INSTANCE_NAME_PROD
instance_class=db.t2.medium
security_group=sg-69a5d30d
subnet_group=prod-subnet-group
db_parameter_group=prod-mysql5-6
stage_db_root_pass=ROOT_PASS

function wait-for-status {
    instance=$1
    target_status=$2
    status=unknown
    while [[ "$status" != "$target_status" ]]; do
        sleep 5
        status=`aws rds describe-db-instances \
            --db-instance-identifier $instance --profile StageDatabaseCreater \
            --query 'DBInstances[0].DBInstanceStatus' --output text`
    done
}

function wait-until-deleted {
    instance=$1
    count=1
    while [[ "$count" != "0" ]]; do
        count=`aws rds describe-db-instances \
            --db-instance-identifier $instance --profile StageDatabaseCreater --output text 2>/dev/null \
            | grep DBINSTANCES \
            | wc -l \
            | tr -d ' '`
        sleep 5
    done
}

# fetch snapshot id
snapshot_id=`aws rds describe-db-snapshots \
    --db-instance-identifier $prod_instance_identifier --profile StageDatabaseCreater \
    --query 'DBSnapshots[-1].DBSnapshotIdentifier' --output text`

echo "Snapshot Id: $snapshot_id"
echo "Deleting database (if exists): $stage_instance_identifier"

# delete the existing instance
aws rds delete-db-instance \
    --db-instance-identifier $stage_instance_identifier \
    --final-db-snapshot-identifier $stage_snapshot_identifier --profile StageDatabaseCreater > /dev/null 2>&1

wait-until-deleted $stage_instance_identifier

echo "Creating new database: $stage_instance_identifier"

# create the new instance
aws rds restore-db-instance-from-db-snapshot \
    --db-instance-identifier $stage_instance_identifier \
    --db-snapshot-identifier=$snapshot_id \
    --db-instance-class $instance_class \
    --no-publicly-accessible \
    --no-multi-az \
    --no-auto-minor-version-upgrade \
    --db-subnet-group-name $subnet_group --profile StageDatabaseCreater > /dev/null

echo "Waiting for new DB instance to be available"

wait-for-status $stage_instance_identifier available

echo "New instance is available"
echo "Disabling backup retention"

# disable backup retention
aws rds modify-db-instance \
    --db-instance-identifier $stage_instance_identifier \
    --vpc-security-group-ids $security_group \
    --db-parameter-group-name $db_parameter_group \
    --backup-retention-period 0 \
    --master-user-password $stage_db_root_pass \
    --apply-immediately --profile StageDatabaseCreater  > /dev/null

echo "Waiting for new DB instance to be available"

wait-for-status $stage_instance_identifier available

# Reboot the instance
echo "Rebooting the database instance"
aws rds reboot-db-instance \
    --db-instance-identifier $stage_instance_identifier \
    --profile StageDatabaseCreater > /dev/null

echo "Waiting for new DB instance to be available"
wait-for-status $stage_instance_identifier available

echo "The new instance is available"
echo "The clone process is complete"
