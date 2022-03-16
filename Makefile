# SPDX-FileCopyrightText: 2022-present Open Networking Foundation <info@opennetworking.org>
#
# SPDX-License-Identifier: Apache-2.0

# If any command in a pipe has nonzero status, return that status
SHELL = bash -o pipefail

export CGO_ENABLED=1
export GO111MODULE=on

VERSION                     ?= $(shell cat ./VERSION)

KIND_CLUSTER_NAME           ?= kind
DOCKER_REPOSITORY           ?= onosproject/
SUBSCRIBER_DNS_VERSION      ?= latest

## Docker labels. Only set ref and commit date if committed
DOCKER_LABEL_VCS_URL        ?= $(shell git remote get-url $(shell git remote))
DOCKER_LABEL_VCS_REF        = $(shell git rev-parse HEAD)
DOCKER_LABEL_BUILD_DATE     ?= $(shell date -u "+%Y-%m-%dT%H:%M:%SZ")
DOCKER_LABEL_COMMIT_DATE    = $(shell git show -s --format=%cd --date=iso-strict HEAD)

DOCKER_EXTRA_ARGS           ?=
DOCKER_BUILD_ARGS ?= \
        ${DOCKER_EXTRA_ARGS} \
        --build-arg org_label_schema_version="${VERSION}" \
        --build-arg org_label_schema_vcs_url="${DOCKER_LABEL_VCS_URL}" \
        --build-arg org_label_schema_vcs_ref="${DOCKER_LABEL_VCS_REF}" \
        --build-arg org_label_schema_build_date="${DOCKER_LABEL_BUILD_DATE}" \
        --build-arg org_opencord_vcs_commit_date="${DOCKER_LABEL_COMMIT_DATE}" \
        --build-arg org_opencord_vcs_dirty="${DOCKER_LABEL_VCS_DIRTY}"

all: images

images: # @HELP build simulators image
images: subscriber-dns-docker

deps: # @HELP ensure that the required dependencies are in place
	GOPRIVATE="github.com/onosproject/*" go build -v `go list ./... `
	bash -c "diff -u <(echo -n) <(git diff go.mod)"
	bash -c "diff -u <(echo -n) <(git diff go.sum)"

linters: golang-ci # @HELP examines Go source code and reports coding problems
	golangci-lint run --timeout 5m

build-tools: # @HELP install the ONOS build tools if needed
	@if [ ! -d "../build-tools" ]; then cd .. && git clone https://github.com/onosproject/build-tools.git; fi

jenkins-tools: # @HELP installs tooling needed for Jenkins
	cd .. && go get -u github.com/jstemmer/go-junit-report && go get github.com/t-yuki/gocover-cobertura

golang-ci: # @HELP install golang-ci if not present
	golangci-lint --version || curl -sfL https://install.goreleaser.com/github.com/golangci/golangci-lint.sh | sh -s -- -b `go env GOPATH`/bin v1.42.0

license_check: build-tools # @HELP examine and ensure license headers exist
	./../build-tools/licensing/boilerplate.py -v --rootdir=${CURDIR} --boilerplate SPDX-Apache-2.0

# @HELP run various tests
test: unit-test deps license_check linters

# @HELP run init tests
unit-test:
	go test -cover -race `go list github.com/onosproject/subscriber-dns/pkg/...`
	go test -cover -race `go list github.com/onosproject/subscriber-dns/cmd/...`

jenkins-test:  # @HELP run the unit tests and source code validation producing a junit style report for Jenkins
jenkins-test: deps license_check linters jenkins-tools
	TEST_PACKAGES=`go list github.com/onosproject/subscriber-dns/... ` ./../build-tools/build/jenkins/make-unit

subscriber-dns-docker:
	docker build . -f Dockerfile \
	$(DOCKER_BUILD_ARGS) \
	-t ${DOCKER_REPOSITORY}subscriber-dns:${SUBSCRIBER_DNS_VERSION}

kind: # @HELP build Docker images and add them to the currently configured kind cluster
kind: images kind-only

kind-only: # @HELP deploy the image without rebuilding first
kind-only:
	@if [ "`kind get clusters`" = '' ]; then echo "no kind cluster found" && exit 1; fi
	kind load docker-image --name ${KIND_CLUSTER_NAME} ${DOCKER_REPOSITORY}subscriber-dns:${SUBSCRIBER_DNS_VERSION}

publish: # @HELP publish version on github and dockerhub
	./../build-tools/publish-version ${VERSION} onosproject/subscriber-dns

jenkins-publish: build-tools jenkins-tools # @HELP Jenkins calls this to publish artifacts
	./build/bin/push-images
	../build-tools/release-merge-commit

clean: # @HELP remove all the build artifacts
	rm -rf ./build/_output
	rm -rf ./vendor
	rm -rf ./cmd/subdns/subdns

help:
	@grep -E '^.*: *# *@HELP' $(MAKEFILE_LIST) \
    | sort \
    | awk ' \
        BEGIN {FS = ": *# *@HELP"}; \
        {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}; \
    '