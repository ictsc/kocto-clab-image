#!/bin/bash
# check-*.shの共通部分。run-qemu.shが前に連結してゲストへ送る。
set -u

TOPOLOGY=/opt/kocto/lab/topology.clab.yml
failed=0

report() {
	echo "KOCTO_TEST $*"
}

check() {
	local name=$1
	shift
	if "$@" >/dev/null 2>&1; then
		report "PASS $name"
	else
		report "FAIL $name"
		failed=1
	fi
}

containers() {
	docker ps --quiet --filter "label=clab-topo-file=$TOPOLOGY" | wc -l
}

# イメージのpullやTCGの遅さを見込んで、既定で10分待つ。
expect_nodes() {
	local name=$1 want=$2 tries=${3:-120}
	for _ in $(seq 1 "$tries"); do
		if [[ $(containers) -eq $want ]]; then
			report "PASS $name nodes=$want"
			return 0
		fi
		sleep 5
	done
	report "FAIL $name nodes=$(containers) want=$want"
	failed=1
	return 1
}

finish() {
	if [[ $failed -ne 0 ]]; then
		journalctl --no-pager -b -u kocto-bundle.service -u kocto-clab.service \
			-u kocto-clab-reload.service -u kocto-clab-watch.path | tail -n 60 | sed 's/^/KOCTO_TEST LOG /'
	fi
	report "RESULT $([[ $failed -eq 0 ]] && echo ok || echo ng)"
	systemctl poweroff
	exit 0
}
