# © Copyright IBM Corporation 2015, 2021
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

ARG BASE_IMAGE=registry.redhat.io/ubi8/ubi-minimal
ARG BASE_TAG=8.4-205
ARG GO_WORKDIR=/opt/app-root/src/go/src/github.com/ibm-messaging/mq-container
ARG MQ_URL="https://public.dhe.ibm.com/ibmdl/export/pub/software/websphere/messaging/mqadv/9.2.3.0-IBM-MQ-Advanced-for-Developers-Non-Install-LinuxX64.tar.gz"
###############################################################################
# Build stage to build Go code
###############################################################################
FROM registry.redhat.io/ubi8/go-toolset:1.15.13-4 as builder
# The URL to download the MQ installer from in tar.gz format
# This assumes an archive containing the MQ Non-Install packages
ARG MQ_URL
ARG IMAGE_REVISION="Not specified"
ARG IMAGE_SOURCE="Not specified"
ARG IMAGE_TAG="Not specified"
ARG GO_WORKDIR
USER 0
COPY install-mq.sh /usr/local/bin/
RUN mkdir /opt/mqm \
  && chmod a+x /usr/local/bin/install-mq.sh \
  && sleep 1 \
  && INSTALL_SDK=1 install-mq.sh \
  && chown -R 1001:root /opt/mqm/*
WORKDIR $GO_WORKDIR/
COPY cmd/ ./cmd
COPY internal/ ./internal
COPY pkg/ ./pkg
COPY vendor/ ./vendor
ENV CGO_CFLAGS="-I/opt/mqm/inc/" \
    CGO_LDFLAGS_ALLOW="-Wl,-rpath.*"
ENV PATH="${PATH}:/opt/mqm/bin"
RUN go build -ldflags "-X \"main.ImageCreated=$(date --iso-8601=seconds)\" -X \"main.ImageRevision=$IMAGE_REVISION\" -X \"main.ImageSource=$IMAGE_SOURCE\" -X \"main.ImageTag=$IMAGE_TAG\"" ./cmd/runmqserver/
RUN go build ./cmd/chkmqready/
RUN go build ./cmd/chkmqhealthy/
RUN go build ./cmd/chkmqstarted/
RUN go build ./cmd/runmqdevserver/
RUN go test -v ./cmd/runmqdevserver/...
RUN go test -v ./cmd/runmqserver/
RUN go test -v ./cmd/chkmqready/
RUN go test -v ./cmd/chkmqhealthy/
RUN go test -v ./cmd/chkmqstarted/
RUN go test -v ./pkg/...
RUN go test -v ./internal/...
RUN go vet ./cmd/... ./internal/...

###############################################################################
# Main build stage, to build MQ image
###############################################################################
FROM $BASE_IMAGE:$BASE_TAG AS mq-server
# The MQ packages to install - see install-mq.sh for default value
ARG MQ_URL
ARG BASE_IMAGE
ARG BASE_TAG
ARG GO_WORKDIR
LABEL summary="IBM MQ Advanced Server"
LABEL description="Simplify, accelerate and facilitate the reliable exchange of data with a security-rich messaging solution — trusted by the world’s most successful enterprises"
LABEL vendor="IBM"
LABEL maintainer="IBM"
LABEL distribution-scope="private"
LABEL authoritative-source-url="https://www.ibm.com/software/passportadvantage/"
LABEL url="https://www.ibm.com/products/mq/advanced"
LABEL io.openshift.tags="mq messaging"
LABEL io.k8s.display-name="IBM MQ Advanced Server"
LABEL io.k8s.description="Simplify, accelerate and facilitate the reliable exchange of data with a security-rich messaging solution — trusted by the world’s most successful enterprises"
LABEL base-image=$BASE_IMAGE
LABEL base-image-release=$BASE_TAG
COPY install-mq.sh /usr/local/bin/
COPY install-mq-server-prereqs.sh /usr/local/bin/
# Install MQ.  To avoid a "text file busy" error here, we sleep before installing.
RUN env \
  && mkdir /opt/mqm \
  && chmod u+x /usr/local/bin/install-*.sh \
  && sleep 1 \
  && install-mq-server-prereqs.sh \
  && install-mq.sh \
  && /opt/mqm/bin/security/amqpamcf \
  && chown -R 1001:root /opt/mqm/*
# Create a directory for runtime data from runmqserver
RUN mkdir -p /run/runmqserver \
  && chown 1001:root /run/runmqserver
COPY --from=builder $GO_WORKDIR/runmqserver /usr/local/bin/
COPY --from=builder $GO_WORKDIR/chkmq* /usr/local/bin/
COPY NOTICES.txt /opt/mqm/licenses/notices-container.txt
COPY ha/native-ha.ini.tpl /etc/mqm/native-ha.ini.tpl
# Copy web XML files
COPY web /etc/mqm/web
COPY etc/mqm/*.tpl /etc/mqm/
RUN chmod ug+x /usr/local/bin/runmqserver \
  && chown 1001:root /usr/local/bin/*mq* \
  && chmod ug+x /usr/local/bin/chkmq* \
  && chown -R 1001:root /etc/mqm/* \
  && install --directory --mode 2775 --owner 1001 --group root /run/runmqserver \
  && touch /run/termination-log \
  && chown 1001:root /run/termination-log \
  && chmod 0660 /run/termination-log \
  && chmod -R g+w /etc/mqm/web
# Always use port 1414 for MQ & 9157 for the metrics
EXPOSE 1414 9157 9443
ENV MQ_OVERRIDE_DATA_PATH=/mnt/mqm/data MQ_OVERRIDE_INSTALLATION_NAME=Installation1 MQ_USER_NAME="mqm" PATH="${PATH}:/opt/mqm/bin"
ENV MQ_GRACE_PERIOD=30
ENV LANG=en_US.UTF-8 AMQ_DIAGNOSTIC_MSG_SEVERITY=1 AMQ_ADDITIONAL_JSON_LOG=1 LOG_FORMAT=basic
# We can run as any UID
USER 1001
ENV MQ_CONNAUTH_USE_HTP=false
ENTRYPOINT ["runmqserver"]

###############################################################################
# Build stage to build C code for custom authorization service (developer-only)
###############################################################################
FROM registry.redhat.io/rhel8/gcc-toolset-9-toolchain as cbuilder
# The URL to download the MQ installer from in tar.gz format
# This assumes an archive containing the MQ Non-Install packages
ARG MQ_URL
USER 0
# Install the Apache Portable Runtime code (used for htpasswd hash checking)
RUN yum -y install apr-devel apr-util-openssl apr-util-devel
# Install MQ client
COPY install-mq.sh /usr/local/bin/
RUN mkdir /opt/mqm \
  && chmod a+x /usr/local/bin/install-mq.sh \
  && sleep 1 \
  && INSTALL_SDK=1 install-mq.sh \
  && chown -R 1001:root /opt/mqm/*
COPY authservice/ /opt/app-root/src/authservice/
WORKDIR /opt/app-root/src/authservice/mqhtpass
RUN make all

###############################################################################
# Add default developer config
###############################################################################
FROM mq-server AS mq-dev-server
ARG BASE_IMAGE
ARG BASE_TAG
ARG GO_WORKDIR
# Enable MQ developer default configuration
ENV MQ_DEV=true
LABEL summary="IBM MQ Advanced for Developers Server"
LABEL description="Simplify, accelerate and facilitate the reliable exchange of data with a security-rich messaging solution — trusted by the world’s most successful enterprises"
LABEL vendor="IBM"
LABEL distribution-scope="private"
LABEL authoritative-source-url="https://www.ibm.com/software/passportadvantage/"
LABEL url="https://www.ibm.com/products/mq/advanced"
LABEL io.openshift.tags="mq messaging"
LABEL io.k8s.display-name="IBM MQ Advanced for Developers Server"
LABEL io.k8s.description="Simplify, accelerate and facilitate the reliable exchange of data with a security-rich messaging solution — trusted by the world’s most successful enterprises"
LABEL base-image=$BASE_IMAGE
LABEL base-image-release=$BASE_TAG
USER 0
COPY --from=cbuilder /opt/app-root/src/authservice/mqhtpass/build/mqhtpass.so /opt/mqm/lib64/
COPY etc/mqm/*.ini /etc/mqm/
COPY etc/mqm/mq.htpasswd /etc/mqm/
RUN chmod 0660 /etc/mqm/mq.htpasswd
COPY incubating/mqadvanced-server-dev/install-extra-packages.sh /usr/local/bin/
RUN chmod u+x /usr/local/bin/install-extra-packages.sh \
  && sleep 1 \
  && install-extra-packages.sh
# Create a directory for runtime data from runmqserver
RUN mkdir -p /run/runmqdevserver \
  && chown 1001:root /run/runmqdevserver
COPY --from=builder $GO_WORKDIR/runmqdevserver /usr/local/bin/
# Copy template files
COPY incubating/mqadvanced-server-dev/*.tpl /etc/mqm/
# Copy web XML files for default developer configuration
COPY incubating/mqadvanced-server-dev/web /etc/mqm/web
RUN chown -R 1001:root /etc/mqm/* \
  && chmod -R g+w /etc/mqm/web \
  && chmod +x /usr/local/bin/runmq* \
  && install --directory --mode 2775 --owner 1001 --group root /run/runmqdevserver
ENV MQ_ENABLE_EMBEDDED_WEB_SERVER=1 MQ_GENERATE_CERTIFICATE_HOSTNAME=localhost
ENV LD_LIBRARY_PATH=/opt/mqm/lib64
ENV MQ_CONNAUTH_USE_HTP=true
ENV MQS_PERMIT_UNKNOWN_ID=true
USER 1001
ENTRYPOINT ["runmqdevserver"]
