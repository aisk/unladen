# `make image` builds and tags the image; `make image-push` sends that tag to
# the registry the name points at. The default name is the one this project
# would publish under.
#
#   make image                        → ghcr.io/aisk/unladen:<git describe> and :local
#   make image TAG=0.1.0              → ghcr.io/aisk/unladen:0.1.0
#   make image IMAGE=localhost/unladen TAG=dev
#   make image-push TAG=0.1.0

ENGINE ?= podman
IMAGE ?= ghcr.io/aisk/unladen
VERSION ?= $(shell git describe --tags --always --dirty)
TAG ?= $(VERSION)
REVISION ?= $(shell git rev-parse HEAD)
STAMP ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

.PHONY: image image-push

image:
	$(ENGINE) build \
		--build-arg VERSION=$(VERSION) \
		--build-arg REVISION=$(REVISION) \
		--build-arg STAMP=$(STAMP) \
		-t $(IMAGE):$(TAG) \
		-t $(IMAGE):local \
		.

image-push: image
	$(ENGINE) push $(IMAGE):$(TAG)
