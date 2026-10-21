IMG ?= ghcr.io/ictsc/kocto-clab-image:dev
BUILDER ?= kocto-clab-builder:dev
# 0にするとttyS0の自動ログインを含めない。
KOCTO_AUTOLOGIN ?= 1
# make bundleでまとめる問題のディレクトリ（必須）と、out/に作るファイル名。
LAB ?=
BUNDLE_NAME ?= bundle.qcow2

DOCKER_RUN = docker run --rm -v $(CURDIR):/src:ro -v $(CURDIR)/.cache:/cache -v $(CURDIR)/out:/out
# 引数はrun-qemu.shへ渡す環境変数。KVMがなければTCGで動く。
QEMU_TEST = $(DOCKER_RUN) $(if $(wildcard /dev/kvm),--device /dev/kvm) $(1) $(BUILDER) /src/test/run-qemu.sh

.PHONY: help
help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Build

.PHONY: builder
builder: ## Build the tool image used by the other targets
	docker build -t $(BUILDER) build/

.PHONY: disk
disk: builder ## Build out/flatcar-clab.qcow2
	mkdir -p .cache out
	$(DOCKER_RUN) -e KOCTO_AUTOLOGIN=$(KOCTO_AUTOLOGIN) $(BUILDER) /src/build/build.sh

.PHONY: bundle
bundle: builder ## Build a bundle disk in out/ (BUNDLE_NAME) from LAB (topology.clab.yml and its files)
	@test -n "$(LAB)" || { echo "error: LAB is required (make bundle LAB=path/to/problem)" >&2; exit 1; }
	mkdir -p out
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v $(CURDIR):/src:ro -v $(CURDIR)/out:/out \
		-v $(abspath $(LAB)):/lab:ro $(BUILDER) /src/build/build-bundle.sh /lab /out/$(BUNDLE_NAME)

.PHONY: container-disk
container-disk: ## Package out/flatcar-clab.qcow2 as a local containerDisk image
	docker buildx build --platform linux/amd64 --load -t $(IMG) -f Containerfile .

.PHONY: clean
clean: ## Remove build outputs (downloads in .cache are kept)
	rm -rf out

##@ Test

.PHONY: test
test: builder ## Check placing, changing, deleting and re-creating a topology, and a reboot
	$(call QEMU_TEST,-e DELIVERY=ignition -e CHECK=/src/test/check-lifecycle.sh -e LOG=/out/test-serial.log)

.PHONY: test-no-ignition
test-no-ignition: builder ## Check booting without userdata or NIC like a Problem VM
	$(call QEMU_TEST,-e CHECK=/src/test/check-boot.sh -e LOG=/out/test-serial-no-ignition.log)

.PHONY: test-bundle
test-bundle: builder ## Check deploying from a bundle without userdata or NIC
	rm -rf out/bundle-lab
	mkdir -p out/bundle-lab/configs
	echo 'hello from bundle' >out/bundle-lab/configs/hello.txt
	printf '%s\n' \
		'name: kocto-bundle' \
		'topology:' \
		'  nodes:' \
		'    n1: {kind: linux, image: alpine:3.20, binds: ["configs:/kocto:ro"], exec: ["ip addr add 192.0.2.1/24 dev eth1"]}' \
		'    n2: {kind: linux, image: alpine:3.20, exec: ["ip addr add 192.0.2.2/24 dev eth1"]}' \
		'  links:' \
		'    - endpoints: ["n1:eth1", "n2:eth1"]' >out/bundle-lab/topology.clab.yml
	$(MAKE) bundle LAB=out/bundle-lab BUNDLE_NAME=bundle-test.qcow2
	$(call QEMU_TEST,-e BUNDLE=/out/bundle-test.qcow2 -e CHECK=/src/test/check-bundle.sh -e LOG=/out/test-serial-bundle.log)
