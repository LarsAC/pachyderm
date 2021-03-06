#### VARIABLES
# TESTFLAGS: flags for test
# KUBECTLFLAGS: flags for kubectl
# DOCKER_BUILD_FLAGS: flags for 'docker build'
####

RUN= # used by go tests to decide which tests to run (i.e. passed to -run)
# Label it w the go version we bundle in:
export VERSION_ADDITIONAL = -$(shell git log --pretty=format:%H | head -n 1)
LD_FLAGS = -X github.com/pachyderm/pachyderm/src/client/version.AdditionalVersion=$(VERSION_ADDITIONAL)
export GC_FLAGS = "all=-trimpath=${PWD}"
export DOCKER_BUILD_FLAGS

CLUSTER_NAME?=pachyderm
CLUSTER_MACHINE_TYPE?=n1-standard-4
CLUSTER_SIZE?=4

MINIKUBE_MEM=8192 # MB of memory allocated to minikube
MINIKUBE_CPU=4 # Number of CPUs allocated to minikube

ifdef TRAVIS_BUILD_NUMBER
	# Upper bound for travis test timeout
	TIMEOUT = 3600s
else
ifndef TIMEOUT
	# You should be able to specify your own timeout, but by default we'll use the same bound as travis
	TIMEOUT = 3600s
endif
endif

install:
	# GOPATH/bin must be on your PATH to access these binaries:
	go install -ldflags "$(LD_FLAGS)" -gcflags "$(GC_FLAGS)" ./src/server/cmd/pachctl

install-clean:
	@# Need to blow away pachctl binary if its already there
	@rm -f $(GOPATH)/bin/pachctl
	@make install

install-doc:
	go install -gcflags "$(GC_FLAGS)" ./src/server/cmd/pachctl-doc

point-release:
	@make VERSION_ADDITIONAL= release-helper
	@make VERSION_ADDITIONAL= release-pachctl
	@make doc
	@echo "Release completed"

# Run via 'make VERSION_ADDITIONAL=-rc2 release-candidate' to specify a version string
release-candidate:
	@if [ $${VERSION_ADDITIONAL:0:1} != - ]; then \
	  echo "VERSION_ADDITIONAL must start with a '-'"; \
	  exit 1; \
	fi
	@make release-helper
	@make release-pachctl-custom
	@echo "Release completed"

custom-release: release-helper release-pachctl-custom
	@echo 'For brew install, do:'
	@echo "$$ brew install https://raw.githubusercontent.com/pachyderm/homebrew-tap/$(shell $(GOPATH)/bin/pachctl version --client-only)/pachctl@$(shell $(GOPATH)/bin/pachctl version --client-only | cut -f -2 -d\.).rb"
	@echo 'For linux install, do:'
	@echo "$$ curl -o /tmp/pachctl.deb -L https://github.com/pachyderm/pachyderm/releases/download/v$(shell $(GOPATH)/bin/pachctl version --client-only)/pachctl_$(shell $(GOPATH)/bin/pachctl version --client-only)_amd64.deb && sudo dpkg -i /tmp/pachctl.deb"
	# Workaround for https://github.com/laher/goxc/issues/112
	@git push origin :v$(shell $(GOPATH)/bin/pachctl version --client-only)
	@git tag v$(shell $(GOPATH)/bin/pachctl version --client-only)
	@git push origin v$(shell $(GOPATH)/bin/pachctl version --client-only)
	@echo "Release completed"

release-pachctl-custom:
	@# Run pachctl release script w deploy branch name
	@VERSION="$(shell $(GOPATH)/bin/pachctl version --client-only)" ./etc/build/release_pachctl.sh $(shell $(GOPATH)/bin/pachctl version --client-only)

release-pachctl:
	@# Run pachctl release script w deploy branch name
	@VERSION="$(shell $(GOPATH)/bin/pachctl version --client-only)" ./etc/build/release_pachctl.sh

release-helper: release-version docker-build docker-push docker-build-pachctl docker-push-pachctl docker-push-pipeline-build

release-version: install-clean
	@./etc/build/repo_ready_for_release.sh

docker-build: enterprise-code-checkin-test
	DOCKER_BUILDKIT=1 docker build \
		--build-arg GO_VERSION=`cat etc/compile/GO_VERSION` \
		--build-arg LD_FLAGS="$(LD_FLAGS)" \
		$(DOCKER_BUILD_FLAGS) \
		--progress plain -f Dockerfile.pachd -t pachyderm_build .

	docker build $(DOCKER_BUILD_FLAGS) -t pachyderm/pachd etc/pachd
	docker tag pachyderm/pachd pachyderm/pachd:local

	docker build \
		--build-arg GO_VERSION=`cat etc/compile/GO_VERSION` \
		--build-arg LD_FLAGS="$(LD_FLAGS)" \
		$(DOCKER_BUILD_FLAGS) \
		-t pachyderm/worker etc/worker
	docker tag pachyderm/worker pachyderm/worker:local

docker-build-pachctl:
	DOCKER_BUILDKIT=1 docker build \
		--build-arg GO_VERSION=`cat etc/compile/GO_VERSION` \
		--build-arg LD_FLAGS="$(LD_FLAGS)" \
		--build-arg GC_FLAGS="$(GC_FLAGS)" \
		$(DOCKER_BUILD_FLAGS) \
		--progress plain -f Dockerfile.pachctl -t pachyderm/pachctl .

docker-build-pipeline-build:
	cd etc/pipeline-build && make docker-build

docker-build-proto:
	docker build $(DOCKER_BUILD_FLAGS) -t pachyderm_proto etc/proto

docker-build-netcat:
	docker build $(DOCKER_BUILD_FLAGS) -t pachyderm_netcat etc/netcat

docker-build-gpu:
	docker build $(DOCKER_BUILD_FLAGS) -t pachyderm_nvidia_driver_install etc/deploy/gpu
	docker tag pachyderm_nvidia_driver_install pachyderm/nvidia_driver_install

docker-build-kafka:
	docker build -t kafka-demo etc/testing/kafka

docker-build-spout-test:
	docker build -t spout-test etc/testing/spout

docker-push-gpu:
	docker push pachyderm/nvidia_driver_install

docker-push-gpu-dev:
	docker tag pachyderm/nvidia_driver_install pachyderm/nvidia_driver_install:`git rev-list HEAD --max-count=1`
	docker push pachyderm/nvidia_driver_install:`git rev-list HEAD --max-count=1`
	echo pushed pachyderm/nvidia_driver_install:`git rev-list HEAD --max-count=1`

docker-gpu: docker-build-gpu docker-push-gpu

docker-gpu-dev: docker-build-gpu docker-push-gpu-dev

docker-build-test-entrypoint:
	docker build $(DOCKER_BUILD_FLAGS) -t pachyderm_entrypoint etc/testing/entrypoint

check-kubectl:
	@# check that kubectl is installed
	@which kubectl >/dev/null || { \
		echo "error: kubectl not found"; \
		exit 1; \
	}

check-kubectl-connection:
	kubectl $(KUBECTLFLAGS) get all > /dev/null

docker-tag: install
	docker tag pachyderm/pachd pachyderm/pachd:`$(GOPATH)/bin/pachctl version --client-only`
	docker tag pachyderm/worker pachyderm/worker:`$(GOPATH)/bin/pachctl version --client-only`

docker-tag-pachctl: install
	docker tag pachyderm/pachctl pachyderm/pachctl:`$(GOPATH)/bin/pachctl version --client-only`

docker-push: docker-tag
	docker push pachyderm/etcd:v3.3.5
	docker push pachyderm/pachd:`$(GOPATH)/bin/pachctl version --client-only`
	docker push pachyderm/worker:`$(GOPATH)/bin/pachctl version --client-only`

docker-push-pachctl: docker-tag-pachctl
	docker push pachyderm/pachctl:`$(GOPATH)/bin/pachctl version --client-only`

docker-push-pipeline-build:
	cd etc/pipeline-build && make docker-push

launch-kube: check-kubectl
	etc/kube/start-minikube.sh

launch-dev-vm: check-kubectl
	# Making sure minikube isn't still up from a previous run...
	@if minikube ip 2>/dev/null || sudo minikube ip 2>/dev/null; \
	then \
	  echo "minikube is still up. Run 'make clean-launch-kube'"; \
	  exit 1; \
	fi
	etc/kube/start-minikube-vm.sh --cpus=$(MINIKUBE_CPU) --memory=$(MINIKUBE_MEM)

# launch-release-vm is like launch-dev-vm but it doesn't build pachctl locally, and uses the same
# version of pachd associated with the current pachctl (useful if you want to start a VM with a
# point-release version of pachd, instead of whatever's in the current branch)
launch-release-vm:
	# Making sure minikube isn't still up from a previous run...
	@if minikube ip 2>/dev/null || sudo minikube ip 2>/dev/null; \
	then \
	  echo "minikube is still up. Run 'make clean-launch-kube'"; \
	  exit 1; \
	fi
	etc/kube/start-minikube-vm.sh --cpus=$(MINIKUBE_CPU) --memory=$(MINIKUBE_MEM) --tag=v$$(pachctl version --client-only)

clean-launch-kube:
	@# clean up both of the following cases:
	@# make launch-dev-vm - minikube config is owned by $USER
	@# make launch-kube - minikube config is owned by root
	minikube ip 2>/dev/null && minikube delete || true
	sudo minikube ip 2>/dev/null && sudo minikube delete || true
	killall kubectl || true

launch: install check-kubectl
	$(eval STARTTIME := $(shell date +%s))
	pachctl deploy local --dry-run | kubectl $(KUBECTLFLAGS) apply -f -
	# wait for the pachyderm to come up
	until timeout 1s ./etc/kube/check_ready.sh app=pachd; do sleep 1; done
	@echo "pachd launch took $$(($$(date +%s) - $(STARTTIME))) seconds"

launch-dev: check-kubectl check-kubectl-connection install
	$(eval STARTTIME := $(shell date +%s))
	pachctl deploy local --no-guaranteed -d --dry-run $(LAUNCH_DEV_ARGS) | kubectl $(KUBECTLFLAGS) apply -f -
	# wait for the pachyderm to come up
	until timeout 1s ./etc/kube/check_ready.sh app=pachd; do sleep 1; done
	@echo "pachd launch took $$(($$(date +%s) - $(STARTTIME))) seconds"

clean-launch: check-kubectl install
	yes | pachctl undeploy

clean-launch-dev: check-kubectl install
	yes | pachctl undeploy

full-clean-launch: check-kubectl
	kubectl $(KUBECTLFLAGS) delete --ignore-not-found job -l suite=pachyderm
	kubectl $(KUBECTLFLAGS) delete --ignore-not-found all -l suite=pachyderm
	kubectl $(KUBECTLFLAGS) delete --ignore-not-found serviceaccount -l suite=pachyderm
	kubectl $(KUBECTLFLAGS) delete --ignore-not-found secret -l suite=pachyderm

test-proto-static:
	./etc/proto/test_no_changes.sh || echo "Protos need to be recompiled; run 'DOCKER_BUILD_FLAGS=--no-cache make proto'."

test-deploy-manifests: install
	./etc/testing/deploy-manifests/validate.sh

regenerate-test-deploy-manifests: install
	./etc/testing/deploy-manifests/validate.sh --regenerate

proto: docker-build-proto
	./etc/proto/build.sh

# Run all the tests. Note! This is no longer the test entrypoint for travis
test: clean-launch-dev launch-dev lint enterprise-code-checkin-test docker-build test-pfs-server test-cmds test-libs test-vault test-auth test-enterprise test-worker test-admin test-pps

enterprise-code-checkin-test:
	@which ag || { printf "'ag' not found. Run:\n  sudo apt-get install -y silversearcher-ag\n  brew install the_silver_searcher\nto install it\n\n"; exit 1; }
	# Check if our test activation code is anywhere in the repo
	@echo "Files containing test Pachyderm Enterprise activation token:"; \
	if ag --ignore=Makefile -p .gitignore 'RM2o1Qit6YlZhS1RGdXVac'; \
	then \
	  $$( which echo ) -e "\n*** It looks like Pachyderm Engineering's test activation code may be in this repo. Please remove it before committing! ***\n"; \
	  false; \
	fi

test-pfs-server:
	./etc/testing/pfs_server.sh $(TIMEOUT)

test-pfs-storage:
	go test  -count=1 ./src/server/pkg/storage/chunk -timeout $(TIMEOUT)
	go test  -count=1 ./src/server/pkg/storage/fileset/index -timeout $(TIMEOUT)
	go test  -count=1 ./src/server/pkg/storage/fileset -timeout $(TIMEOUT)

test-pps: launch-stats docker-build-spout-test docker-build-test-entrypoint
	@# Use the count flag to disable test caching for this test suite.
	PROM_PORT=$$(kubectl --namespace=monitoring get svc/prometheus -o json | jq -r .spec.ports[0].nodePort) \
	  go test -v -count=1 ./src/server -parallel 1 -timeout $(TIMEOUT) $(RUN)

test-cmds:
	go install -v ./src/testing/match
	CGOENABLED=0 go test -v -count=1 ./src/server/cmd/pachctl/cmd
	go test -v -count=1 ./src/server/pkg/deploy/cmds -timeout $(TIMEOUT)
	go test -v -count=1 ./src/server/pfs/cmds -timeout $(TIMEOUT)
	go test -v -count=1 ./src/server/pps/cmds -timeout $(TIMEOUT)
	go test -v -count=1 ./src/server/config -timeout $(TIMEOUT)
	@# TODO(msteffen) does this test leave auth active? If so it must run last
	go test -v -count=1 ./src/server/auth/cmds -timeout $(TIMEOUT)

test-transaction:
	go test -count=1 ./src/server/transaction/server/testing -timeout $(TIMEOUT)

test-client:
	go test -count=1 -cover $$(go list ./src/client/...)

test-libs:
	go test -count=1 ./src/client/pkg/grpcutil -timeout $(TIMEOUT)
	go test -count=1 ./src/server/pkg/collection -timeout $(TIMEOUT) -vet=off
	go test -count=1 ./src/server/pkg/hashtree -timeout $(TIMEOUT)
	go test -count=1 ./src/server/pkg/cert -timeout $(TIMEOUT)
	go test -count=1 ./src/server/pkg/localcache -timeout $(TIMEOUT)
	go test -count=1 ./src/server/pkg/work -timeout $(TIMEOUT)

test-vault:
	kill $$(cat /tmp/vault.pid) || true
	./src/plugin/vault/etc/start-vault.sh
	./src/plugin/vault/etc/pach-auth.sh --activate
	./src/plugin/vault/etc/setup-vault.sh
	go test -v -count=1 ./src/plugin/vault -timeout $(TIMEOUT)
	./src/plugin/vault/etc/pach-auth.sh --delete-all

test-s3gateway-conformance:
	@if [ -z $$CONFORMANCE_SCRIPT_PATH ]; then \
	  echo "Missing environment variable 'CONFORMANCE_SCRIPT_PATH'"; \
	  exit 1; \
	fi
	$(CONFORMANCE_SCRIPT_PATH) --s3tests-config=etc/testing/s3gateway/s3tests.conf --ignore-config=etc/testing/s3gateway/ignore.conf --runs-dir=etc/testing/s3gateway/runs

test-s3gateway-integration:
	@if [ -z $$INTEGRATION_SCRIPT_PATH ]; then \
	  echo "Missing environment variable 'INTEGRATION_SCRIPT_PATH'"; \
	  exit 1; \
	fi
	$(INTEGRATION_SCRIPT_PATH) http://localhost:30600 --access-key=none --secret-key=none

test-s3gateway-unit:
	go test -v -count=1 ./src/server/pfs/s3 -timeout $(TIMEOUT)

test-fuse:
	CGOENABLED=0 go test -count=1 -cover $$(go list ./src/server/... | grep '/src/server/pfs/fuse')

test-local:
	CGOENABLED=0 go test -count=1 -cover -short $$(go list ./src/server/... | grep -v '/src/server/pfs/fuse') -timeout $(TIMEOUT)

test-auth:
	yes | pachctl delete all
	go test -v -count=1 ./src/server/auth/server/testing -timeout $(TIMEOUT) $(RUN)

test-admin:
	go test -v -count=1 ./src/server/admin/server -timeout $(TIMEOUT)

test-enterprise:
	go test -v -count=1 ./src/server/enterprise/server -timeout $(TIMEOUT)

test-tls:
	./etc/testing/test_tls.sh

test-worker: launch-stats test-worker-helper

test-worker-helper:
	PROM_PORT=$$(kubectl --namespace=monitoring get svc/prometheus -o json | jq -r .spec.ports[0].nodePort) \
	  go test -v -count=1 ./src/server/worker/ -timeout $(TIMEOUT)

clean: clean-launch clean-launch-kube

doc-custom: install-doc release-version
	./etc/build/doc.sh

doc:
	@make VERSION_ADDITIONAL= doc-custom

dash-compatibility:
	./etc/build/dash_compatibility.sh

clean-launch-kafka:
	kubectl delete -f etc/kubernetes-kafka -R

launch-kafka:
	kubectl apply -f etc/kubernetes-kafka -R
	until timeout 10s ./etc/kube/check_ready.sh app=kafka kafka; do sleep 10; done

clean-launch-stats:
	kubectl delete --filename etc/kubernetes-prometheus -R

launch-stats:
	kubectl apply --filename etc/kubernetes-prometheus -R

clean-launch-monitoring:
	kubectl delete --ignore-not-found -f ./etc/plugin/monitoring

launch-monitoring:
	kubectl create -f ./etc/plugin/monitoring
	@echo "Waiting for services to spin up ..."
	until timeout 5s ./etc/kube/check_ready.sh k8s-app=heapster kube-system; do sleep 5; done
	until timeout 5s ./etc/kube/check_ready.sh k8s-app=influxdb kube-system; do sleep 5; done
	until timeout 5s ./etc/kube/check_ready.sh k8s-app=grafana kube-system; do sleep 5; done
	@echo "All services up. Now port forwarding grafana to localhost:3000"
	kubectl --namespace=kube-system port-forward `kubectl --namespace=kube-system get pods -l k8s-app=grafana -o json | jq '.items[0].metadata.name' -r` 3000:3000 &

clean-launch-logging: check-kubectl check-kubectl-connection
	git submodule update --init
	cd etc/plugin/logging && ./undeploy.sh

launch-logging: check-kubectl check-kubectl-connection
	@# Creates Fluentd / Elasticsearch / Kibana services for logging under --namespace=monitoring
	git submodule update --init
	cd etc/plugin/logging && ./deploy.sh
	kubectl --namespace=monitoring port-forward `kubectl --namespace=monitoring get pods -l k8s-app=kibana-logging -o json | jq '.items[0].metadata.name' -r` 35601:5601 &

launch-loki:
	helm repo add loki https://grafana.github.io/loki/charts
	helm repo update
	helm upgrade --install loki loki/loki-stack
	until timeout 1s ./etc/kube/check_ready.sh release=loki; do sleep 1; done

clean-launch-loki:
	helm uninstall loki

logs: check-kubectl
	kubectl $(KUBECTLFLAGS) get pod -l app=pachd | sed '1d' | cut -f1 -d ' ' | xargs -n 1 -I pod sh -c 'echo pod && kubectl $(KUBECTLFLAGS) logs pod'

follow-logs: check-kubectl
	kubectl $(KUBECTLFLAGS) get pod -l app=pachd | sed '1d' | cut -f1 -d ' ' | xargs -n 1 -I pod sh -c 'echo pod && kubectl $(KUBECTLFLAGS) logs -f pod'

google-cluster-manifest:
	@pachctl deploy --dry-run google $(BUCKET_NAME) $(STORAGE_NAME) $(STORAGE_SIZE)

google-cluster:
	gcloud container clusters create $(CLUSTER_NAME) --scopes storage-rw --machine-type $(CLUSTER_MACHINE_TYPE) --num-nodes $(CLUSTER_SIZE)
	gcloud config set container/cluster $(CLUSTER_NAME)
	gcloud container clusters get-credentials $(CLUSTER_NAME)
	gcloud components install kubectl
	-gcloud compute firewall-rules create pachd --allow=tcp:30650
	gsutil mb gs://$(BUCKET_NAME) # for PFS
	gcloud compute disks create --size=$(STORAGE_SIZE)GB $(STORAGE_NAME) # for PPS

clean-google-cluster:
	gcloud container clusters delete $(CLUSTER_NAME)
	gcloud compute firewall-rules delete pachd
	gsutil -m rm -r gs://$(BUCKET_NAME)
	gcloud compute disks delete $(STORAGE_NAME)

amazon-cluster-manifest: install
	@pachctl deploy --dry-run amazon $(BUCKET_NAME) $(AWS_ID) $(AWS_KEY) $(AWS_TOKEN) $(AWS_REGION) $(STORAGE_NAME) $(STORAGE_SIZE)

amazon-cluster:
	aws s3api create-bucket --bucket $(BUCKET_NAME) --region $(AWS_REGION)
	aws ec2 create-volume --size $(STORAGE_SIZE) --region $(AWS_REGION) --availability-zone $(AWS_AVAILABILITY_ZONE) --volume-type gp2

amazon-clean-cluster:
	aws s3api delete-bucket --bucket $(BUCKET_NAME) --region $(AWS_REGION)
	aws ec2 detach-volume --force --volume-id $(STORAGE_NAME)
	sleep 20
	aws ec2 delete-volume --volume-id $(STORAGE_NAME)

amazon-clean-launch: clean-launch
	kubectl $(KUBECTLFLAGS) delete --ignore-not-found secrets amazon-secret

amazon-clean:
	@while :; \
        do if echo "The following script will delete your AWS bucket and volume. The action cannot be undone. Do you want to proceed? (Y/n)";read REPLY; then \
        case $$REPLY in Y|y) make amazon-clean-launch;make amazon-clean-cluster;break;; \
	N|n) echo "The amazon clean process has been cancelled by user!";break;; \
	*) echo "input parameter error, please input again ";continue;;esac; \
        fi;done;

microsoft-cluster-manifest:
	@pachctl deploy --dry-run microsoft $(CONTAINER_NAME) $(AZURE_STORAGE_NAME) $(AZURE_STORAGE_KEY) $(VHD_URI) $(STORAGE_SIZE)

microsoft-cluster:
	azure group create --name $(AZURE_RESOURCE_GROUP) --location $(AZURE_LOCATION)
	azure storage account create $(AZURE_STORAGE_NAME) --location $(AZURE_LOCATION) --resource-group $(AZURE_RESOURCE_GROUP) --sku-name LRS --kind Storage

clean-microsoft-cluster:
	azure group delete $(AZURE_RESOURCE_GROUP) -q

lint:
	etc/testing/lint.sh

spellcheck:
	@mdspell doc/*.md doc/**/*.md *.md --en-us --ignore-numbers --ignore-acronyms --report --no-suggestions

goxc-generate-local:
	@if [ -z $$GITHUB_OAUTH_TOKEN ]; then \
	  echo "Missing token. Please run via: 'make GITHUB_OAUTH_TOKEN=12345 goxc-generate-local'"; \
	  exit 1; \
	fi
	goxc -wlc default publish-github -apikey=$(GITHUB_OAUTH_TOKEN)

goxc-release:
	@if [ -z $$VERSION ]; then \
	  @echo "Missing version. Please run via: 'make VERSION=v1.2.3-4567 VERSION_ADDITIONAL=4567 goxc-release'"; \
	  @exit 1; \
	fi
	sed 's/%%VERSION_ADDITIONAL%%/$(VERSION_ADDITIONAL)/' .goxc.json.template > .goxc.json
	goxc -pv="$(VERSION)" -build-gcflags="$(GC_FLAGS)" -wd=./src/server/cmd/pachctl

goxc-build:
	sed 's/%%VERSION_ADDITIONAL%%/$(VERSION_ADDITIONAL)/' .goxc.json.template > .goxc.json
	goxc -build-gcflags="$(GC_FLAGS)" -tasks=xc -wd=./src/server/cmd/pachctl

.PHONY: \
	install \
	install-clean \
	install-doc \
	point-release \
	release-candidate \
	custom-release \
	release-pachctl-custom \
	release-pachctl \
	release-helper \
	release-version \
	docker-build \
	docker-build-pachctl \
	docker-build-pipeline-build \
	docker-build-proto \
	docker-build-netcat \
	docker-build-gpu \
	docker-build-spout-test \
	docker-push-gpu \
	docker-push-gpu-dev \
	docker-gpu \
	docker-gpu-dev \
	docker-build-test-entrypoint \
	check-kubectl \
	check-kubectl-connection \
	docker-tag \
	docker-tag-pachctl \
	docker-push \
	docker-push-pachctl \
	docker-push-pipeline-build \
	launch-kube \
	launch-dev-vm \
	launch-release-vm \
	clean-launch-kube \
	launch \
	launch-dev \
	clean-launch \
	clean-launch-dev \
	full-clean-launch \
	test-proto-static \
	test-deploy-manifests \
	regenerate-test-deploy-manifests \
	proto \
	test \
	enterprise-code-checkin-test \
	test-pfs-server \
	test-pfs-storage \
	test-pps \
	test-cmds \
	test-transaction \
	test-client \
	test-libs \
	test-vault \
	test-s3gateway-conformance \
	test-s3gateway-integration \
	test-s3gateway-unit \
	test-fuse \
	test-local \
	test-auth \
	test-admin \
	test-enterprise \
	test-tls \
	test-worker \
	test-worker-helper \
	clean \
	doc-custom \
	doc \
	clean-launch-kafka \
	launch-kafka \
	clean-launch-stats \
	launch-stats \
	clean-launch-monitoring \
	launch-monitoring \
	clean-launch-logging \
	launch-logging \
	logs \
	follow-logs \
	google-cluster-manifest \
	google-cluster \
	clean-google-cluster \
	amazon-cluster-manifest \
	amazon-cluster \
	amazon-clean-cluster \
	amazon-clean-launch \
	amazon-clean \
	microsoft-cluster-manifest \
	microsoft-cluster \
	clean-microsoft-cluster \
	lint \
	spellcheck \
	goxc-generate-local \
	goxc-release \
	goxc-build
