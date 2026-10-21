#!/bin/bash
# Flatcarの公式イメージを起動せずにROOTへファイルを書き込む。初回起動の処理（Ignition、machine-id、
# ROOTの拡張など）を問題VMの初回起動まで残すため。
set -euo pipefail

SRC=${SRC:-/src}
CACHE=${CACHE:-/cache}
OUT=${OUT:-/out}
KOCTO_AUTOLOGIN=${KOCTO_AUTOLOGIN:-1}
# shellcheck source=../versions.env
source "$SRC/versions.env"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

die() {
	echo "error: $*" >&2
	exit 1
}

fetch() {
	local url=$1 dest=$2
	if [[ ! -s $dest ]]; then
		echo "Downloading $url"
		curl -fsSL --retry 3 -o "$dest.part" "$url"
		mv "$dest.part" "$dest"
	fi
}

mkdir -p "$CACHE" "$OUT"

echo "Verifying Flatcar $FLATCAR_VERSION"
base=https://$FLATCAR_CHANNEL.release.flatcar-linux.net/amd64-usr/$FLATCAR_VERSION
image=$CACHE/$FLATCAR_VERSION-$FLATCAR_IMAGE
key=$CACHE/Flatcar_Image_Signing_Key.asc
fetch "$base/$FLATCAR_IMAGE" "$image"
fetch "$base/$FLATCAR_IMAGE.sig" "$image.sig"
fetch https://www.flatcar.org/security/image-signing-key/Flatcar_Image_Signing_Key.asc "$key"
export GNUPGHOME=$work/gnupg
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --import "$key" 2>/dev/null
# 取得した鍵ファイル自体は信用せず、VALIDSIGの最後の欄（主鍵）を固定値と照合する。
status=$(gpg --batch --status-fd 1 --verify "$image.sig" "$image" 2>/dev/null || true)
primary=$(awk '$2 == "VALIDSIG" { print $NF }' <<<"$status")
[[ $primary == "$FLATCAR_SIGNING_KEY_FINGERPRINT" ]] ||
	die "Flatcar image signature was not made by $FLATCAR_SIGNING_KEY_FINGERPRINT"

echo "Verifying containerlab $CONTAINERLAB_VERSION"
tarball=$CACHE/containerlab_${CONTAINERLAB_VERSION}_linux_amd64.tar.gz
fetch "https://github.com/srl-labs/containerlab/releases/download/v$CONTAINERLAB_VERSION/containerlab_${CONTAINERLAB_VERSION}_linux_amd64.tar.gz" "$tarball"
echo "$CONTAINERLAB_SHA256  $tarball" | sha256sum --check --quiet -

stage=$work/rootfs
cp -a "$SRC/rootfs" "$stage"
if [[ $KOCTO_AUTOLOGIN == 1 ]]; then
	cp -a "$SRC/autologin/." "$stage/"
fi
# gitは空のディレクトリを残さないため、トポロジーの置き場所はここで作る。
mkdir -p "$stage/opt/bin" "$stage/opt/kocto/lab"
tar -xzf "$tarball" -C "$stage/opt/bin" containerlab
# 配布物はclab_admins向けのsetuid付き。rootのserviceからしか使わないので外す。
chmod 0755 "$stage/opt/bin/containerlab"
mkdir -p "$stage/etc/systemd/system/multi-user.target.wants"
for unit in kocto-clab.service kocto-clab-watch.path; do
	ln -s "../$unit" "$stage/etc/systemd/system/multi-user.target.wants/$unit"
done

echo "Converting image to raw"
disk=$work/disk.raw
qemu-img convert -f qcow2 -O raw "$image" "$disk"
read -r start sector < <(sfdisk --json "$disk" |
	jq -r '.partitiontable as $t | $t.partitions[] | select(.name == "ROOT") | "\(.start) \($t.sectorsize // 512)"')
[[ -n ${start:-} ]] || die "ROOT partition was not found"
# e2fsprogsの?offset=指定で、パーティションを切り出さずに直接編集する。
fs="$disk?offset=$((start * sector))"

exists() {
	debugfs -R "stat $1" "$fs" 2>/dev/null | grep -q '^Inode:'
}

cmds=$work/debugfs.cmds
: >"$cmds"
cd "$stage"
while IFS= read -r -d '' rel; do
	path=/${rel#./}
	[[ $path != *[[:space:]]* ]] || die "path with whitespace is not supported: $path"
	if [[ -d $rel && ! -L $rel ]]; then
		if ! exists "$path"; then
			printf 'mkdir %s\nsif %s mode 040755\nsif %s uid 0\nsif %s gid 0\n' "$path" "$path" "$path" "$path" >>"$cmds"
		fi
		continue
	fi
	if exists "$path"; then
		printf 'rm %s\n' "$path" >>"$cmds"
	fi
	if [[ -L $rel ]]; then
		printf 'symlink %s %s\n' "$path" "$(readlink "$rel")" >>"$cmds"
	else
		mode=$(printf '0%o' $((0100000 | 0$(stat -c %a "$rel"))))
		printf 'write %s %s\nsif %s mode %s\nsif %s uid 0\nsif %s gid 0\n' \
			"$stage/${rel#./}" "$path" "$path" "$mode" "$path" "$path" >>"$cmds"
	fi
done < <(find . -mindepth 1 -print0 | LC_ALL=C sort -z)
cd - >/dev/null

echo "Writing files into ROOT"
# debugfsは個々のコマンドが失敗しても終了コードが変わらないため、出力で判定する。
log=$work/debugfs.log
debugfs -w -f "$cmds" "$fs" >"$log" 2>&1
if grep -E -i 'error|not found|could not|failed|already exists' "$log" >&2; then
	die "debugfs reported errors"
fi
e2fsck -f -n "$fs" >/dev/null || die "ROOT filesystem check failed"

echo "Compressing image"
out=$OUT/flatcar-clab.qcow2
qemu-img convert -c -f raw -O qcow2 "$disk" "$out.part"
mv "$out.part" "$out"
{
	echo "FLATCAR_VERSION=$FLATCAR_VERSION"
	echo "CONTAINERLAB_VERSION=$CONTAINERLAB_VERSION"
	echo "KOCTO_AUTOLOGIN=$KOCTO_AUTOLOGIN"
	echo "SHA256=$(sha256sum "$out" | cut -d' ' -f1)"
} >"$OUT/build-info.env"
cat "$OUT/build-info.env"
