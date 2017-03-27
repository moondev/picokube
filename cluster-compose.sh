#!/bin/bash
# Copyright 2017 Mirantis
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
 
set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

set -x

out() {
  echo $1 >> out.txt
}

if [ $(uname) = Darwin ]; then
  readlinkf(){ perl -MCwd -e 'print Cwd::abs_path shift' "$1";}
else
  readlinkf(){ readlink -f "$1"; }
fi
DIND_ROOT="$(cd $(dirname "$(readlinkf "${BASH_SOURCE}")"); pwd)"

RUN_ON_BTRFS_ANYWAY="${RUN_ON_BTRFS_ANYWAY:-}"
if [[ ! ${RUN_ON_BTRFS_ANYWAY} ]] && docker info| grep -q '^Storage Driver: btrfs'; then
  echo "ERROR: Docker is using btrfs storage driver which is unsupported by kubeadm-dind-cluster" >&2
  echo "Please refer to the documentation for more info." >&2
  echo "Set RUN_ON_BTRFS_ANYWAY to non-empty string to continue anyway." >&2
  exit 1
fi

# In case of moby linux, -v will not work so we can't
# mount /lib/modules and /boot
is_moby_linux=
if docker info|grep -q '^Kernel Version: .*-moby$'; then
    is_moby_linux=1
fi

EMBEDDED_CONFIG=y;DIND_IMAGE=mirantis/kubeadm-dind-cluster:v1.5

if [[ ! ${EMBEDDED_CONFIG:-} ]]; then
  source "${DIND_ROOT}/config.sh"
fi

DIND_SUBNET="${DIND_SUBNET:-10.192.0.0}"
dind_ip_base="$(echo "${DIND_SUBNET}" | sed 's/\.0$//')"
DIND_IMAGE="${DIND_IMAGE:-}"
BUILD_KUBEADM="${BUILD_KUBEADM:-}"
BUILD_HYPERKUBE="${BUILD_HYPERKUBE:-}"
APISERVER_PORT=${APISERVER_PORT:-8080}
#NUM_NODES=${NUM_NODES:-2}
NUM_NODES=1
LOCAL_KUBECTL_VERSION=${LOCAL_KUBECTL_VERSION:-}
KUBECTL_DIR="${KUBECTL_DIR:-${HOME}/.kubeadm-dind-cluster}"
DASHBOARD_URL="${DASHBOARD_URL:-https://rawgit.com/kubernetes/dashboard/master/src/deploy/kubernetes-dashboard.yaml}"
E2E_REPORT_DIR="${E2E_REPORT_DIR:-}"

if [[ ! ${LOCAL_KUBECTL_VERSION:-} && ${DIND_IMAGE:-} =~ :(v[0-9]+\.[0-9]+)$ ]]; then
  LOCAL_KUBECTL_VERSION="${BASH_REMATCH[1]}"
fi

function dind::need-source {
  if [[ ! -f cluster/kubectl.sh ]]; then
    echo "$0 must be called from the Kubernetes repository root directory" 1>&2
    exit 1
  fi
}

build_tools_dir="build"
use_k8s_source=y
if [[ ! ${BUILD_KUBEADM} && ! ${BUILD_HYPERKUBE} ]]; then
  use_k8s_source=
fi
if [[ ${use_k8s_source} ]]; then
  dind::need-source
  kubectl=cluster/kubectl.sh
  if [[ ! -f ${build_tools_dir}/common.sh ]]; then
    build_tools_dir="build-tools"
  fi
else
  if [[ ! ${LOCAL_KUBECTL_VERSION:-} ]] && ! hash kubectl 2>/dev/null; then
    echo "You need kubectl binary in your PATH to use prebuilt DIND image" 1>&2
    exit 1
  fi
  kubectl=kubectl
fi

busybox_image="busybox:1.26.2"
e2e_base_image="golang:1.7.1"
sys_volume_args=()
build_volume_args=()

function dind::set-build-volume-args {
  if [ ${#build_volume_args[@]} -gt 0 ]; then
    return 0
  fi
  build_container_name=
  if [ -n "${KUBEADM_DIND_LOCAL:-}" ]; then
    build_volume_args=(-v "$PWD:/go/src/k8s.io/kubernetes")
  else
    build_container_name="$(KUBE_ROOT=$PWD &&
                            . ${build_tools_dir}/common.sh &&
                            kube::build::verify_prereqs >&2 &&
                            echo "${KUBE_DATA_CONTAINER_NAME:-${KUBE_BUILD_DATA_CONTAINER_NAME}}")"
    build_volume_args=(--volumes-from "${build_container_name}")
  fi
}

function dind::volume-exists {
  local name="$1"
  if docker volume inspect "${name}" >& /dev/null; then
    return 0
  fi
  return 1
}

function dind::create-volume {
  local name="$1"
  docker volume create --label mirantis.kubeadm_dind_cluster --name "${name}" >/dev/null
}

# We mount /boot and /lib/modules into the container
# below to in case some of the workloads need them.
# This includes virtlet, for instance. Also this may be
# useful in future if we want DIND nodes to pass
# preflight checks.
# Unfortunately we can't do this when using Mac Docker
# (unless a remote docker daemon on Linux is used)
# NB: there's no /boot on recent Mac dockers
function dind::prepare-sys-mounts {
  # if [[ ! ${is_moby_linux} ]]; then
  #   sys_volume_args=()
  #   if [[ -d /boot ]]; then
  #     sys_volume_args+=(-v /boot:/boot)
  #   fi
  #   if [[ -d /lib/modules ]]; then
  #     sys_volume_args+=(-v /lib/modules:/lib/modules)
  #   fi
  #   return 0
  # fi
  if ! dind::volume-exists kubeadm-dind-sys; then
    echo "DRUN"
    dind::step "Saving a copy of docker host's /lib/modules"
    dind::create-volume kubeadm-dind-sys
    # Use a dirty nsenter trick to fool Docker on Mac and grab system
    # /lib/modules into sys.tar file on kubeadm-dind-sys volume.
    local nsenter="nsenter --mount=/proc/1/ns/mnt --"
    docker run \
           --rm \
           --privileged \
           -v kubeadm-dind-sys:/dest \
           --pid=host \
           "${busybox_image}" \
           /bin/sh -c \
           "if ${nsenter} test -d /lib/modules; then ${nsenter} tar -C / -c lib/modules >/dest/sys.tar; fi"
  fi
  sys_volume_args=(-v kubeadm-dind-sys:/dind-sys)
}

tmp_containers=()

function dind::cleanup {
  if [ ${#tmp_containers[@]} -gt 0 ]; then
    for name in "${tmp_containers[@]}"; do
      docker rm -vf "${name}" 2>/dev/null
    done
  fi
}

trap dind::cleanup EXIT

function dind::check-image {
  local name="$1"
  if docker inspect --format 'x' "${name}" >&/dev/null; then
    return 0
  else
    return 1
  fi
}

function dind::make-for-linux {
  local copy="$1"
  shift
  dind::step "Building binaries:" "$*"
  if [ -n "${KUBEADM_DIND_LOCAL:-}" ]; then
    dind::step "+ make WHAT=\"$*\""
    make WHAT="$*"
  elif [ "${copy}" = "y" ]; then
    dind::step "+ ${build_tools_dir}/run.sh make WHAT=\"$*\""
    "${build_tools_dir}/run.sh" make WHAT="$*"
  else
    dind::step "+ KUBE_RUN_COPY_OUTPUT=n ${build_tools_dir}/run.sh make WHAT=\"$*\""
    KUBE_RUN_COPY_OUTPUT=n "${build_tools_dir}/run.sh" make WHAT="$*"
  fi
}

function dind::check-binary {
  local filename="$1"
  local dockerized="_output/dockerized/bin/linux/amd64/${filename}"
  local plain="_output/local/bin/linux/amd64/${filename}"
  dind::set-build-volume-args
  # FIXME: don't hardcode amd64 arch
  if [ -n "${KUBEADM_DIND_LOCAL:-${force_local:-}}" ]; then
    if [ -f "${dockerized}" -o -f "${plain}" ]; then
      return 0
    fi
  elif docker run --rm "${build_volume_args[@]}" \
              "${busybox_image}" \
              test -f "/go/src/k8s.io/kubernetes/${dockerized}" >&/dev/null; then
    return 0
  fi
  return 1
}

function dind::ensure-downloaded-kubectl {
  local kubectl_url
  local kubectl_sha1
  local kubectl_sha1_linux
  local kubectl_sha1_darwin
  local kubectl_link
  local kubectl_os
  local full_kubectl_version

  case "${LOCAL_KUBECTL_VERSION}" in
    v1.4)
      full_kubectl_version=v1.4.9
      kubectl_sha1_linux=5726e8f17d56a5efeb2a644d8e7e2fdd8da8b8fd
      kubectl_sha1_darwin=630fb3e0f4f442178cde0264d4b399291226eb2b
      ;;
    v1.5)
      full_kubectl_version=v1.5.4
      kubectl_sha1_linux=15d8430dc52b1f3772b88bc6a236c8fa58e07c0d
      kubectl_sha1_darwin=5e671ba792567574eea48be4eddd844ba2f07c27
      ;;
    v1.6)
      full_kubectl_version=v1.6.0-beta.3
      kubectl_sha1_linux=894ea988a92568fce3ed290bc4728171b45b11ef
      kubectl_sha1_darwin=ce48630a490d6f3cd7298482e11eaf87f89b4e38
      ;;
    "")
      return 0
      ;;
    *)
      echo "Invalid kubectl version" >&2
      exit 1
  esac

  export PATH="${KUBECTL_DIR}:$PATH"

  if [ $(uname) = Darwin ]; then
    kubectl_sha1="${kubectl_sha1_darwin}"
    kubectl_os=darwin
  else
    kubectl_sha1="${kubectl_sha1_linux}"
    kubectl_os=linuxhttps://github.com/moondev/cluster-compose.git
  fi
  local link_target="kubectl-${full_kubectl_version}"
  local link_name="${KUBECTL_DIR}"/kubectl
  if [[ -h "${link_name}" && "$(readlink "${link_name}")" = "${link_target}" ]]; then
    return 0
  fi

  if [[ ! -f "${link_target}" ]]; then
    mkdir -p "${KUBECTL_DIR}"
    local path="${KUBECTL_DIR}/${link_target}"
    wget -O "${path}" "https://storage.googleapis.com/kubernetes-release/release/${full_kubectl_version}/bin/${kubectl_os}/amd64/kubectl"
    echo "${kubectl_sha1} ${path}" | sha1sum -c
    chmod +x "${path}"
  fi

  ln -fs "${link_target}" "${KUBECTL_DIR}/kubectl"
}

function dind::ensure-kubectl {
  if [[ ! ${use_k8s_source} ]]; then
    # already checked on startup
    dind::ensure-downloaded-kubectl
    return 0
  fi
  if [ $(uname) = Darwin ]; then
    if [ ! -f _output/local/bin/darwin/amd64/kubectl ]; then
      dind::step "Building kubectl"
      dind::step "+ make WHAT=cmd/kubectl"
      make WHAT=cmd/kubectl
    fi
  elif ! force_local=y dind::check-binary kubectl; then
    dind::make-for-linux y cmd/kubectl
  fi
}

function dind::ensure-binaries {
  local -a to_build=()
  for name in "$@"; do
    if ! dind::check-binary "$(basename "${name}")"; then
      to_build+=("${name}")
    fi
  done
  if [ "${#to_build[@]}" -gt 0 ]; then
    dind::make-for-linux n "${to_build[@]}"
  fi
  return 0
}

function dind::ensure-network {
  if ! docker network inspect kubeadm-dind-net >&/dev/null; then
    docker network create --subnet=10.192.0.0/16 kubeadm-dind-net >/dev/null
  fi
}

function dind::ensure-volume {
  local reuse_volume=
  if [[ $1 = -r ]]; then
    reuse_volume=1
    shift
  fi
  local name="$1"
  if dind::volume-exists "${name}"; then
    if [[ ! {reuse_volume} ]]; then
      docker volume rm "${name}" >/dev/null
    fi
  elif [[ ${reuse_volume} ]]; then
    echo "*** Failed to locate volume: ${name}" 1>&2
    return 1
  fi
  dind::create-volume "${name}"
}

function dind::run {
  local reuse_volume=
  if [[ $1 = -r ]]; then
    reuse_volume="-r"
    shift
  fi
  local container_name="${1:-}"
  local ip="${2:-}"
  local netshift="${3:-}"
  local portforward="${4:-}"
  if [[ $# -gt 4 ]]; then
    shift 4
  else
    shift $#
  fi
  local -a opts=(--ip "${ip}" "$@")
  local -a args

  if [[ ! "${container_name}" ]]; then
    echo >&2 "Must specify container name"
    exit 1
  fi

  # remove any previously created containers with the same name
  docker rm -vf "${container_name}" >&/dev/null || true
  if [[ "$portforward" ]]; then
    opts+=(-p "$portforward")
    #opts+=(-p "127.0.0.1:80:80")
    # opts+=(-p "8080:8080")
    # opts+=(-p "80:30912")
  fi

  if [[ "${container_name}" == "kube-node-1" ]]; then
    opts+=(-p "80:80")
    opts+=(-p "30912:30912")
  fi


  if [[ "$netshift" ]]; then
    args+=("systemd.setenv=DOCKER_NETWORK_OFFSET=0.0.${netshift}.0")
  fi

  opts+=(${sys_volume_args[@]+"${sys_volume_args[@]}"})

  dind::step "Starting DIND container:" "${container_name}"

  # if [[ ! ${is_moby_linux} ]]; then
  #   opts+=(-v /boot:/boot -v /lib/modules:/lib/modules)
  # fi

  volume_name="kubeadm-dind-${container_name}"
  dind::ensure-network
  dind::ensure-volume ${reuse_volume} "${volume_name}"

  # TODO: create named volume for binaries and mount it to /k8s
  # in case of the source build
  

  if [[ "${container_name}" == "kube-node-1" ]]; then
    opts+=(-v "/Users/chad/picokube:/workdir")
  fi

  # Start the new container.
  docker run \
         -d --privileged \
         --net kubeadm-dind-net \
         --name "${container_name}" \
         --hostname "${container_name}" \
         -l mirantis.kubeadm_dind_cluster \
         -v ${volume_name}:/dind \
         ${opts[@]+"${opts[@]}"} \
         "${DIND_IMAGE}" \
         ${args[@]+"${args[@]}"}
}

function dind::kubeadm {
  local container_id="$1"
  shift
  dind::step "Running kubeadm:" "$*"
  status=0
  # See image/bare/wrapkubeadm.
  # Capturing output is necessary to grab flags for 'kubeadm join'
  if ! docker exec "${container_id}" wrapkubeadm "$@" 2>&1 | tee /dev/fd/2; then
    echo "*** kubeadm failed" >&2
    return 1
  fi
  return ${status}
}

# function dind::bare {
#   local container_name="${1:-}"
#   if [[ ! "${container_name}" ]]; then
#     echo >&2 "Must specify container name"
#     exit 1
#   fi
#   shift
#   run_opts=(${@+"$@"})
#   dind::run "${container_name}"
# }

function dind::configure-kubectl {
  dind::step "Setting cluster config"
  "${kubectl}" config set-cluster dind --server="http://localhost:${APISERVER_PORT}" --insecure-skip-tls-verify=true
  "${kubectl}" config set-context dind --cluster=dind
  "${kubectl}" config use-context dind
}

force_make_binaries=
function dind::set-master-opts {
  master_opts=()
  if [[ ${BUILD_KUBEADM} || ${BUILD_HYPERKUBE} ]]; then
    # share binaries pulled from the build container between nodes
    dind::ensure-volume "dind-k8s-binaries"
    dind::set-build-volume-args
    master_opts+=("${build_volume_args[@]}" -v dind-k8s-binaries:/k8s)
    local -a bins
    if [[ ${BUILD_KUBEADM} ]]; then
      master_opts+=(-e KUBEADM_SOURCE=build://)
      bins+=(cmd/kubeadm)
    fi
    if [[ ${BUILD_HYPERKUBE} ]]; then
      master_opts+=(-e HYPERKUBE_SOURCE=build://)
      bins+=(cmd/hyperkube)
    fi
    if [[ ${force_make_binaries} ]]; then
      dind::make-for-linux n "${bins[@]}"
    else
      dind::ensure-binaries "${bins[@]}"
    fi
  fi
}

function dind::deploy-dashboard {
  dind::step "Deploying k8s dashboard"
  "${kubectl}" create -f "${DASHBOARD_URL}"
}

function dind::init {
  local -a opts
  dind::set-master-opts
  local master_ip="${dind_ip_base}.2"
  local container_id=$(dind::run kube-master "${master_ip}" 1 127.0.0.1:${APISERVER_PORT}:8080 ${master_opts[@]+"${master_opts[@]}"})
  # FIXME: I tried using custom tokens with 'kubeadm ex token create' but join failed with:
  # 'failed to parse response as JWS object [square/go-jose: compact JWS format must have three parts]'
  # So we just pick the line from 'kubeadm init' output
  kubeadm_join_flags="$(dind::kubeadm "${container_id}" init --skip-preflight-checks "$@" | grep '^ *kubeadm join' | sed 's/^ *kubeadm join //')"
  dind::configure-kubectl
  dind::deploy-dashboard
}

function dind::create-node-container {
  local reuse_volume=
  if [[ $1 = -r ]]; then
    reuse_volume="-r"
    shift
  fi
  # if there's just one node currently, it's master, thus we need to use
  # kube-node-1 hostname, if there are two nodes, we should pick
  # kube-node-2 and so on
  local next_node_index=${1:-$(docker ps -q --filter=label=mirantis.kubeadm_dind_cluster | wc -l | sed 's/^ *//g')}
  local node_ip="${dind_ip_base}.$((next_node_index + 2))"
  local -a opts
  if [[ ${BUILD_KUBEADM} || ${BUILD_HYPERKUBE} ]]; then
    opts+=(-v dind-k8s-binaries:/k8s)
    if [[ ${BUILD_KUBEADM} ]]; then
      opts+=(-e KUBEADM_SOURCE=build://)
    fi
    if [[ ${BUILD_HYPERKUBE} ]]; then
      opts+=(-e HYPERKUBE_SOURCE=build://)
    fi
  fi
  dind::run ${reuse_volume} kube-node-${next_node_index} ${node_ip} $((next_node_index + 1)) "" ${opts[@]+"${opts[@]}"}
}

function dind::join {
  local container_id="$1"
  shift
  dind::kubeadm "${container_id}" join --skip-preflight-checks "$@" >/dev/null
}

function dind::escape-e2e-name {
    sed 's/[]\$*.^|()[]/\\&/g; s/\s\+/\\s+/g' &lt;&lt;&lt; "$1" | tr -d '\n'
}

function dind::accelerate-kube-dns {
  dind::step "Patching kube-dns deployment to make it start faster"
  # Could do this on the host, too, but we don't want to require jq here
  # TODO: do this in wrapkubeadm
  # 'kubectl version --short' is a quick check for kubectl 1.4
  # which doesn't support 'kubectl apply --force'
  docker exec kube-master /bin/bash -c \
         "kubectl get deployment kube-dns -n kube-system -o json | jq '.spec.template.spec.containers[0].readinessProbe.initialDelaySeconds = 3|.spec.template.spec.containers[0].readinessProbe.periodSeconds = 3' | if kubectl version --short >&/dev/null; then kubectl apply --force -f -; else kubectl apply -f -; fi"
}

function dind::component-ready {
  local label="$1"
  local out
  if ! out="$("${kubectl}" get pod -l "${label}" -n kube-system \
                           -o jsonpath='{ .items[*].status.conditions[?(@.type == "Ready")].status }' 2>/dev/null)"; then
    return 1
  fi
  if ! grep -v False &lt;&lt;&lt;"${out}" | grep -q True; then
    return 1
  fi
  return 0
}

function dind::wait-for-ready {
  dind::step "Waiting for kube-proxy and the nodes"
  local proxy_ready
  local nodes_ready
  local n=3
  while true; do
    if "${kubectl}" get nodes 2>/dev/null| grep -q NotReady; then
      nodes_ready=
    else
      nodes_ready=y
    fi
    if dind::component-ready k8s-app=kube-proxy; then
      proxy_ready=y
    else
      proxy_ready=
    fi
    if [[ ${nodes_ready} && ${proxy_ready} ]]; then
      if ((--n == 0)); then
        echo "[done]" >&2
        break
      fi
    else
      n=3
    fi
    echo -n "." >&2
    sleep 1
  done

  dind::step "Bringing up kube-dns and kubernetes-dashboard"
  "${kubectl}" scale deployment --replicas=1 -n kube-system kube-dns
  "${kubectl}" scale deployment --replicas=1 -n kube-system kubernetes-dashboard

  while ! dind::component-ready k8s-app=kube-dns || ! dind::component-ready app=kubernetes-dashboard; do
    echo -n "." >&2
    sleep 1
  done
  echo "[done]" >&2

  "${kubectl}" get pods -n kube-system -l k8s-app=kube-discovery | (grep MatchNodeSelector || true) | awk '{print $1}' | while read name; do
    dind::step "Killing off stale kube-discovery pod" "${name}"
    "${kubectl}" delete pod --now -n kube-system "${name}"
  done

  "${kubectl}" get nodes >&2
  dind::step "Access dashboard at:" "http://localhost:${APISERVER_PORT}/ui"
  #  kubectl apply -f https://raw.githubusercontent.com/moondev/cluster-compose/master/manifests/heapster/grafana-deployment.yaml

  kubectl create -f manifests/
  kubectl --namespace kube-system rollout status deployment/monitoring-grafana
  kubectl --namespace kube-system rollout status deployment/monitoring-influxdb
  kubectl --namespace kube-system rollout status deployment/heapster
  kubectl --namespace kube-system rollout status deployment/traefik-ingress-controller

  sleep 2


  kubectl create -f k8s/

  kubectl cluster-info

  sleep 5
  open "http://dashboard.127.0.0.1.xip.io" || true
  # xdg-open "http://dashboard.127.0.0.1.xip.io" || true
  # explorer "http://dashboard.127.0.0.1.xip.io" || true

}

function dind::up {
  dind::down
  dind::init
  local master_ip="$(docker inspect --format="