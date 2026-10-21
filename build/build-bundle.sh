#!/bin/bash
# 問題のディレクトリとトポロジーが使うイメージを、ラベルKOCTO-BUNDLEのext4にまとめる。
set -euo pipefail

LAB=${1:?usage: $0 <lab-dir> <output.qcow2>}
OUTPUT=${2:?usage: $0 <lab-dir> <output.qcow2>}

die() {
	echo "error: $*" >&2
	exit 1
}

[[ -f $LAB/topology.clab.yml ]] || die "topology.clab.yml not found in $LAB"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage=$work/stage
mkdir -p "$stage/lab" "$stage/images"
cp -a "$LAB/." "$stage/lab/"

# kindの既定イメージは集めない。imageを書いていないノードは、VM内でpullできずに失敗する。
mapfile -t images < <(yq -r '
	[
		.topology.defaults.image?,
		((.topology.kinds // {}) | .[] | .image?),
		((.topology.groups // {}) | .[] | .image?),
		((.topology.nodes // {}) | .[] | .image?)
	] | map(select(. != null)) | unique | .[]' "$LAB/topology.clab.yml")
missing=$(yq -r '(.topology.nodes // {}) | to_entries[] | select(.value.image == null) | .key' "$LAB/topology.clab.yml")
if [[ -n $missing ]]; then
	echo "warning: nodes without an explicit image are not bundled: $(echo "$missing" | tr '\n' ' ')" >&2
fi

for image in "${images[@]}"; do
	archive=$stage/images/$(echo "$image" | tr '/:@' '___').tar
	# 手元のDockerにあるイメージはビルドする環境のアーキテクチャのことがあるため、
	# レジストリから問題VMと同じamd64を直接取る。
	echo "Fetching $image"
	if ! skopeo copy --quiet --override-os linux --override-arch amd64 \
		"docker://$image" "docker-archive:$archive:$image" 2>"$work/skopeo.log"; then
		# docker importしたものなど、レジストリにないイメージは手元のDockerから取る。
		docker image inspect "$image" >/dev/null 2>&1 || { cat "$work/skopeo.log" >&2; die "image not found: $image"; }
		echo "Saving local image $image"
		docker save --output "$archive" "$image"
	fi
done

# VM側は同じIDのbundleを二度は適用しない。
(cd "$stage" && find lab images -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) >"$stage/manifest.sha256"
sha256sum "$stage/manifest.sha256" | cut -d' ' -f1 >"$stage/bundle.id"

# ext4のメタデータとジャーナルの分を足す。
size=$(du -sm "$stage" | cut -f1)
size=$((size * 12 / 10 + 64))
raw=$work/bundle.raw
truncate -s "${size}M" "$raw"
mkfs.ext4 -q -L KOCTO-BUNDLE -d "$stage" -E root_owner=0:0 "$raw"
qemu-img convert -c -f raw -O qcow2 "$raw" "$OUTPUT.part"
mv "$OUTPUT.part" "$OUTPUT"
echo "Bundle id=$(cat "$stage/bundle.id") images=${#images[@]} size=${size}MiB output=$OUTPUT"
