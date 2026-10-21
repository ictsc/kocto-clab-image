#!/bin/bash
# shellcheck disable=SC2154 # failedなどはrun-qemu.shが前に連結するtest/lib.shで定義される。
# トポロジーの配置・変更・削除・再作成と、再起動後に状態が戻ることを確かめる。
# 起動のたびに実行され、2回目の起動で再起動後の状態を見る。
PHASE=/var/lib/kocto-test/phase

ping_n2() {
	docker exec clab-kocto-test-n1 ping -c 3 -W 2 192.0.2.2
}

# 印が残っていれば、ノードは作り直されていない。
put_marker() {
	docker exec clab-kocto-test-n1 sh -c 'echo kept >/root/kocto-marker'
}

has_marker() {
	[[ $(docker exec clab-kocto-test-n1 cat /root/kocto-marker 2>/dev/null) == kept ]]
}

write_topology() {
	local nodes=$1 tmp
	tmp=$(mktemp /opt/kocto/lab/.topology.XXXXXX)
	{
		echo "name: kocto-test"
		echo "topology:"
		echo "  nodes:"
		for i in $(seq 1 "$nodes"); do
			echo "    n$i: {kind: linux, image: alpine:3.20, exec: [\"ip addr add 192.0.2.$i/24 dev eth1\"]}"
		done
		echo "  links:"
		echo "    - endpoints: [\"n1:eth1\", \"n2:eth1\"]"
	} >"$tmp"
	# エディタの保存と同じくrenameで差し替える。
	mv "$tmp" "$TOPOLOGY"
}

if [[ -f $PHASE ]]; then
	report "START reboot"
	expect_nodes reboot-nodes 2 && check reboot-link ping_n2
	check reboot-keep-state has_marker
	finish
fi

report "START $(. /etc/os-release && echo "$VERSION")"
report "INFO units $(systemctl is-enabled kocto-clab.service kocto-clab-watch.path | tr '\n' ' ')"

write_topology 2
expect_nodes place-deploy 2 && check place-link ping_n2
put_marker

write_topology 3
expect_nodes change-redeploy 3
check change-keep-node has_marker

rm -f "$TOPOLOGY"
expect_nodes delete-destroy 0

write_topology 2
expect_nodes create-deploy 2 && check create-link ping_n2

[[ $failed -eq 0 ]] || finish
put_marker
mkdir -p "$(dirname "$PHASE")"
echo reboot >"$PHASE"
report "INFO rebooting"
systemctl reboot
