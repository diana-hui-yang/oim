#!/bin/ksh
#
# Name:         incremerge.fastcopy.ksh
#
# Function:     This script will copy files created by RMAN copy files that
#               are used for incrmenetal merge from one diretory to two other 
#               directories in the same mtree using DD fasctcopy. This step 
#               saves a full Oracle image backup before they are updated with 
#               new incremental data. One directory is named with the backup date. 
#               The date is determined by incremerge.ksh script which does 
#               RMAN incremental merge backup.The other directory is named with 
#               "recent". The copy that has the backup data will be retention 
#               locked to prevent accidently open or delete. The other copy 
#               can be used to validate the database backup.
#               First DD secure login should be set up from this Linux server
#               to DD. The last field of mount point is assumed to be the same
#               as the last field of mtree if mtree name is not provided. 
#               Retention lock is set based on the date that are fastcopied. 
#
# Show Usage: run the command to show the usage
#
# Changes:
# 10/1/16 Diana Yang   New script
# 02/19/18 Diana Yang  Add retention lock
# 08/29/18 Diana Yang  Add logs and troubleshooting
# 09/19/18 Diana Yang  Add creating retention-lock on Oracle backup mtree automatically
#
# footnotes:
# If you use this script and would like to get new code when any fixes are added,
# please send an email to diana.h.yang@dell.com. Whenever it is updated, I will send
# you an alert.
#################################################################

function show_usage {
echo "usage: incremerge-fastcopy.ksh -d <Data Domain> -u <DD User> -m <Mount Point> -h <host> -o <Oracle_sid> -t <mtree> -k <retention lock days>" 
echo " -d : Data Domain"
echo " -u : DD user (administrator role)"
echo " -m : Mount point"
echo " -h : host"
echo " -o : ORACLE_SID"
echo " -t : mtree (optional, start with /data/col1/
If mtree is not provides, we assume it is the same as the last field of Mount Point)"
echo " -k : Retention Lock in Days" 
}
while getopts ":d:u:m:k:h:o:" opt; do
  case $opt in
    d ) dd=$OPTARG;;
    u ) user=$OPTARG;;
    m ) mount=$OPTARG;;
    k ) lockday=$OPTARG;;
    h ) host=$OPTARG;;
    o ) oraclesid=$OPTARG;;
    t ) mtree=$OPTARG;;
  esac
done

echo $dd $user $mount $host $oraclesid $lockday

# Check required parameters
if test $dd && test $user && test $mount && test $host && test $oraclesid && test $lockday
then
  :
else
  show_usage
  exit 1
fi

DIRcurrent=$0
DIR=`echo $DIRcurrent |  awk 'BEGIN{FS=OFS="/"}{NF--; print}'`
if [[ $DIR = "." ]]; then
   DIR=`pwd`
fi

#echo "directory is $DIR"

if [[ ! -d $DIR/log ]]; then
    print " $DIR/log does not exist, create it"
    mkdir $DIR/log
fi
 
currentDATE=`/bin/date '+%Y%m%d%H%M%S'`
runlog=$DIR/log/$host.$oraclesid.incremerge-fastcopy.$currentDATE.log
setret_ksh=$DIR/$host.$oraclesid.setretention.ksh

DATE_SUFFIX=`cat /tmp/$host.$oraclesid.incremerge.time`
if [ $? -ne 0 ]; then
    echo "Cannot open file /tmp/$host.$oraclesid.incremerge.time" >> $runlog
    exit 1
fi
echo "Oracle backup time was $DATE_SUFFIX" >> $runlog



#echo "runlog is $runlog"

echo "Incremerge-fastcopy.ksh script starts at $DATE_SUFFIX" > $runlog 
echo "Oracle datafiles were copied to directory $mount/incre/datafile" >> $runlog 
sdir=$mount/$host/$oraclesid/incre/datafile

if [[ ! -d $sdir ]]; then
    print "Source Directory $sdir does not exist"
    exit 1
fi

echo "Fastcopy Oracle datafiles in  $mount/$host/$oraclesid/incre/datafile to $mount/$host/$oraclesid/incre/datafile.$DATE_SUFFIX" >> $runlog 
echo "Fastcopy Oracle datafiles in  $mount/$host/$oraclesid/incre/datafile to $mount/$host/$oraclesid/incre/datafile.recent" >> $runlog 
newdir=$mount/$host/$oraclesid/incre/datafile.$DATE_SUFFIX

if [[ -z $mtree ]]; then
    mtree=/data/col1/`echo $mount | awk -F "/" '{print $NF}'`
    print "Mtree is not provided, we assume it is same as the last field of Mount Point" >> $runlog 
    print "Mtree is $mtree" >> $runlog 
fi

echo "fastcopy started at " `/bin/date '+%Y%m%d%H%M%S'` >> $runlog
ssh $user@$dd "filesys fastcopy source $mtree/$host/$oraclesid/incre/datafile destination $mtree/$host/$oraclesid/incre/datafile.$DATE_SUFFIX force"
ssh $user@$dd "filesys fastcopy source $mtree/$host/$oraclesid/incre/datafile destination $mtree/$host/$oraclesid/incre/datafile.recent force"

if [ $? -ne 0 ]; then
    echo "fastcopy failed at " `/bin/date '+%Y%m%d%H%M%S'` >> $runlog
    exit 1
fi

echo "fastcopy finished at " `/bin/date '+%Y%m%d%H%M%S'` >> $runlog

cd $newdir
find . -type f |  grep -v "snapshot" > $DIR/oracle-image-file 

echo "create set retention lock script $setret_ksh at " `/bin/date '+%Y%m%d%H%M%S'` >> $runlog
echo "#!/bin/ksh" > $setret_ksh
while IFS= read -r line
do
    locktime=$(/bin/date '+%Y%m%d%H%M' -d "+$lockday days")
    echo touch -a -t $locktime $line >> $setret_ksh 


done < $DIR/oracle-image-file
chmod 755 $setret_ksh
cp $setret_ksh /tmp/$host.$oraclesid.setretention.ksh

/bin/rm $DIR/oracle-image-file


ret_status=`ssh $user@$dd "mtree list $mtree"  | grep -i orabfs | awk '{print $3}' | awk -F "/" '{print $2}'`

if [[ $ret_status != "RLGE"  && $ret_status != "RLCE" ]]; then
   echo "Retention lock is not enabled on this mtree $mtee. Will enable governance mode " >> $runlog
   ssh $user@$dd "mtree retention-lock enable mode governance mtree $mtree"
   
   if [ $? -ne 0 ]; then
      echo "Cannot enable retention lock, maybe there is no license key" >> $runlog
      exit
   fi
   
   ssh $user@$dd "mtree retention-lock set max-retention-period "$lockday"day mtree $mtree"
else
   echo "Retention lock is enabled on this mtree $mtree. " >> $runlog
fi
