#!/bin/bash
# nvidia gpu auto installer
# centos 7.X, ubuntu 16.04+ are supported
NVIDIA_DIR=/var/IEF/nvidia
KERNEL_VERSION=$(uname -r)

mkdir -p "${NVIDIA_DIR}/build"
cd "$NVIDIA_DIR/build"
set -e
set -u

# TODO: find the most proper nvidia-driver version
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-384.111}"

NVIDIA_DRIVER_DOWNLOAD_URL_DEFAULT="https://us.download.nvidia.com/tesla/${NVIDIA_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"
NVIDIA_DRIVER_DOWNLOAD_URL="${NVIDIA_DRIVER_DOWNLOAD_URL:-$NVIDIA_DRIVER_DOWNLOAD_URL_DEFAULT}"


get_url()
{
  echo "${NVIDIA_DRIVER_DOWNLOAD_URL//$NVIDIA_DRIVER_VERSION/$1}"
}

uninstall()
{
  # 
  # TODO: need to help uninstall the driver if not installed by this method?
  # TODO: found a way to figure out installed by this method
  version=$(modinfo nvidia | awk '/^version/{print $2}')
  if [ -n "$version" ]; then
    url=$(get_url $version)
    installer_file=$(basename ${url})
    [ -f "$installer_file" ] || curl -L -S -f "${url}" -o "$installer_file"
    bash $installer_file --uninstall --silent || return 1
      
  else
    echo "Can't found current nvidia version"
    return 1
  fi
}


pre_check()
{
  if ! echo $OS_ID | grep -w -q -e centos -e ubuntu; then
    echo "current only centos/ubuntu are supported!"
    return 1
  fi

  if ! lspci | grep -i NVIDIA | grep -qe '3D controller'; then
    echo "NVIDIA Card not found"
    return 1
  fi

  if lsmod |grep -q nvidia; then
    echo "NVIDIA kernel driver already installed and loaded! Need to uninstall it first!"
    read -p "Are you sure to uninstall it:[yN]" choice
    if [ "$choice" = y -o "$choice" = Y ] ; then
      uninstall || { echo "You need to uninstall it manully"; return 1; }
    else
      { echo "You need to uninstall nvidia drivers first"; return 1; }
    fi
  fi

  if ! docker ps 2>/dev/null >&2; then
    echo "docker are not installed or stopped! Please install or start docker first!"
    return 1
  fi
}

dev_ubuntu()
{
    echo "RUN apt-get update && \
    apt-get install -y kmod gcc make curl && \
    rm -rf /var/lib/apt/lists/*"
}

dev_centos()
{
    echo "RUN yum update -y && yum install gcc make curl -y"
}

download_kernel_ubuntu()
{
    echo "apt-get update && apt-get install -y linux-headers-${KERNEL_VERSION}"
}

installer_extra_args_ubuntu()
{
    echo ""
}


download_kernel_centos()
{
   
   # TODO: report error when kernel-devel version does not match current kernel version
  echo '
   if [ ! -d {ROOT_MOUNT_DIR}/usr/src/kernels/$KERNEL_VERSION ] ; then
        yum update -y && yum install -y kernel-devel kernel-headers 
   fi
   '
}

installer_extra_args_centos()
{
    echo '--kernel-source-path ${ROOT_MOUNT_DIR}/usr/src/kernels/$KERNEL_VERSION'
}


build_image()
{
  cat > Dockerfile <<EOF
FROM ${OS_ID}:${OS_VERSION_ID}

EOF

  cat >> Dockerfile <<EOF

$(dev_${OS_ID})
COPY entrypoint.sh /entrypoint.sh
CMD /entrypoint.sh
EOF
  docker build -t "$1" .
}

gen_entrypoint()
{
  templ=$(cat <<"EOL" 
#!/bin/bash
# Copyright 2017 Google Inc. All rights reserved.
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
set -o pipefail
set -u

set -x
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-384.111}"
NVIDIA_DRIVER_DOWNLOAD_URL_DEFAULT="https://us.download.nvidia.com/tesla/${NVIDIA_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"
NVIDIA_DRIVER_DOWNLOAD_URL="${NVIDIA_DRIVER_DOWNLOAD_URL:-$NVIDIA_DRIVER_DOWNLOAD_URL_DEFAULT}"
NVIDIA_INSTALL_DIR_HOST="${NVIDIA_INSTALL_DIR_HOST:-/var/IEF/nvidia}"
NVIDIA_INSTALL_DIR_CONTAINER="${NVIDIA_INSTALL_DIR_CONTAINER:-/var/IEF/nvidia}"
NVIDIA_INSTALLER_RUNFILE="$(basename "${NVIDIA_DRIVER_DOWNLOAD_URL}")"
ROOT_MOUNT_DIR="${ROOT_MOUNT_DIR:-/root}"
CACHE_FILE="${NVIDIA_INSTALL_DIR_CONTAINER}/.cache"
KERNEL_VERSION="$(uname -r)"
set +x

check_cached_version() {
  echo "Checking cached version"
  if [[ ! -f "${CACHE_FILE}" ]]; then
    echo "Cache file ${CACHE_FILE} not found."
    return 1
  fi

  # Source the cache file and check if the cached driver matches
  # currently running kernel version and requested driver versions.
  . "${CACHE_FILE}"
  if [[ "${KERNEL_VERSION}" == "${CACHE_KERNEL_VERSION}" ]]; then
    if [[ "${NVIDIA_DRIVER_VERSION}" == "${CACHE_NVIDIA_DRIVER_VERSION}" ]]; then
      echo "Found existing driver installation for kernel version ${KERNEL_VERSION} and driver version ${NVIDIA_DRIVER_VERSION}."
      return 0
    fi
  fi
  echo "Cache file ${CACHE_FILE} found but existing versions didn't match."
  return 1
}

update_cached_version() {
  cat >"${CACHE_FILE}"<<__EOF__
CACHE_KERNEL_VERSION=${KERNEL_VERSION}
CACHE_NVIDIA_DRIVER_VERSION=${NVIDIA_DRIVER_VERSION}
__EOF__

  echo "Updated cached version as:"
  cat "${CACHE_FILE}"
}

update_container_ld_cache() {
  echo "Updating container's ld cache..."
  echo "${NVIDIA_INSTALL_DIR_CONTAINER}/lib64" > /etc/ld.so.conf.d/nvidia.conf
  ldconfig
  echo "Updating container's ld cache... DONE."
}

download_kernel_src() {
  echo "Downloading kernel sources..."
  {{download_kernel}}
  echo "Downloading kernel sources... DONE."
}

configure_nvidia_installation_dirs() {
  echo "Configuring installation directories..."
  mkdir -p "${NVIDIA_INSTALL_DIR_CONTAINER}"
  pushd "${NVIDIA_INSTALL_DIR_CONTAINER}"

  # nvidia-installer does not provide an option to configure the
  # installation path of `nvidia-modprobe` utility and always installs it
  # under /usr/bin. The following workaround ensures that
  # `nvidia-modprobe` is accessible outside the installer container
  # filesystem.
  # overlay workaround does not work with aufs, which makes node freeze
  # see https://github.com/GoogleCloudPlatform/container-engine-accelerators/issues/80.
  # we just use bind mount workaround
  mkdir -p bin
  # no bind, just copy nvidia-binaries
  # mount -t overlay -o lowerdir=/usr/bin,upperdir=bin,workdir=bin-workdir none /usr/bin

  # nvidia-installer does not provide an option to configure the
  # installation path of libraries such as libnvidia-ml.so. The following
  # workaround ensures that the libs are accessible from outside the
  # installer container filesystem.
  mkdir -p lib64
  mkdir -p /usr/lib/x86_64-linux-gnu
  # mount -t overlay -o lowerdir=/usr/lib/x86_64-linux-gnu,upperdir=lib64,workdir=lib64-workdir none /usr/lib/x86_64-linux-gnu
  cp -R  /usr/lib/x86_64-linux-gnu/. /lib/
  mount --bind lib64 /usr/lib/x86_64-linux-gnu

  # nvidia-installer does not provide an option to configure the
  # installation path of driver kernel modules such as nvidia.ko. The following
  # workaround ensures that the modules are accessible from outside the
  # installer container filesystem.
  mkdir -p drivers
  mkdir -p /lib/modules/${KERNEL_VERSION}/video
  # just bind mount
  # mount -t overlay -o lowerdir=/lib/modules/${KERNEL_VERSION}/video,upperdir=drivers,workdir=drivers-workdir none /lib/modules/${KERNEL_VERSION}/video
  mount --bind drivers /lib/modules/${KERNEL_VERSION}/video

  # Populate ld.so.conf to avoid warning messages in nvidia-installer logs.
  update_container_ld_cache

  popd
  echo "Configuring installation directories... DONE."
}

download_nvidia_installer() {
  echo "Downloading Nvidia installer..."
  pushd "${NVIDIA_INSTALL_DIR_CONTAINER}"
  if [ ! -f "${NVIDIA_INSTALLER_RUNFILE}" ]; then
    curl -L -S -f "${NVIDIA_DRIVER_DOWNLOAD_URL}" -o "${NVIDIA_INSTALLER_RUNFILE}"
  fi
  popd
  echo "Downloading Nvidia installer... DONE."
}

run_nvidia_installer() {
  echo "Running Nvidia installer..."
  pushd "${NVIDIA_INSTALL_DIR_CONTAINER}"
  sh "${NVIDIA_INSTALLER_RUNFILE}" \
    --utility-prefix="${NVIDIA_INSTALL_DIR_CONTAINER}" \
    --opengl-prefix="${NVIDIA_INSTALL_DIR_CONTAINER}" \
    --no-install-compat32-libs \
    --log-file-name="${NVIDIA_INSTALL_DIR_CONTAINER}/nvidia-installer.log" \
    --no-drm \
    --silent \
    --accept-license \
    {{installer_extra_args}}
    
  # copy nvidia binaries
  cp /usr/bin/nvidia-* bin/
  popd
  echo "Running Nvidia installer... DONE."
}

configure_cached_installation() {
  echo "Configuring cached driver installation..."
  update_container_ld_cache
  if ! lsmod | grep -q -w 'nvidia'; then
    insmod "${NVIDIA_INSTALL_DIR_CONTAINER}/drivers/nvidia.ko"
  fi
  if ! lsmod | grep -q -w 'nvidia_uvm'; then
    insmod "${NVIDIA_INSTALL_DIR_CONTAINER}/drivers/nvidia-uvm.ko"
  fi
  echo "Configuring cached driver installation... DONE"
}

verify_nvidia_installation() {
  echo "Verifying Nvidia installation..."
  export PATH="${NVIDIA_INSTALL_DIR_CONTAINER}/bin:${PATH}"
  nvidia-smi
  # Create unified memory device file.
  nvidia-modprobe -c0 -u
  echo "Verifying Nvidia installation... DONE."
}

update_host_ld_cache() {
  echo "Updating host's ld cache..."
  echo "${NVIDIA_INSTALL_DIR_HOST}/lib64" >> "${ROOT_MOUNT_DIR}/etc/ld.so.conf"
  ldconfig -r "${ROOT_MOUNT_DIR}"
  echo "Updating host's ld cache... DONE."
}

install_nvidia_loader_service() {

  pushd $NVIDIA_INSTALL_DIR_CONTAINER

  cat <<-"EOF" > nvidia-drivers-loader.sh
#!/bin/bash
cd "$(dirname $0)/drivers"
modprobe ipmi_devintf 2>/dev/null || true
insmod nvidia.ko
if [ "$?" -eq 0 ]; then
  # Count the number of NVIDIA controllers found.
  N=`lspci | grep -i NVIDIA | grep -e '3D controller' -e 'VGA compatible controller' | wc -l`
  for((i=0;i<N;i++)); do
    mknod -m 666 /dev/nvidia$i c 195 $i
  done
  mknod -m 666 /dev/nvidiactl c 195 255
  else
  exit 1
fi
insmod nvidia-uvm.ko && mknod -m 666 /dev/nvidia-uvm c $(awk '/nvidia-uvm/&&$0=$1' /proc/devices) 0 || exit 1
EOF

  chmod +x nvidia-drivers-loader.sh

  cat <<-EOF > ${ROOT_MOUNT_DIR}/etc/systemd/system/nvidia-drivers-loader.service
[Unit]
Description=auto loader of nvidia drivers
Before=local-fs.target
DefaultDependencies=no
Conflicts=shutdown.target

[Service]
Type=oneshot
ExecStart=/bin/bash $NVIDIA_INSTALL_DIR_HOST/nvidia-drivers-loader.sh
RemainAfterExit=yes
Environment="PATH=/usr/sbin:/sbin:/usr/bin:/bin"

[Install]
WantedBy=sysinit.target
EOF

  chroot ${ROOT_MOUNT_DIR} systemctl enable nvidia-drivers-loader.service
  popd
}

main() {
  if check_cached_version; then
    configure_cached_installation
    verify_nvidia_installation
  else
    download_kernel_src
    configure_nvidia_installation_dirs
    download_nvidia_installer
    run_nvidia_installer
    update_cached_version
    verify_nvidia_installation
  fi
  update_host_ld_cache
  install_nvidia_loader_service
}

main "$@"

EOL)

  for t in download_kernel installer_extra_args; do
    pat="{{"$t"}}"
    v="$(eval ${t}_${OS_ID})"
    templ="${templ/$pat/$v}"
  done
  echo "$templ" > entrypoint.sh
  chmod +x entrypoint.sh
}

get_release()
{
  eval "$(sed 's/^[A-Za-z]/OS_&/' /etc/os-release)"
}

pre_run()
{
    # Note: this also load ipmi_msghandler
    modprobe ipmi_devintf 2>/dev/null || true
}

run_installer()
{
  pre_run
  gen_entrypoint
  image_name=${OS_ID}-nvidia-driver-installer:latest

  build_image $image_name

  # build extra args
  extra_args=""
  [ -n "${http_proxy:-}" ] && extra_args="$extra_args -e http_proxy=$http_proxy"
  [ -n "${https_proxy:-}" ] && extra_args="$extra_args -e https_proxy=$https_proxy"


  # TODO: find the most proper nvidia-driver version
  docker run --rm -it --privileged --net=host -v /dev:/dev \
    -v $NVIDIA_DIR:$NVIDIA_DIR -v /:/root \
    -e NVIDIA_INSTALL_DIR_HOST=$NVIDIA_DIR \
    -e NVIDIA_INSTALL_DIR_CONTAINER=$NVIDIA_DIR \
    -e ROOT_MOUNT_DIR=/root \
    -e NVIDIA_DRIVER_VERSION=${NVIDIA_DRIVER_VERSION} \
    -e NVIDIA_DRIVER_DOWNLOAD_URL=${NVIDIA_DRIVER_DOWNLOAD_URL} \
    $extra_args \
    $image_name
}

post_check()
{
  # nvidia installer already run nvidia-smi check
  return 0
}

get_release

if pre_check; then
  run_installer && post_check
fi

