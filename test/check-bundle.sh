#!/bin/bash
# shellcheck disable=SC2154 # failedなどはrun-qemu.shが前に連結するtest/lib.shで定義される。
# bundleディスクだけでdeployできることと、同じbundleを二度適用しないことを確かめる。
report "INFO default-route=[$(ip route show default)]"
expect_nodes bundle-nodes 2
check bundle-image docker image inspect alpine:3.20
check bundle-link docker exec clab-kocto-bundle-n1 ping -c 3 -W 2 192.0.2.2
check bundle-files sh -c '[ "$(docker exec clab-kocto-bundle-n1 cat /kocto/hello.txt)" = "hello from bundle" ]'
check bundle-applied test -s /var/lib/kocto-bundle/applied-id

echo changed-in-vm >/opt/kocto/lab/configs/hello.txt
since=$(date '+%Y-%m-%d %H:%M:%S')
systemctl start kocto-bundle.service
check bundle-skip-applied sh -c "journalctl -u kocto-bundle.service --since '$since' -o cat | grep -q 'Bundle already applied'"
check bundle-keep-changes sh -c '[ "$(cat /opt/kocto/lab/configs/hello.txt)" = changed-in-vm ]'
finish
