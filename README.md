# kocto-clab-image

ictsc-kocto の問題VM向けに、Flatcar Container Linux へ containerlab を組み込んだ KubeVirt containerDisk を作る。
VM内の `/opt/kocto/lab/topology.clab.yml` にトポロジーを置くと、containerlab が自動でdeployする。

## 動作

| 契機 | 動作 |
| --- | --- |
| トポロジーの作成・変更 | 差分を適用する。変更していないノードは作り直さない |
| トポロジーの削除 | そのファイルからdeployしたlabを `destroy` する |
| VMの再起動 | ノードをそのまま起動し直し、リンクと `exec` を戻す。ノード内の設定やファイルは残る |

- トポロジー以外のファイル（startup-configやbind対象）を変えただけでは再deployしない。`touch /opt/kocto/lab/topology.clab.yml` で再実行する。
- ログは `journalctl -u kocto-clab -u kocto-clab-reload -u kocto-bundle` で確認できる。

## bundleディスク

問題VMにはネットワークがなく、VMの中でイメージをpullできない。トポロジー、関連ファイル、コンテナイメージをbundleディスクにまとめ、2本目のディスクとして付ける。

```sh
make bundle LAB=path/to/problem   # out/bundle.qcow2 を作る
```

- `LAB` には `topology.clab.yml` と関連ファイルを置く。ノードの `image:` は明示する（kindの既定イメージはbundleに入らない）。
- VMはラベル `KOCTO-BUNDLE` のディスクを見つけると、イメージを `docker load` し、ファイルを `/opt/kocto/lab/` に置く。最後にトポロジーを置くので、そのままdeployされる。
- 同じ内容のbundleは二度適用しない。cloneしたVMや再起動後に、VM内で変えたファイルを上書きしないため。
- ictsc-kocto のcontrollerは、今のところbundleディスクを付けられない。

## 前提と制約

- `machine.disk` は `14Gi` 以上にする。Docker用に使える領域は「ディスクの大きさ − 約6.6GiB」なので、使うイメージの展開後の合計に余裕を足して決める。
- 既定のビルドは、`virtctl console` から入れるようにttyS0で `core` を自動ログインさせる。`make disk KOCTO_AUTOLOGIN=0` で無効にできる。
- ベースはFlatcarの **QEMU版** を使う。KubeVirt版は、userdataのないVMでは初回起動が進まない。
- 自動更新は止めている。更新は `versions.env` を上げて作り直す。

## ビルドと試験

Dockerがあればビルドできる。変更したら手元で試験を回してからmainに入れる。KVMがない環境（macOSなど）では試験がTCGで動くため、1回に10分以上かかる。

```sh
make disk              # out/flatcar-clab.qcow2 を作る
make test              # 配置・変更・削除・再作成・再起動を確認する
make test-no-ignition  # userdataもNICもなしで起動できることを確認する
make test-bundle       # bundleだけでdeployできることを確認する
make container-disk    # ローカルにcontainerDiskイメージを作る（pushしない）
```

`make disk` は、`versions.env` で固定したFlatcarとcontainerlabを署名・sha256で検証し、ROOTパーティションへ `rootfs/` と containerlab を書き込む。特権コンテナやloopデバイスは使わない。

## 公開

GitHub Actionsは、pull requestではビルドだけを行い、`main` へのpushでビルドしたイメージを `ghcr.io/ictsc/kocto-clab-image:<commit SHA>` としてpushする。試験は、Actionsの画面から手動で実行し、`test` を選んだときだけ回る。

## Problemでの使い方

```yaml
spec:
  machine:
    cpu: 2
    memory: 4Gi
    disk: 14Gi
    image:
      containerDisk: ghcr.io/ictsc/kocto-clab-image:<commit SHA>
```

## 更新

`versions.env` のバージョンとsha256を書き換える。containerlabのsha256はリリースの `checksums.txt` にある。
