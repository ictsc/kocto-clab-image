#!/bin/bash
# out/flatcar-clab.qcow2をQEMUで起動してゲスト内でCHECKを実行し、「KOCTO_TEST RESULT ok」で合否を決める。
#
# 環境変数:
#   CHECK      実行する確認スクリプト（必須）
#   DELIVERY   ignition: Ignitionでunitとして置き、NICを付けて起動する。再起動をまたぐ確認に使う。
#              serial:   問題VMと同じくuserdataもNICもなしで起動し、自動ログインしたシェルへ送る。
#   BUNDLE     2本目のディスクとして読み取り専用で付けるbundle
#   DISK_SIZE  ディスクを広げる大きさ（例: 14G）。空ならイメージの大きさのまま
#   MEMORY, TIMEOUT, LOG
set -euo pipefail

SRC=${SRC:-/src}
OUT=${OUT:-/out}
CHECK=${CHECK:?CHECK is required}
DELIVERY=${DELIVERY:-serial}
BUNDLE=${BUNDLE:-}
DISK=${DISK:-$OUT/flatcar-clab.qcow2}
DISK_SIZE=${DISK_SIZE:-}
MEMORY=${MEMORY:-1400}
TIMEOUT=${TIMEOUT:-3600}
LOG=${LOG:-$OUT/test-serial.log}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 成果物を初回起動済みにしないよう、差分ディスクを重ねる。
# shellcheck disable=SC2086
qemu-img create -q -f qcow2 -F qcow2 -b "$DISK" "$work/disk.qcow2" $DISK_SIZE
cat "$SRC/test/lib.sh" "$CHECK" >"$work/check.sh"

qemu_args=(
	-machine q35 -smp 2 -m "$MEMORY" -display none -serial stdio
	-drive "if=virtio,file=$work/disk.qcow2,format=qcow2"
)
if [[ -w /dev/kvm ]]; then
	accel=kvm
	qemu_args+=(-accel kvm -cpu host)
else
	accel=tcg
	# TCGの変換キャッシュは既定で大きく、メモリの少ないDocker環境ではOOMで落ちるため絞る。
	qemu_args+=(-accel "tcg,thread=multi,tb-size=256" -cpu max)
fi
if [[ -n $BUNDLE ]]; then
	qemu_args+=(-drive "if=virtio,file=$BUNDLE,format=qcow2,readonly=on")
fi

console=/dev/null
case $DELIVERY in
ignition)
	# fw_cfgの名前は、FlatcarとupstreamのIgnitionの両方に合わせる。
	data_url() {
		echo "data:;base64,$(base64 -w0 "$1")"
	}
	jq -n --arg script "$(data_url "$work/check.sh")" '{
		ignition: {version: "3.3.0"},
		storage: {files: [{path: "/opt/kocto-test/check.sh", mode: 493, contents: {source: $script}}]},
		systemd: {units: [{
			name: "kocto-test.service",
			enabled: true,
			contents: "[Unit]\nAfter=kocto-clab.service\n[Service]\nType=oneshot\nExecStart=/opt/kocto-test/check.sh\nStandardOutput=tty\nStandardError=tty\nTTYPath=/dev/ttyS0\n[Install]\nWantedBy=multi-user.target\n"
		}]}
	}' >"$work/config.ign"
	qemu_args+=(
		-fw_cfg "name=opt/org.flatcar-linux/config,file=$work/config.ign"
		-fw_cfg "name=opt/com.coreos/config,file=$work/config.ign"
		-nic "user,model=virtio-net-pci"
	)
	;;
serial)
	qemu_args+=(-nic none)
	console=$work/console
	mkfifo "$console"
	: >"$LOG"
	# エコーされる入力はbase64なので、結果の行と混ざらない。
	(
		until grep -a -q '(automatic login)' "$LOG"; do sleep 2; done
		sleep 5
		echo "echo $(base64 -w0 "$work/check.sh") | base64 -d >/tmp/kocto-check.sh && sudo bash /tmp/kocto-check.sh"
		sleep infinity
	) >"$console" &
	;;
*)
	echo "error: unknown DELIVERY: $DELIVERY" >&2
	exit 2
	;;
esac

echo "Booting with accel=$accel, delivery=$DELIVERY, serial log: $LOG"
timeout "$TIMEOUT" qemu-system-x86_64 "${qemu_args[@]}" <"$console" |
	tee "$LOG" | grep --line-buffered KOCTO_TEST || true

grep -q 'KOCTO_TEST RESULT ok' "$LOG"
