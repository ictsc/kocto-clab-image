# 107はvirt-launcherのqemuユーザー。containerDiskとして直接起動する場合に読めるようにする。
FROM scratch
ADD --chown=107:107 out/flatcar-clab.qcow2 /disk/
