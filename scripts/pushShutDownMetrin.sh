
#!/bin/bash

########################################
# Initial Settings
########################################
SCRIPT_NAME=${0##*/}
SCRIPT_VERSION=1.0

instanceid=`wget -q -O - http://169.254.169.254/latest/meta-data/instance-id`
pDNSName=`wget -q -O - http://169.254.169.254/latest/meta-data/public-hostname`
azone=`wget -q -O - http://169.254.169.254/latest/meta-data/placement/availability-zone`
region=${azone/%?/}
aws configure set region us-east-1

jobflowid=$(cat /mnt/var/lib/info/job-flow.json | jq -r ".jobFlowId")

export EC2_REGION=$region

########################################
# Usage
########################################
usage() 
{
    echo "Usage: $SCRIPT_NAME [options] "
    echo "Options:" 
    printf "    %-28s %s\n" "-h|--help" "Displays detailed usage information."
    printf "    %-28s %s\n" "--version" "Displays the version number."
    printf "    %-28s %s\n" "--verify" "Checks configuration and prepares a remote call."
    printf "    %-28s %s\n" "--verbose" "Displays details of what the script is doing."
    printf "    %-28s %s\n" "--from-cron" "Use this option when calling the script from cron."
    printf "    %-28s %s\n" "--isEMRUsed" "Use this option to pass isEMRUsed Custom metric to cloudwatch"
}

########################################
# Options
########################################
SHORT_OPTS="h"
LONG_OPTS="help,version,verify,verbose,from-cron,isEMRUsed"

ARGS=$(getopt -s bash --options $SHORT_OPTS --longoptions $LONG_OPTS --name $SCRIPT_NAME -- "$@" )

VERIFY=0
VERBOSE=0
FROM_CRON=0
PROFILE=""
ISEMRUSED=0
ISSSH=0
EMRISIDLE=1
ISACTIVEYARN=0
ZTASKACTIVE=0
presto_InProgress=0
presto_Finished=0

eval set -- "$ARGS" 
while true; do
    case $1 in
        # General
        -h|--help)
            usage
            exit 0
            ;;
        --version)
            echo "$SCRIPT_VERSION" 
            ;;
        --verify)
            VERIFY=1
            ;;
        --verbose)
            VERBOSE=1
            ;;
        --isEMRUsed)
            ISEMRUSED=1
            ;;
        --)
            shift
            break
            ;;
        *)
            shift
            break
            ;;
    esac
    shift
done

########################################
# Utility Function
########################################
isActiveSSh()
{       
        woutrow=`(w | wc -l)`
        if [[ "$woutrow" -gt 2 ]]
        then    
                sec=`(w | awk 'NR > 2 { print $5 }')`
                for i in $sec
                do      
                        if [[ $i == *.* ]]; then
                                ISSSH=1
                                break
            		elif [[ $i == *:*m ]]; then
				continue
                		#break   
                        elif [[ $i == *:* ]]; then
                                arrTime=(${i//:/ })
                                if [[ "${arrTime[0]}"  -lt 10 ]]; then
                                        ISSSH=1
                                        break
                                fi
                        fi
                done
        fi
}

fetchISIdleMetric()
{
        STARTTIME="$(date -u -d '5 minutes ago' '+%Y-%m-%dT%T')"
        ENDTIME="$(date -u '+%Y-%m-%dT%T')"
        EMRISIDLE=`(aws cloudwatch get-metric-statistics --namespace AWS/ElasticMapReduce --metric-name IsIdle --start-time $STARTTIME --end-time $ENDTIME --period 60 --statistics Average --dimensions="Name=JobFlowId, Value=$jobflowid" --output text | awk 'NR > 1 { print $2 }')`

    if [[ $EMRISIDLE = 1.0 ]]; then
        isIdle=1
    else
        isIdle=0
    fi

    echo "*******************************************" >> /home/hadoop/EMRShutdown/EMRShutdown.log
    echo "$ENDTIME" >> /home/hadoop/EMRShutdown/EMRShutdown.log
    echo "IsIdle metric returned from CloudWatch : $EMRISIDLE" >> /home/hadoop/EMRShutdown/EMRShutdown.log

}

yarnJobsStatusChk()
{
    appid=`yarn application -list | awk 'NR>2' | grep 'RUNNING' | awk '{print $1}'`
    for i in `echo $appid`
    do
    running_jobs=`curl -s http://$pDNSName:18080/api/v1/applications/$i/jobs?status=running|grep 'completionTime'| awk '{print $3}'|head -n 1`

    if [[ -n $running_jobs ]]; then
        #echo "Output is not null."f
        ISACTIVEYARN=1
        break
    else
        #echo "Output is null."
        completiondate=`curl -s http://$pDNSName:18080/api/v1/applications/$i/jobs?status=succeeded|grep 'completionTime'| awk '{print $3}'|head -n 1`
        if [[ -n $completiondate ]]; then
            completiontime=${completiondate:1:26}
            target=$(date +%s -d $completiontime)
            current=$(date +%s)
            mphr=60
            time_diff=$(( ($current - $target) / $mphr ))

            if [[ "$time_diff" -lt "50" ]]
            then
               #echo "time diff less than 2"
               ISACTIVEYARN=1
               break
            fi
        fi
    fi
    done;
}

yarnAppsRunning()
{
	appNames=$( curl -s "http://$pDNSName:8088/ws/v1/cluster/apps?state=RUNNING"|jq '.[]'|grep '"name":' )
	#echo $appNames

	ZRunning=0
	NonZRunning=0
	if [[ -n $appNames ]]; then
  		# echo "not empty"

   		while IFS=',' read -ra ADDR; do
     		for index in "${ADDR[@]}"; do
        		#echo $index
        		if [[ $index = *"Zeppelin"* ]]; then
            		    if [ $ZRunning -eq 0 ]; then
                		#echo "contains Zeppelin"
                		ZRunning=1
            		    fi
        		else
        		    echo "Entered into non-zepplin"
        		    echo "contains $index"
           			NonZRunning=1
                    break
        		fi
     		done
   		done <<< "$appNames"
	fi

    if [ $NonZRunning -eq 0 ]; then

        appFinishTime=$( curl -s "http://$pDNSName:8088/ws/v1/cluster/apps?state=FINISHED"|jq '.[]'|grep '"finishedTime":'|awk '{print $2}' )
        appCurrentTime=$((`date +%s`*1000+`date +%-N`/1000000))
        appMPH=60000
        #echo $((`date +%s`*1000+`date +%-N`/1000000))

        while IFS=',' read -ra ADDR; do
           for cTime in "${ADDR[@]}"; do
           appTime_diff=$(( ($appCurrentTime - $cTime) / $appMPH ))
              if [[ "$appTime_diff" -lt "5" ]]; then
                  NonZRunning=1
                  break
              fi
           done
        done <<< "$appFinishTime"
    fi

}

zeppelinCheck()
{
	NBResult=$( curl -s "http://$pDNSName:8890/api/notebook"| jq '.[]'|awk 'NR>2'|grep 'id'|awk '{print $2}' )
	for i in `echo $NBResult`
	do
		notebookID=${i:1:${#i}-2}
		isAnyParaRunning=$( curl -s "http://$pDNSName:8890/api/notebook/job/$notebookID"| jq '.[]'|awk 'NR>1' |grep 'RUNNING' )
		if [[ -n $isAnyParaRunning ]]; then
			ZTASKACTIVE=1
			break
		else
			Zfin_jobs=$( curl -s "http://$pDNSName:8890/api/notebook/job/$notebookID"| jq '.[]'|awk 'NR>1' |grep 'finished' )
			currentTime=$(date +%s)
			mphr=60

			while IFS=',' read -ra ADDR; do
				for index in "${ADDR[@]}"; do
					Zfin_date2=${index:16}
					Zfin_date=${Zfin_date2:1:28}

					Ztarget="$(date -u -d "$Zfin_date" '+%Y-%m-%dT%T')"
					Ztarget2=$(date +%s -d $Ztarget)

					Ztime_diff=$(( ($currentTime - $Ztarget2) / $mphr ))
					#echo "diff:$Ztime_diff"
					if [[ "$Ztime_diff" -lt "5" ]]
					then
						ZTASKACTIVE=1
						break
					fi
				done
			done <<< "$Zfin_jobs"

			if [ $ZTASKACTIVE -eq 1 ]; then
				break
            else

                mod_jobs=$( curl -s "http://$pDNSName:8890/api/notebook/$notebookID"| jq '.body.paragraphs' )
                for row in $(echo "${mod_jobs}" | jq -r '.[] | @base64'); do
                    _jq() {
                        echo ${row} | base64 --decode | jq -r ${1}
                    }
                    dModified=$(_jq '.dateUpdated')

                    if [[ $dModified != "null" ]]; then
                        mtarget="$(date -u -d "$dModified" '+%Y-%m-%dT%T')"
                        mtarget2=$(date +%s -d $mtarget)

                        mtime_diff=$(( ($currentTime - $mtarget2) / $mphr ))

                        if [[ "$mtime_diff" -lt "5" ]]
                        then
                            ZTASKACTIVE=1
                            break
                        fi
                    fi
                done

                if [ $ZTASKACTIVE -eq 1 ]; then
                    break
                fi
			fi
		fi
	done;
}

prestoCheck()
{
    prestoQueries=$( curl -s "http://$pDNSName:8889/v1/query"|jq '.[]' )

    if [[ -n $prestoQueries ]]; then
        stateLst=$( curl -s "http://$pDNSName:8889/v1/query"|jq '.[]' | grep '"state":' )
        presto_InProgress=0
        presto_Finished=0

        while IFS=',' read -ra ADDR; do
            for index in "${ADDR[@]}"; do
                if [[ ( $index = *"QUEUED"* ) || ( $index = *"PLANNING"* ) || ( $index = *"STARTING"* ) || ( $index = *"RUNNING"* ) || ( $index = *"FINISHING"* ) ]]; then
                    presto_InProgress=1
                    break
                elif [[ $index = *"FINISHED"* ]]; then
                    presto_Finished=1
                fi
            done
        done <<< "$stateLst"

        if [[ ( $presto_InProgress -eq 0 ) && ( $presto_Finished -eq 1 ) ]]; then

            queryObject=$( curl -s "http://$pDNSName:8889/v1/query" )
            for row in $(echo "${queryObject}" | jq -r '.[] | @base64'); do
                _jq() {
                    echo ${row} | base64 --decode | jq -r ${1}
                }

            qState=$(_jq '.state')

            if [[ $qState = *FINISHED* ]]; then
                qCompletionTime=$(_jq '.queryStats.endTime')
                qtarget=$(date +%s -d $qCompletionTime)

                qcurrent=$(date +%s)
                qmphr=60
                qtime_diff=$(( ($qcurrent - $qtarget) / $qmphr ))
                #echo $qtime_diff

                if [[ "$qtime_diff" -lt "5" ]]
                then
                #echo "time diff less than 2"
                    presto_InProgress=1
                    break
                fi
            fi
            done
        fi
    fi
}

########################################
# Main
########################################

# Avoid a storm of calls at the beginning of a minute
if [ $FROM_CRON -eq 1 ]; then
    sleep $(((RANDOM%20) + 1))
fi

# CloudWatch Command Line Interface Option
CLOUDWATCH_OPTS="--namespace EMRShutdown/Cluster-Metric --dimensions JobFlowId=$jobflowid"
if [ -n "$PROFILE" ]; then
    CLOUDWATCH_OPTS="$CLOUDWATCH_OPTS --profile $PROFILE"
fi

if [ $ISEMRUSED -eq 1 ]; then
    emruse=1
    fetchISIdleMetric
    echo "isIdle:$isIdle" >> /home/hadoop/EMRShutdown/EMRShutdown.log
    isActiveSSh
    echo "isAnyActiveSSH:$ISSSH" >> /home/hadoop/EMRShutdown/EMRShutdown.log
    yarnJobsStatusChk
    echo "Active-Spark-Jobs:$ISACTIVEYARN" >> /home/hadoop/EMRShutdown/EMRShutdown.log

    yarnAppsRunning
    prestoCheck
    zeppelinCheck
    
    if [ $VERBOSE -eq 1 ]; then
            echo "isAnyActiveSSH:$ISSSH"
            echo "isIdle:$isIdle"
            echo "Active-Yarn-Jobs:$ISACTIVEYARN"
            echo "NonZRunning:$NonZRunning"
            echo "PresoRunning:$presto_InProgress"
            echo "ZRunning:$ZRunning"
	    echo "ZActive:$ZTASKACTIVE"


	if [[ ( $ISSSH -eq 0 ) && ( $NonZRunning -eq 0 ) && ( $presto_InProgress -eq 0 ) && ( $ZTASKACTIVE -eq 0) ]]; then
        	emruse=0
        fi

        echo "Other-Running:$NonZRunning" >> /home/hadoop/EMRShutdown/EMRShutdown.log
        echo "PrestoInprogress:$presto_InProgress" >> /home/hadoop/EMRShutdown/EMRShutdown.log
        echo "Zeppelin-Running:$ZRunning" >> /home/hadoop/EMRShutdown/EMRShutdown.log
        echo "Zeppelin-ActiveTask:$ZTASKACTIVE" >> /home/hadoop/EMRShutdown/EMRShutdown.log
        echo "isEMRInUse:$emruse"
        echo "isEMRInUse:$emruse" >> /home/hadoop/EMRShutdown/EMRShutdown.log
        echo "  " >> /home/hadoop/EMRShutdown/EMRShutdown.log
    fi

        if [ $VERIFY -eq 0 ]; then

          #  if [ $ISSSH -eq 0 ]; then

          #      if [ $isIdle -eq 1 ]; then
          #          emruse=0
          #      else
          #          if [ $NonZRunning -eq 0 ]; then
          #              #emruse=0
          #              if [ $ZRunning -eq 1 ]; then
          #              	zeppelinCheck
          #              	if [ $ZTASKACTIVE -eq 0 ]; then
          #              		emruse=0
          #              	fi
          #              fi
          #          fi
          #      fi
          #  fi

	    if [[ ( $ISSSH -eq 0 ) && ( $NonZRunning -eq 0 ) && ( $presto_InProgress -eq 0 ) && ( $ZTASKACTIVE -eq 0) ]]; then
                emruse=0
            fi

            echo "Other-Running:$NonZRunning" >> /home/hadoop/EMRShutdown/EMRShutdown.log
            echo "PrestoInprogress:$presto_InProgress" >> /home/hadoop/EMRShutdown/EMRShutdown.log
            echo "Zeppelin-Running:$ZRunning" >> /home/hadoop/EMRShutdown/EMRShutdown.log
            echo "Zeppelin-ActiveTask:$ZTASKACTIVE" >> /home/hadoop/EMRShutdown/EMRShutdown.log
            echo "isEMRInUse:$emruse" >> /home/hadoop/EMRShutdown/EMRShutdown.log
            echo "  " >> /home/hadoop/EMRShutdown/EMRShutdown.log

            aws cloudwatch put-metric-data --metric-name "isEMRUsed" --value "$emruse" --unit "Count" $CLOUDWATCH_OPTS

            aws cloudwatch put-metric-data --metric-name "sshMetric" --value "$ISSSH" --unit "Count" $CLOUDWATCH_OPTS
            aws cloudwatch put-metric-data --metric-name "idleMetric" --value "$isIdle" --unit "Count" $CLOUDWATCH_OPTS
            aws cloudwatch put-metric-data --metric-name "NonZRunning" --value "$NonZRunning" --unit "Count" $CLOUDWATCH_OPTS
            aws cloudwatch put-metric-data --metric-name "PrestoActive" --value "$presto_InProgress" --unit "Count" $CLOUDWATCH_OPTS
            aws cloudwatch put-metric-data --metric-name "ZRunning" --value "$ZRunning" --unit "Count" $CLOUDWATCH_OPTS
            aws cloudwatch put-metric-data --metric-name "zActive" --value "$ZTASKACTIVE" --unit "Count" $CLOUDWATCH_OPTS
        fi
fi

