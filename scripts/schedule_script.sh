
#!/bin/sh

set -x

# check if bucket and R53 domain name is passed
if [[ "$#" -eq 1 ]]; then
    ARTIFACTS_BUCKET=$1
else
    echo "value for ARTIFACTS_BUCKET is required"
    exit 1;
fi

# check for master node
IS_MASTERNODE=false
if grep isMaster /mnt/var/lib/info/instance.json | grep true;
then
    IS_MASTERNODE=true
fi

if [ "$IS_MASTERNODE" = true ]
then

    cd ~
    mkdir EMRShutdown
    cd EMRShutdown
    touch /home/hadoop/EMRShutdown/EMRShutdown.log

    aws s3 cp ${ARTIFACTS_BUCKET} .
    chmod 700 pushShutDownMetrin.sh
    /home/hadoop/EMRShutdown/pushShutDownMetrin.sh --isEMRUsed

    #sudo bash -c 'echo "" >> /etc/crontab'
	sudo bash -c 'echo "*/5 * * * * root /home/hadoop/EMRShutdown/pushShutDownMetrin.sh --isEMRUsed" >> /etc/crontab'
	sudo bash -c 'echo "55 23 * * * root >  /home/hadoop/EMRShutdown/EMRShutdown.log" >> /etc/crontab'

fi