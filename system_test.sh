#!/bin/sh -u

trap '' ERR 2> /dev/null || exec bash $0 "$@"

# test runner

function try { let tests+=1; this="$1"; }

function assert {
	[[ "$1" == "$2" ]] && { printf "."; return; }
	printf "\nFAIL: $this\n'$1' != '$2'\n"

	echo "*************************************"
	echo "System test directory contents:"
	: | head -n 50 $(find $tmp -type f  ! -perm -111)
	echo "*************************************"
	exit 1
}
function skip { printf "s"; }

function zz { sleep 0.25; }
function setup {
	rm -f $tmp/*
	touch $tmp/file1 $tmp/file2
	unset ENTR_STATUS_SCRIPT
}
tmp=$(cd $(mktemp -d ${TMPDIR:-/tmp}/entr-system-test-XXXXXX); pwd -P)
tsession=$(basename $tmp)

let tests=0
clear_tty='test -t 0 && stty echo icanon'
clear_tmux='tmux kill-session -t $tsession 2>/dev/null || true'
clear_tmp='rm -rf $tmp'
trap "$clear_tty; $clear_tmux; $clear_tmp" EXIT
trap 'printf "\nTerminated by SIGINT at line $LINENO\n"; exit 1' INT

# required utilities

utils="file pgrep git vim tmux"
for util in $utils; do
	p=$(command -v $util) || {
		echo "ERROR: could not locate the '$util' utility" >&2
		echo "System tests depend on the following: $utils" >&2
		exit 1
	}
done

if [ $(uname) == 'Linux' ]; then
	date | awk -S '{}' 2> /dev/null || {
		echo "ERROR: gawk required on Linux"
		exit 1
	}
fi

# local binary, non-interactive by default
alias entr='./entr -n'
alias entr_tty='./entr'

# alias expansion is not enabled by default in non-interactive Bourne Again Shell (bash) sessions
command -v shopt > /dev/null && shopt -s expand_aliases

# fast tests

try "no arguments"
	entr 2> /dev/null || code=$?
	assert $code 1

try "no input"
	echo | entr echo "vroom" 2> /dev/null || code=$?
	assert $code 1

try "reload and clear options with no utility to run"
	entr -r -c 2> /dev/null || code=$?
	assert $code 1

try "empty input"
	echo "" | entr echo 2> /dev/null || code=$?
	assert $code 1

try "no regular files provided as input"
	mkdir $tmp/dir1
	ls $tmp | entr echo 2> /dev/null || code=$?
	rmdir $tmp/dir1
	assert $code 1

# status message tests

try "install default status script"
	setup
	export ENTR_STATUS_SCRIPT="$tmp/status.awk"
	ls $tmp/* | entr -zx true >$tmp/exec.out 2>$tmp/exec.err &
	bgpid=$! ; zz
	wait $bgpid
	assert "$(cat $tmp/exec.err)" ""
	assert "$(cat $tmp/exec.out)" "$(printf "entr: created '$tmp/status.awk'\ntrue returned exit code 0\n")"

try "status script not compatible with restart option"
	setup
	ls $tmp/* | entr -zrx true >$tmp/exec.out 2>$tmp/exec.err &
	bgpid=$! ; zz
	wait $bgpid; assert "$?" "1"

try "block unsafe status script"
	setup
	export ENTR_STATUS_SCRIPT="$tmp/status.awk"
	cat > $ENTR_STATUS_SCRIPT <<-EOF
	{ system("date") }
	EOF
	ls $tmp/* | entr -zx true >$tmp/exec.out 2>$tmp/exec.err &
	bgpid=$! ; zz
	sed -i -e "s,.*awk: .*,awk: system is unsafe ... status.awk," $tmp/exec.err
	assert "$(head -n1 $tmp/exec.err)" "awk: system is unsafe ... status.awk"
	assert "$(head -n1 $tmp/exec.out)" ""

try "allow unsafe status script"
	setup
	export ENTR_STATUS_SCRIPT="$tmp/status.awk"
	cat > $ENTR_STATUS_SCRIPT <<-EOF
	{ system("date") }
	EOF
	ls $tmp/* | entr -zxx true >$tmp/exec.out 2>$tmp/exec.err &
	bgpid=$! ; zz
	assert "$(head -n1 $tmp/exec.err)" ""

try "use custom status script"
	setup
	export ENTR_STATUS_SCRIPT="$tmp/status.awk"
	cat > $ENTR_STATUS_SCRIPT <<-'EOF'
	{
	  print "=", $1, $2, "="
	}
	EOF
	ls $tmp/* | entr -zx false >$tmp/exec.out 2>$tmp/exec.err &
	bgpid=$! ; zz
	assert "$(cat $tmp/exec.err)" ""
	assert "$(cat $tmp/exec.out)" "$(printf '= exit 1 =')"

try "use custom status script with shell option and kill"
	setup
	export ENTR_STATUS_SCRIPT="$tmp/status.awk"
	cat > $ENTR_STATUS_SCRIPT <<-'EOF'
	{
	  print "=", $1, $2, "="
	}
	EOF
	ls $tmp/* | entr -zx -s 'kill -9 $$' >$tmp/exec.out 2>$tmp/exec.err &
	bgpid=$! ; zz
	assert "$(cat $tmp/exec.err)" ""
	assert "$(cat $tmp/exec.out)" "$(printf '= signal 9 =')"

try "abort if status script terminates"
	setup
	export ENTR_STATUS_SCRIPT="$tmp/status.awk"
	cat > $ENTR_STATUS_SCRIPT <<-'EOF'
	{ exit; }
	EOF
	ls $tmp/* | entr -x true >$tmp/exec.out 2>$tmp/exec.err &
	bgpid=$! ; zz
	assert "$(cat $tmp/exec.err)" "entr: status process terminated"
	assert "$(cat $tmp/exec.out)" ""

# terminal tests

unset TMUX

try "spacebar triggers utility"
	setup
	env SHELL=/bin/sh tmux new-session -s $tsession -d
	echo "waiting" > $tmp/file1
	echo "finished" > $tmp/file2
	tmux send-keys -t $tsession:0 \
	    "ls $tmp/file2 | ./entr -p cp $tmp/file2 $tmp/file1" C-m ; zz
	assert "$(cat $tmp/file1)" "waiting"
	tmux send-keys -t $tsession:0 "xyz" C-m ; zz
	assert "$(cat $tmp/file1)" "waiting"
	tmux send-keys -t $tsession:0 " " ; zz
	assert "$(cat $tmp/file1)" "finished"
	tmux send-keys -t $tsession:0 "q" ; zz
	tmux kill-session -t $tsession

# file system tests

try "exec a command using one-shot option"
	setup
	ls $tmp/file2 | entr -zp cat $tmp/file2 >$tmp/exec.out 2>$tmp/exec.err &
	bgpid=$! ; zz
	echo 456 >> $tmp/file2 ; zz
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.err)" ""
	assert "$(head -n1 $tmp/exec.out)" "$(printf '456\n')"

try "exec a command using one-shot option and return signal number"
	setup
	ls $tmp/file2 | entr -z sh -c 'kill -9 $$' >$tmp/exec.out 2>$tmp/exec.err
	assert "$?" "137"
	assert "$(cat $tmp/exec.err)" ""
	assert "$(cat $tmp/exec.out)" ""

try "exec a command using one-shot and shell options and return signal"
	setup
	ls $tmp/file2 | entr -z -s 'kill -9 $$' >$tmp/exec.out 2>$tmp/exec.err
	assert "$?" "137"
	assert "$(tail -c23  $tmp/exec.out)" ""

try "fail to exec a command using one-shot option"
	setup
	ls $tmp/file* | entr -z /usr/bin/false_X 2>$tmp/exec.err
	assert "$?" "1"

try "exec a command using one-shot option exit code from child"
	setup
	ls $tmp/file* | entr -z sh -c 'exit 4' &
	bgpid=$! ; zz
	wait $bgpid; assert "$?" "4"

try "restart a server when a file is modified using one-shot option"
	setup
	if [ $(uname) == 'Linux' ]; then
		skip "GNU nc spins while retrying SELECT(2); busybox does not support domain sockets"
	else
		ls $tmp/file2 | entr -rz nc -l -U $tmp/nc.s >> $tmp/exec.out &
		bgpid=$! ; zz
		echo "123" | nc -NU $tmp/nc.s 2> /dev/null || {
			echo "123" | nc -U $tmp/nc.s
		} ; zz
		echo 456 >> $tmp/file2 ; zz
		wait $bgpid; assert "$?" "0"
		assert "$(cat $tmp/exec.out)" "123"
	fi

try "exec a command in non-intertive mode"
	setup
	ls $tmp/file* | entr tty >$tmp/exec.out &
	bgpid=$! ; zz
	kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" "not a tty"

try "exec a command as a background task and ensure stdin is closed"
	setup
	ls $tmp/file* | entr -r sh -c 'test -t 0; echo $?; kill $$' >$tmp/exec.out &
	bgpid=$! ; zz
	kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" "1"

try "exec a command as a background task, and verify that read from stdin doesn't complain"
	setup
	ls $tmp/file* | entr -r sh -c 'read X' 2>$tmp/exec.err &
	bgpid=$! ; zz
	kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.err)" ""

try "exec single shell utility and exit when a file is added to an implicit watch path"
	setup
	ls $tmp/file* | entr -dp sh -c 'echo ping' >$tmp/exec.out 2>$tmp/exec.err \
	    || true &
	bgpid=$! ; zz
	touch $tmp/newfile
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" "ping"
	assert "$(cat $tmp/exec.err)" "entr: directory altered"

try "exec single shell utility and exit when a subdirectory is added"
	setup
	ls -d $tmp | entr -dp sh -c 'echo ping' >$tmp/exec.out 2>$tmp/exec.err \
	    || true &
	bgpid=$! ; zz
	mkdir $tmp/newdir
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" "ping"
	assert "$(cat $tmp/exec.err)" "entr: directory altered"
	rmdir $tmp/newdir

try "exec single shell utility and exit when a hidden subdirectory is added"
	setup
	ls -d $tmp | entr -ddp sh -c 'echo ping' >$tmp/exec.out 2>$tmp/exec.err \
	    || true &
	bgpid=$! ; zz
	mkdir $tmp/.newdir
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" "ping"
	assert "$(cat $tmp/exec.err)" "entr: directory altered"
	rmdir $tmp/.newdir

try "exec single shell utility and exit when a file is added to a specific path"
	setup
	ls -d $tmp | entr -p sh -c 'echo ping' >$tmp/exec.out 2>$tmp/exec.err \
	    || true &
	bgpid=$! ; zz
	touch $tmp/newfile
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" "ping"
	assert "$(cat $tmp/exec.err)" "entr: directory altered"

try "do nothing when a file not monitored is changed in directory watch mode"
	setup
	ls $tmp/file2 | entr -dp echo "changed" >$tmp/exec.out 2>$tmp/exec.err &
	bgpid=$! ; zz
	echo "123" > $tmp/file1
	kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" ""
	assert "$(cat $tmp/exec.err)" ""

try "exec utility when a file is written by Vim in directory watch mode"
	setup
	ls $tmp/file* | entr -dp echo "changed" >$tmp/exec.out 2>$tmp/exec.err &
	bgpid=$! ; zz
	vim -e -s -u NONE -N \
	    -c ":r!date" \
	    -c ":wq" $tmp/file1 ; zz
	kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" "changed"
	assert "$(cat $tmp/exec.err)" ""

try "exec utility when a file is opened for write and then closed"
	setup
	echo "---" > $tmp/file1
	ls $tmp/file* | entr -p echo "changed" > $tmp/exec.out &
	bgpid=$! ; zz
	: > $tmp/file1 ; zz
	kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	if [ $(uname | grep -E 'Darwin|FreeBSD|DragonFly') ]; then
		skip "NOTE_TRUNCATE not supported"
	else
		assert "$(cat $tmp/exec.out)" "changed"
	fi

try "exec single utility when an entire stash of files is reverted"
	if [ ! -d /usr/include ]; then
		skip "Operating system does not include files in a standard location"
	else
		setup
		cp /usr/include/*.h $tmp/
		cd $tmp
		git init -q
		git config --local user.email entr.test@example.com
		git add *.h
		git commit -m "initial checkin" -q
		for f in `ls *.h | head`; do
			chmod 644 $f
			echo "" >> $f
		done
		cd - > /dev/null ; zz
		ls $tmp/*.h | entr -p echo "changed" > $tmp/exec.out &
		bgpid=$! ; zz
		cd $tmp
		git checkout *.h -q
		cd - > /dev/null ; zz
		kill -INT $bgpid
		wait $bgpid; assert "$?" "0"
		rm -rf $tmp/.git
		assert "$(cat $tmp/exec.out)" "changed"
	fi

try "exec utility when a file is written by Vim"
	setup
	ls $tmp/file* | entr -p echo "changed" > $tmp/exec.out &
	bgpid=$! ; zz
	vim -e -s -u NONE -N \
	    -c ":r!date" \
	    -c ":wq" $tmp/file1 ; zz
	kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" "changed"

try "exec shell utility when a file is written by Vim with 'backup'"
	setup
	ls $tmp/file* | entr -p echo "changed" > $tmp/exec.out &
	bgpid=$! ; zz
	vim -e -s -u NONE -N \
	    -c ":set backup" \
	    -c ":r!date" \
	    -c ":wq" $tmp/file1 ; zz
	kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" "changed"

try "exec shell utility when a file is written by Vim with 'nowritebackup'"
	setup
	ls $tmp/file* | entr -p echo "changed" > $tmp/exec.out &
	bgpid=$! ; zz
	vim -e -s -u NONE -N \
	    -c ":set nowritebackup" \
	    -c ":r!date" \
	    -c ":wq" $tmp/file1 ; zz
	kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" "changed"

try "restart a server when a file is modified"
	setup
	echo "started." > $tmp/file1
	ls $tmp/file2 | entr -r tail -f $tmp/file1 2> /dev/null > $tmp/exec.out &
	bgpid=$! ; zz
	assert "$(cat $tmp/exec.out)" "started."
	echo 456 >> $tmp/file2 ; zz
	kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" "$(printf 'started.\nstarted.')"

try "ensure that all shell subprocesses are terminated in restart mode"
	setup
	cat <<-SCRIPT > $tmp/go.sh
	#!/bin/sh
	trap 'echo "caught signal"; exit' TERM
	echo "running"; sleep 10
	SCRIPT
	chmod +x $tmp/go.sh
	ls $tmp/file2 | entr -r sh -c "$tmp/go.sh" 2> /dev/null > $tmp/exec.out &
	bgpid=$! ; zz
	kill -INT $bgpid ; zz
	assert "$(cat $tmp/exec.out)" "$(printf 'running\ncaught signal')"

try "ensure that all shell subprocesses are terminated when terminal is closed"
	setup
	cat <<-SCRIPT > $tmp/go.sh
	#!/bin/sh
	trap 'echo "caught signal"; exit' TERM
	echo "running"; sleep 10
	SCRIPT
	chmod +x $tmp/go.sh
	ls $tmp/file2 | entr -r sh -c "$tmp/go.sh" 2> /dev/null > $tmp/exec.out &
	bgpid=$! ; zz
	kill -HUP $bgpid ; zz
	assert "$(cat $tmp/exec.out)" "$(printf 'running\ncaught signal')"

try "exit with no action when restart and dirwatch flags are combined"
	setup
	echo "started." > $tmp/file1
	ls $tmp/file* | entr -rd tail -f $tmp/file1 2> /dev/null > $tmp/exec.out &
	bgpid=$! ; zz
	assert "$(cat $tmp/exec.out)" "started."
	touch $tmp/newfile
	kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" "$(printf 'started.')"

try "exec single shell utility when two files change simultaneously"
	setup
	ln $tmp/file1 $tmp/file3
	ls $tmp/file* | entr -p sh -c 'echo ping' > $tmp/exec.out &
	bgpid=$! ; zz
	echo 456 >> $tmp/file1 ; zz
	kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" "ping"

try "exec single shell utility on startup and when a file is changed"
	setup
	ls $tmp/file* | entr sh -c 'printf ping' > $tmp/exec.out &
	bgpid=$! ; zz
	echo 456 >> $tmp/file1 ; zz
	kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" "pingping"

try "exec a command if a file is made executable"
	setup
	ls $tmp/file* | entr -p echo /_ > $tmp/exec.out &
	bgpid=$! ; zz
	chmod +x $tmp/file2 ; zz
	kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" "$tmp/file2"

try "ensure watches operate on a running executable"
	setup
	cp /bin/sleep $tmp/
	ls $tmp/sleep | entr -rs "echo 'vroom'; $tmp/sleep 30" \
	    > $tmp/exec.out 2> /dev/null &
	bgpid=$! ; zz
	cp -f /bin/sleep $tmp/ ; zz
	kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	rm -f $tmp/sleep
	assert "$(cat $tmp/exec.out)" "$(printf 'vroom\nvroom\n')"

try "exec a command using the first file to change"
	setup
	ls $tmp/file* | entr -p cat /_ > $tmp/exec.out &
	bgpid=$! ; zz
	echo 456 > $tmp/file1 ; zz
	kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" "456"

try "exec single shell utility using utility substitution"
	setup
	ls $tmp/file1 $tmp/file2 | entr -p file /_ > $tmp/exec.out &
	bgpid=$! ; zz
	echo 456 >> $tmp/file2; zz
	kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" "$tmp/file2: ASCII text"

try "watch and exec a program that is overwritten"
	setup
	touch $tmp/script; chmod 755 $tmp/script
	echo $tmp/script | entr -p $tmp/script $tmp/file1 > $tmp/exec.out &
	bgpid=$! ; zz
	cat > $tmp/script <<-EOF
	#!/bin/sh
	echo vroom
	EOF
	zz ; kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" "vroom"

try "exec an interactive utility when a file changes"
	setup
	if ! test -t 0 ; then
		skip "A TTY is not available"
	else
		ls $tmp/file* | entr_tty -p sh -c 'tty | cut -c1-9' 2> /dev/null > $tmp/exec.out &
		bgpid=$! ; zz
		echo 456 >> $tmp/file2 ; zz
		kill -INT $bgpid
		wait $bgpid; assert "$?" "0"
		assert "$(awk '/dev.(tty|pts)/ { print "/dev/tty" }' $tmp/exec.out)" "/dev/tty"
	fi

try "exec a command using shell option"
	setup
	ls $tmp/file* | entr -ps 'file $0; exit 2' >$tmp/exec.out 2>$tmp/exec.err &
	bgpid=$! ; zz
	echo 456 >> $tmp/file2 ; zz
	kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.err)" ""
	assert "$(head -n1 $tmp/exec.out)" "$(printf ${tmp}'/file2: ASCII text')"

try "exec a command as a background task"
	setup
	(ls $tmp/file* | entr -ps 'echo terminating; kill $$' >$tmp/exec.out 2>$tmp/exec.err &)
	zz
	echo 456 >> $tmp/file2 ; zz
	assert "$(cat $tmp/exec.err)" ""
	assert "$(head -n1 $tmp/exec.out)" "terminating"

# extra slow tests that rely on timeouts

try "respond to events that occur while the utility is running"
	setup
	ls $tmp/file* | entr -a sh -c 'echo "vroom"; sleep 0.5' > $tmp/exec.out &
	bgpid=$! ; zz
	echo "123" > $tmp/file1
	sleep 1
	kill -INT $bgpid
	wait $bgpid; assert "$?" "0"
	assert "$(cat $tmp/exec.out)" "$(printf 'vroom\nvroom\n')"

try "ensure that all subprocesses are terminated in restart mode when a file is removed"
	setup
	cat <<-SCRIPT > $tmp/go.sh
	#!/bin/sh
	trap 'echo "caught signal"; exit' TERM
	echo "running"; sleep 10
	SCRIPT
	chmod +x $tmp/go.sh
	ls $tmp/file2 | entr -r sh -c "$tmp/go.sh" 2> /dev/null > $tmp/exec.out &
	bgpid=$! ; zz
	rm $tmp/file2; sleep 2
	pgrep -P $bgpid > /dev/null || assert "$?" "1"
	assert "$(cat $tmp/exec.out)" "$(printf 'running\ncaught signal')"

this="exit 0"
echo
echo "$tests tests PASSED"
