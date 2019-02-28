#!/bin/bash
#
# Name:         incremerge.bash
#
# Function:     This script does Oracle rman incremental merge backup. 
#               It can do full backup or incremental forever backup.
#		After this script, DD fastcopy script is recommended to run 
#		to keep old backup.
#
# Show Usage: run the command to show the usage
#
# Changes:
# 08/03/18 Diana Yang   New script
# 08/29/18 Diana Yang	Add remote execute fastcopy script
# 08/30/18 Diana Yang	Add Oracle recovery window as input 
# 10/14/18 Diana Yang	Create a script that will catalog fastcopied files. 
#                       This script should be called after fastcopy  
# 02/27/19 Diana Yang	Add backup parallelism paramter. 
#
# footnotes:
# If you use this script and would like to get new code when any fixes are added,
# please send an email to diana.h.yang@dell.com. Whenever it is updated, I will send
# you an alert.
#################################################################

. /home/oracle/.bash_profile

function show_usage {
echo "usage: incremerge.bash -r <RMAN login> -h <host> -o <Oracle_sid> -w <recovery window> -t <backup type> -m <Mount point> -s <Linux server> -c <concurrent Streams>"
echo " -r : RMAN login (example: \"rman target /\")"  
echo " -h : host (optional)"  
echo " -o : ORACLE_SID" 
echo " -w : Oracle Recovery Window (retention time)"
echo " -t : backup type: Full or Incre"
echo " -m : Mount point"
echo " -s : linux server"
echo " -c : backup concurrent streams"
}

while getopts ":r:h:o:w:t:m:s:c:" opt; do
  case $opt in
    r ) rmanlogin=$OPTARG;;
    h ) host=$OPTARG;;
    o ) oraclesid=$OPTARG;;
    w ) retday=$OPTARG;;
    t ) ttype=$OPTARG;;
    m ) mount=$OPTARG;;
    s ) server=$OPTARG;;
    c ) parallel=$OPTARG;;
  esac
done

#echo $rmanlogin, $ttype, $mount, $retday

# Check required parameters
if test "$rmanlogin" && test $ttype && test $mount && test $retday && test $oraclesid && test $server
then
  :
else
  show_usage 
  exit 1
fi

function setup {
if test $host
then
  :
else
  host=`hostname -s`
fi

DATE_SUFFIX=`/bin/date '+%Y%m%d%H%M%S'`
echo $DATE_SUFFIX

DIRcurrent=$0
DIR=`echo $DIRcurrent |  awk 'BEGIN{FS=OFS="/"}{NF--; print}'`
if [[ $DIR = '.' ]]; then
   DIR=`pwd`
fi

#echo $DATE_SUFFIX > $DIR/incremerge.time
echo $DATE_SUFFIX > /tmp/$host.$oraclesid.incremerge.time

if [[ ! -d $DIR/log/$host ]]; then
    echo " $DIR/log/$host does not exist, create it"
    mkdir $DIR/log/$host
fi

backup_dir=$mount/$host/$oraclesid
data_root_dir=$backup_dir/full
full_dir=$data_root_dir/datafile
archive_dir=$backup_dir/archivelog
control_dir=$backup_dir/controlfile
runlog=$DIR/log/$host/$oraclesid.incremerge.$DATE_SUFFIX.log
rman1log=$DIR/log/$host/$oraclesid.rman1.$DATE_SUFFIX.log
rman2log=$DIR/log/$host/$oraclesid.rman2.$DATE_SUFFIX.log
catalog_log=$DIR/log/$host/$oraclesid.catalog.$DATE_SUFFIX.log
catalog_bash=$DIR/log/$host/$oraclesid.catalog.bash
tag=${oraclesid}_${DATE_SUFFIX}

if [[ -z $parallel ]]; then
    parallel=4 
fi

echo "#!/bin/bash" > $catalog_bash

#echo $host $ORACLE_SID $ttype $backup_dir

export ORACLE_SID=$oraclesid 
echo ". /home/oracle/.bash_profile" >> $catalog_bash
echo "export ORACLE_SID=$oraclesid" >> $catalog_bash


if [[ -n $server ]]; then
     echo "copy $host.$oraclesid.incremerge.time to $server " >> $runlog
     scp /tmp/$host.$oraclesid.incremerge.time $server:/tmp/$host.$oraclesid.incremerge.time 
     if [ $? -ne 0 ]; then
        echo "scp /tmp/$host.$oraclesid.incremerge.time failed at " `/bin/date '+%Y%m%d%H%M%S'` >> $runlog
        exit 1 
     fi
fi

#trim log directory
find $DIR/log/$host -type f -mtime +7 -exec /bin/rm {} \;

if [ $? -ne 0 ]; then
    echo "del old logs in $DIR/log/$host failed" >> $runlog
    exit 1
fi

echo "check whether $mount is a mountpoint. If not, script stop" >> $runlog

if mountpoint -q "$mount"; then
#make directory
    echo "$mount is mount point"
    echo " "

    if [[ ! -d "$control_dir" ]]; then
       echo "Directory $control_dir does not exist, create it"
       if mkdir -p $control_dir; then
          echo "$control_dir is created"
       fi
    fi

    if [[ ! -d "$full_dir" ]]; then
       echo "Directory $full_dir does not exist, create it"
       if mkdir -p $full_dir; then
          echo "$full_dir is created"
       fi
    fi

    if [[ ! -d "$archive_dir" ]]; then
       echo "Directory $archive_dir does not exist, create it"
       if mkdir -p $archive_dir; then
          echo  "$archive_dir is created"
       fi
    fi

else
    echo "$mount is not a mount point"
    exit 1
fi
}

function create_catalog {

     cd $full_dir
#echo oracle datafile directory $data_root_dir/datafile
     find . -type f |  grep -v "snapshot" | grep -i "data_D" > $DIR/${host}-${oraclesid}-datafile
#echo file is $DIR/${host}-${oraclesid}-datafile

#     echo ". /home/oracle/.bash_profile" >> $catalog_bash
     echo "echo \"Catalog the fastcopy files started at  \" \`/bin/date '+%Y%m%d%H%M%S'\`"  >> $catalog_bash
     echo "$rmanlogin log $catalog_log << EOF" >> $catalog_bash
     while IFS= read -r line
     do
	echo "CATALOG DATAFILECOPY '${data_root_dir}/datafile.${DATE_SUFFIX}/${line:1}' tag '${tag}';" >> $catalog_bash
     done < $DIR/${host}-${oraclesid}-datafile
     
     rm $DIR/${host}-${oraclesid}-datafile

     echo "backup as copy current controlfile format '$control_dir/$ORACLE_SID.ctl.$DATE_SUFFIX';"  >> $catalog_bash
     echo "exit;"  >> $catalog_bash
     echo "EOF"  >> $catalog_bash

     echo "echo \"Catalog the fastcopy files finished at  \" \`/bin/date '+%Y%m%d%H%M%S'\`"  >> $catalog_bash
    
     chmod 740 $catalog_bash
}

function full_backup {

#echo $full_dir $archive_dir $control_dir

echo "full backup started at " `/bin/date '+%Y%m%d%H%M%S'` 

echo "start full copy"
$rmanlogin log $rman1log << EOF
CONFIGURE DEFAULT DEVICE TYPE TO disk;
CONFIGURE CONTROLFILE AUTOBACKUP ON;
CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '$control_dir/%d_%F.ctl';
CONFIGURE DEVICE TYPE DISK PARALLELISM 4 BACKUP TYPE TO BACKUPSET;
CONFIGURE CHANNEL DEVICE TYPE DISK FORMAT   '$full_dir/%d_%T_%U';
configure retention policy to redundancy 1;
configure retention policy to recovery window of $retday days;

delete noprompt copy of database tag "incre_update";
crosscheck datafilecopy like "$full_dir/%";
delete noprompt expired datafilecopy all;
backup incremental level 1 for recover of copy with tag "incre_update" database;
recover copy of database with tag  "incre_update";
EOF

echo "create archivelogs"
$rmanlogin log $rman2log << EOF
sql 'alter system switch logfile';
backup archivelog like '+FRA/%' format '$archive_dir/%d_%T_%U.log';
backup as copy archivelog like '+FRA/%' format '$archive_dir/%U' delete input;

exit;

EOF

echo "full backup finished at " `/bin/date '+%Y%m%d%H%M%S'`
}

function incre_backup {

#echo $incre_dir $archive_dir $control_dir

echo "Incremental backup started at " `/bin/date '+%Y%m%d%H%M%S'`

echo "start incremental backup and recovery"

$rmanlogin log $rman1log << EOF
DELETE FORCE NOPROMPT OBSOLETE;
#DELETE NOPROMPT OBSOLETE;
CONFIGURE DEFAULT DEVICE TYPE TO disk;
CONFIGURE CONTROLFILE AUTOBACKUP ON;
CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '$control_dir/%d_%F.ctl';
CONFIGURE DEVICE TYPE DISK PARALLELISM $parallel BACKUP TYPE TO BACKUPSET;
CONFIGURE CHANNEL DEVICE TYPE DISK FORMAT   '$full_dir/%d_%T_%U';
configure retention policy to redundancy 1;
configure retention policy to recovery window of $retday days;

backup incremental level 1 for recover of copy with tag "incre_update" database;
recover copy of database with tag  "incre_update";
EOF

echo "start archivelog backup"
$rmanlogin log $rman2log << EOF
sql 'alter system switch logfile';
backup archivelog like '+FRA/%' format '$archive_dir/%d_%T_%U.log';
backup as copy archivelog like '+FRA/%' format '$archive_dir/%U' delete input;
exit;

EOF

echo "Incremental merge finished at " `/bin/date '+%Y%m%d%H%M%S'`

}

setup

if [[ $ttype = "full" || $type = "Full" || $ttype = "FULL" ]]; then
     echo "Full backup" 
     full_backup 
     if [ $? -ne 0 ]; then
        echo "full backup failed at " `/bin/date '+%Y%m%d%H%M%S'` >> $runlog
     else
        echo "full backup finished at " `/bin/date '+%Y%m%d%H%M%S'` >> $runlog
     fi
elif [[  $ttype = "incre" || $ttype = "Incre" || $ttype = "INCRE" ]]; then
     echo "incremental merge" 
     incre_backup
     if [ $? -ne 0 ]; then
        echo "incremental merge backup failed at " `/bin/date '+%Y%m%d%H%M%S'` >> $runlog
     else
        echo "incremental merge backup finished at " `/bin/date '+%Y%m%d%H%M%S'` >> $runlog
     fi
else
     echo "backup type entered is not correct. It should be full or incre"
     exit 1
fi

create_catalog

let retnewday=$retday+1
echo "Clean old backup longer than $retnewday started at " `/bin/date '+%Y%m%d%H%M%S'` >> $runlog
#####debug begin
find $backup_dir -type f -mtime +$retnewday -exec /bin/rm {} \;
find $backup_dir -depth -type d -empty -exec rmdir {} \;
#####debug finish

if [ $? -ne 0 ]; then
    echo "Clean old backup failed at " `/bin/date '+%Y%m%d%H%M%S'` >> $runlog
else
    echo "Clean old backup finished at " `/bin/date '+%Y%m%d%H%M%S'` >> $runlog
fi

