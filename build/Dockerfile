FROM debian:trixie-slim

RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		ca-certificates curl gnupg qemu-utils e2fsprogs fdisk jq yq docker-cli skopeo \
		qemu-system-x86 \
	&& rm -rf /var/lib/apt/lists/*
