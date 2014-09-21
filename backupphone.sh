#!/bin/sh

sudo adb start-server || exit 1
TMP=$(mktemp)
exec 3>&2

ZBIN=gzip
ZSUFFIX=gz
MODE=pull
#MODE=shelldd

if [[ "$MODE" == "shelldd" ]]; then
	DOS2UNIX=$(
		type -p dos2unix >/dev/null && echo dos2unix ||
		{ [ -e /tmp/dos2unix ] || gcc dos2unix.c -o /tmp/dos2unix; echo /tmp/dos2unix; }
	)
else
	DOS2UNIX() {
		sed -u 's/\r$//'
	}
fi

progresscat() {
	cat "$1" | pv -etabps "$(stat -c %s "$1")" 2>&3
}

tarheaderraw()
{
	name=$1
	mode=$2
	uid=$3
	gid=$4
	size=$5
	mtime=$6
	type=$7
	sum=$8
	#echo "Tar header $name $mode $uid $gid $size $mtime $type $sum" 1>&2
	{
		printf "%-100s" $name |tr ' ' '\0'
		printf "%7s\0" $mode |tr ' ' 0
		printf "%07o\0" $uid
		printf "%07o\0" $gid
		printf "%011o\0" $size
		printf "%011o\0" $mtime
		if [[ "x$sum" == "x" ]]; then
			printf "%8s" ''
		else
			printf '%06o\0 ' $sum
		fi
		printf "%1s" "$type"
	} | dd bs=512 count=1 iflag=fullblock conv=sync 2>/dev/null
}

tarheader()
{
	tarheaderraw "$@" |  xxd -c 1 -ps | {
		sum=0
		while read byte; do
			sum=$((sum+0x$byte))
		done
		tarheaderraw "$@" $sum
	}
}

size2blocks()
{
	SIZE=$1
	BLOCKS=$(((SIZE-1)/512+1))
	echo $BLOCKS
}

tar2tarpiece()
{
	BLOCKS=$(($(size2blocks $1)+1))
	dd bs=512 count=$BLOCKS 2>/dev/null
}

data2tarpiece()
{
	name=$1
	mode=$2
	uid=$3
	gid=$4
	size=$5
	mtime=$6
	BLOCKS=$(size2blocks $size)
	tarheader $name $mode $uid $gid $size $mtime 0
	dd bs=512 count=$BLOCKS iflag=fullblock conv=sync status=noxfer 2>"$TMP"
	sed 's/+.*//' "$TMP" | {
		read blocksin
		read blocksout
		(( $blocksout == $BLOCKS )) || {
			cat "$TMP" 1>&2
			rm $TMP
			return $blocksout
		}
	}	
	rm $TMP
}

tarfolder()
{
	tarheader "$@" 5
}

tartail()
{
	dd bs=512 if=/dev/zero count=2 2>/dev/null
}

phone2stdout()
{
	path=$1
	count=$2
	skip=$3
	if [[ "$MODE" == "shelldd" ]]; then
		adb shell "dd if=$path bs=512 skip=$((skip/512)) count=$(size2blocks $count) 2>/dev/null" | $DOS2UNIX
	elif [[ "$MODE" == "pull" ]]; then
		adb pull $path /dev/stdout |
		dd bs=512 iflag=fullblock skip=$((skip/512)) count=$(size2blocks $count) 2>/dev/null
	fi
	sleep 1
}

# tar partitions and block together
TAG="$@"
if [[ "x$TAG" == "x" ]]; then TAG=phone; echo WARNING: no tag specified using - $TAG -; fi
FILES="$(adb shell "cd /dev/block; echo -n mmcblk*") "
TARFILE="$TAG.tar.$ZSUFFIX"
[ "x$FILES" != "x" ] || exit 1

RESUME=
if [ -s "$TARFILE" ] && [ ! -s "partial.$TARFILE" ]; then
	mv -v "$TARFILE" "partial.$TARFILE"
fi
if [ -s "partial.$TARFILE" ]; then
	# Resume existing files for now
	echo "Resuming partial.$TARFILE ..." 1>&2
	RESUME=$( progresscat "partial.$TARFILE" | $ZBIN -d | tar -vtRf -  2>/dev/null | tee /dev/stderr | {
		read _block blockColon _mod _own size _date _time folder
		if [ "$folder" != "$TAG/" ]; then
			echo "unexpected: $folder != $TAG/" 1>&2
		else while read _block blockColon _mod _own size _date _time name; do
			expected=${FILES%% *}
			if [ "$name" != "$TAG/$expected" ]; then
				if [ "$_mod" != '**' ]; then
					echo "unexpected: $name != $TAG/$expected" 1>&2
					RESUME=
				fi
				break;
			fi
			FILES="${FILES#* }"
			RESUME="$((${blockColon%:}*512)) $size $expected"
		done; fi
		echo $RESUME
	} )
fi

{

	if [ "x$RESUME" == "x" ]; then
		if [ -e "partial.$TARFILE" ]; then
			echo "Invalid resumefile, deleting." 1>&2
			rm "partial.$TARFILE"
		fi
		tarfolder "$TAG/" 555 0 0 0 $(date +%s)
	else
		resumeFile=${RESUME##* }
		resumeOffset=${RESUME% *}
		resumeSize=${resumeOffset#* }
		resumeOffset=${resumeOffset% *}
		PARTIAL="${FILES%%$resumeFile *}"
		FILES="${FILES#*$resumeFile }"
		if [ "x$PARTIAL" != "x" ]; then
			echo "Already transferred: $PARTIAL" 1>&2
		fi
		{ progresscat "partial.$TARFILE" | $ZBIN -d 2>&3 | tee /dev/stderr | wc -c > $TMP; } 2>&1
		size=$(<$TMP)
		rm $TMP
		transferred=$((size - resumeOffset))
		remaining=$((resumeSize - transferred));
	fi
	
	echo 1>&2
	read -n1 -p "   -- Press key to begin backup --   " 1>&2
	echo -ne "\r                                       \r" 1>&2

	#trap "sudo adb reboot" SIGINT
	
	sudo sh -v quickroot.sh 1>&2 || exit 1
	adb shell mount | while read device folder rest; do
		adb shell mount -o remount,ro "$device" "$folder" >/dev/null
	done

	if [ "x$RESUME" != "x" ]; then
		echo "Continuing $resumeFile at $transferred for $remaining ..." 1>&2
		PHONEF=/dev/block/$resumeFile
		echo adb shell "dd if=$PHONEF bs=512 skip=$((transferred/512)) count=$(size2blocks $remaining) 2>/dev/null" 1>&2
		phone2stdout "$PHONEF" "$remaining" "$transferred" |
			pv -etabps "$(( remaining + (transferred%512) ))" -N "$resumeFile" |
			dd iflag=fullblock conv=sync bs=512 count=$(size2blocks $remaining) 2>"$TMP" |
			tail -c +$((transferred % 512))
		sed 's/+.*//' "$TMP" | {
			read blocksin
			read blocksout
			[ "0" != "x$((blocksout))" ] && (( $blocksout == $(size2blocks $remaining) )) || {
				cat "$TMP" 1>&2
				rm $TMP
				exit $blocksout
			}
		}
		rm $TMP
	fi

	for F in $FILES; do
		PHONEF=/dev/block/$F

		size=$(adb shell "dd < $PHONEF > /dev/null" | tee $TMP | sed -ne 's/^\([0-9]*\) bytes.*/\1/p')
		if ! (( size )); then
			cat $TMP
			rm $TMP
			exit 1
		fi
		rm $TMP
		echo "Transferring $size bytes in $(size2blocks $size) blocks..." 1>&2
		
		phone2stdout "$PHONEF" "$size" 0 |
			pv -etabps "$size" -N "$F" |
			data2tarpiece "$TAG/$F" 444 0 0 $size $(adb shell date +%s | $DOS2UNIX) || { touch $TMP; exit $?; }
	done
	if ! [ -e $TMP ]; then tartail; fi
} | $ZBIN > "$TARFILE"
if [ -e $TMP ]; then 
	rm $TMP
	echo FAIL
else
	echo "$TARFILE created, verify ..."
	adb reboot
	tar -atvf "$TARFILE"
fi
