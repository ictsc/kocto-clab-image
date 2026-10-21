#!/bin/bash
# shellcheck disable=SC2154 # failedなどはrun-qemu.shが前に連結するtest/lib.shで定義される。
# userdataもNICもないVMが、ネットワーク待ちで遅れずにrunningまで起動することを確かめる。
state=$(systemctl is-system-running --wait)
report "INFO state=$state units $(systemctl is-active kocto-clab.service kocto-clab-watch.path | tr '\n' ' ')"
check boot-running test "$state" = running
check boot-units systemctl is-active --quiet kocto-clab.service kocto-clab-watch.path
[[ $failed -eq 0 ]] || systemctl --failed --no-pager
finish
