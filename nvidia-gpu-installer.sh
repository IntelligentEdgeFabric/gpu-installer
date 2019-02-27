#!/bin/bash
# nvidia gpu auto installer
# centos 7.X, ubuntu 16.04+ are supported
set -e
set -u

NVIDIA_INSTALL_DIR=/var/IEF/nvidia
KERNEL_VERSION=$(uname -r)
PATH="${NVIDIA_INSTALL_DIR}/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/sbin:/bin:$PATH"
CACHE_FILE="${NVIDIA_INSTALL_DIR}/.cache"

mkdir -p "$NVIDIA_INSTALL_DIR"
cd "$NVIDIA_INSTALL_DIR"


get_latest_nvidia_driver()
{
  # find the latest nvidia driver version from the nvidia offical web page

  [ -z "${NVIDIA_DRIVER_VERSION:-}" ] || return 0
  echo "You don't specify the NVIDIA_DRIVER_VERSION, try to find the latest version"

  for _loop in 0 1; do
    product_name=$(lspci | awk '
        # found the nvidia product
        # example output: 00:0c.0 3D controller: NVIDIA Corporation GP104GL [Tesla P4]
        /NVIDIA/&&!first++&&sub(/.*\[/, ""){
           sub(/\].*/, "")
          print $0
          exit 0
        }
      ')

    if [ -z "$product_name" ]; then
      echo "Update the PCI ID list"
      update-pciids -q
      continue
    fi

    # these values are from the source of https://www.nvidia.cn/Download/index.aspx?lang=cn
    # current only support Tesla product type
    product_map="822 Tesla P100 827 Tesla P40 858 Tesla P6 831 Tesla P4 @
                 883 Tesla T4 @
                 857 Tesla V100 @
                 762 Tesla K80 856 Tesla K520 713 Tesla K40c 714 Tesla K40m 715 Tesla K40s 716 Tesla K40st 777 Tesla K40t 670 Tesla K20Tesla Xm 668 Tesla K20m 684 Tesla K20s 667 Tesla K20c 652 Tesla K10 760 Tesla K8 @"
    product_value=$(echo "$product_map" | awk "sub(/$product_name .*/,e){print\$NF}")
    echo "Found the nvidia driver product name '$product_name', product value is $product_value"

    os_value=12 # Linux 64-bit
    driver_result_url=$(curl -s "https://www.nvidia.com/Download/processDriver.aspx?pfid=$product_value&rpf=1&osid=$os_value" | sed s/http:/https:/)
    NVIDIA_DRIVER_VERSION=$(curl -s "$driver_result_url" | awk '
        { gsub(/\r/,"") }
        start && $1~/^[0-9]+(\.[0-9]*)?$/{
          print $1;exit
        }
        $1=="Version:"{start=1}
      ')

    [ -n "$NVIDIA_DRIVER_VERSION" ] && echo "Found the latest nvidia driver $NVIDIA_DRIVER_VERSION"
    break
  done

  # fall back the old default version
  NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-384.111}"
}


get_release()
{
  eval "$(sed 's/^[A-Za-z]/OS_&/' /etc/os-release)"
  if test $OS_ID = rhel; then
    # translate redhat into centos
    OS_ID=centos
    # get the major number of OS_VERSION_ID
    OS_VERSION_ID=$(echo $OS_VERSION_ID | cut -d. -f1)
  fi
}

pre_check()
{
  if ! echo $OS_ID | grep -w -q -e centos -e ubuntu; then
    echo "current only centos/ubuntu are supported!"
    return 1
  fi

  if ! lspci | grep -i NVIDIA | grep -qe '3D controller' -e 'VGA compatible controller'; then
    [ -z "${__DEBUG__:-}" ] && {
      echo "NVIDIA Card not found"
      return 1
    }
  fi

  if ! docker ps 2>/dev/null >&2; then
    echo "docker are not installed or stopped! Please install or start docker first!"
    return 1
  fi
}

parse_args()
{
  force=
  no_cache_check=
  no_cache_container=
  for opt ; do
    case "$opt" in
      -y|--yes) force=y;;
      --no-cache-check) no_cache_check=y;;
      --no-cache-container) no_cache_container=y;;
      *) :;;
    esac
  done
}

_download_url_ok()
{
  curl -L --silent --head "$1" | awk '/^HTTP/{a=$2<400}END{exit(1-a)}'
}

get_download_url()
{
  # found the downloadable url
  for url in "http://us.download.nvidia.com/XFree86/Linux-x86_64/@/NVIDIA-Linux-x86_64-@.run" \
      "https://us.download.nvidia.com/tesla/@/NVIDIA-Linux-x86_64-@.run";  do
    url=${url//@/$1}
    if _download_url_ok "$url"; then
      # found good url
      echo "$url"
      break
    fi
  done

}

download_nvidia_installer()
{

  url="${1:-$NVIDIA_DRIVER_DOWNLOAD_URL}"
  savefile="${2:-$NVIDIA_INSTALLER_RUNFILE}"
  if [ ! -f "${savefile}" ] || ! sh "${savefile}" --check >/dev/null 2>&1; then
    if [ -z "$url" ]; then
      echo "Can't found the downloadable url, you need to specify the NVIDIA_DRIVER_DOWNLOAD_URL"
      usage 1
    fi
    echo "${savefile} does not exist or broken"
    echo "Downloading Nvidia installer..."
    curl -L -S -f "${url}" -o "${savefile}" || return 1
    echo "Downloading Nvidia installer... DONE."
  else
    echo "Nvidia installer cached in ${PWD}/${savefile}"
  fi
}

check_drivers_exist()
{
  [ -n "${__DEBUG__:-}" ] && return 0
  lsmod | grep -qw nvidia
}

insert_drivers()
{
  modprobe ipmi_devintf 2>/dev/null || true
  for f in nvidia.ko nvidia-uvm.ko; do
    f=${NVIDIA_INSTALL_DIR}/drivers/$f
    [ -f "$f" ] && insmod $f
  done
}

unload_drivers()
{
  for m in nvidia_drm nvidia_uvm nvidia_modeset nvidia; do
    rmmod -f $m 2>/dev/null || modprobe -rf $m 2>/dev/null || true
  done
  ! check_drivers_exist
}

uninstall_drivers()
{
  if ! check_drivers_exist; then
    # don't need to uninstall!
    return 0
  fi
  echo "Uninstalling nvidia kernel drivers..."
  #
  # TODO: need to help uninstall the driver if not installed by this method?
  # TODO: found a way to figure out installed by this method
  version=$(modinfo nvidia 2>/dev/null| awk '/^version/{print $2}')
  if [ -z "$version" ]; then
    echo "Can't find the nvidia version, so guess it's installed by this script"
    unload_drivers && return 0
    # this error message is from nvidia office installer
    echo "ERROR: An NVIDIA kernel module 'nvidia' appears to already be loaded in your kernel.  This may be because it is in use (for example, by an X server, a CUDA program, or the NVIDIA Persistence Daemon), but this may also happen if your"
    echo "       kernel was configured without support for module unloading.  Please be sure to exit any programs that may be using the GPU(s) before attempting to upgrade your driver.  If no GPU-based programs are running, you know that your"
    echo "       kernel supports module unloading, and you still receive this message, then an error may have occured that has corrupted an NVIDIA kernel module's usage count, for which the simplest remedy is to REBOOT YOUR COMPUTER."
  else
    uninstall_choice=y
    echo "Nvidia drivers are found, but are not installed by not by this script, maybe the nvidia offical way!"
    [ -z "$force" ] && read -p "Are you sure to uninstall it by the nvidia offical way? [yN] " uninstall_choice
    if [ "$uninstall_choice" != y -a "$uninstall_choice" != Y ] ; then
      echo "Abort!"
      return 1
    fi
    url="$(get_download_url $version)"
    installer_file=$(basename "${url}")
    download_nvidia_installer "$url" "$installer_file"
    bash "$installer_file" \
      --uninstall --no-questions --ui=none \
      --accept-license \
      --log-file-name=/dev/stdout
  fi

  # last to check
  if check_drivers_exist; then
    [ -n "${__DEBUG__:-}" ] && return 0
    return 1
  fi
}

clean()
{
  echo "cleanup ..."
  uninstall_choice=y
  [ -z "$force" ] && read -p "This will REMOVE all the files under ${NVIDIA_INSTALL_DIR}, Are you sure? [yN] " uninstall_choice
  if [ "$uninstall_choice" != y -a "$uninstall_choice" != Y ] ; then
    echo "Abort!"
    return 1
  fi
  set +e
  systemctl disable nvidia-drivers-loader 2>/dev/null
  # remove ld entry added by old installation
  grep -q ${NVIDIA_INSTALL_DIR}/lib64 /etc/ld.so.conf && \
    sed -i "s@${NVIDIA_INSTALL_DIR}/lib64@@" /etc/ld.so.conf && ldconfig
  rm -f /etc/systemd/system/nvidia-drivers-loader.service
  uninstall_drivers
  rm -rf "$NVIDIA_INSTALL_DIR"
  set -e
  echo "cleanup ... DONE."
}

install_devel_ubuntu()
{
  echo '
  # set apt config when http_proxy is set
  # see https://github.com/jenkinsci/docker/issues/543
  env |grep -q "^http_proxy=" && echo "Acquire::http::Pipeline-Depth 0;
Acquire::http::No-Cache true;
Acquire::BrokenProxy    true;
" > /etc/apt/apt.conf.d/99fixbadproxy
  apt-get update
  apt-get install -y kmod
  apt-get install -y gcc
  apt-get install -y make
  apt-get install -y linux-headers-${KERNEL_VERSION}'
}

installer_extra_args_ubuntu()
{
  echo ""
}

install_devel_centos()
{

  echo '
   kernel_dir=/usr/src/kernels/$KERNEL_VERSION
   if [ ! -d ${ROOT_MOUNT_DIR}$kernel_dir ] ; then
      yum update -y
      yum install -y kernel-devel kernel-headers
      if [ ! -d $kernel_dir ] ; then
          installed_version=$(rpm -q kernel-devel | sed s/kernel-devel-//)
          echo "kernel development not found for $KERNEL_VERSION, found: $installed_version"
          if test $(echo $installed_version | cut -d. -f1,2,3) = $(echo $KERNEL_VERSION | cut -d. -f1,2,3); then
            echo "But the kernel version until the patch number is same."
            echo "So try to use /usr/src/kernels/$installed_version as the kernel dir anyway."
            ln -s /usr/src/kernels/$installed_version $kernel_dir
          else
            echo "RUN this command below to upgrade your kernel:"
            echo "   yum update -y && yum install -y kernel-devel kernel-headers"
            echo "And then reboot!"
            exit 1
          fi
      fi
   elif [ ! -d "$kernel_dir" ] ; then
      mkdir -p /usr/src/kernels
      echo "symbolic link $kernel_dir to ${ROOT_MOUNT_DIR}$kernel_dir"
      ln -s ${ROOT_MOUNT_DIR}$kernel_dir $kernel_dir
   fi
   yum update -y
   yum install gcc  -y
   yum install make -y'
}

installer_extra_args_centos()
{
  echo '--kernel-source-path /usr/src/kernels/$KERNEL_VERSION'
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
NVIDIA_INSTALL_DIR_HOST="${NVIDIA_INSTALL_DIR_HOST:-/var/IEF/nvidia}"
NVIDIA_INSTALL_DIR_CONTAINER="${NVIDIA_INSTALL_DIR_CONTAINER:-/var/IEF/nvidia}"
ROOT_MOUNT_DIR="${ROOT_MOUNT_DIR:-/root}"
KERNEL_VERSION="$(uname -r)"
set +x


update_container_ld_cache() {
  echo "Updating container's ld cache..."
  echo "${NVIDIA_INSTALL_DIR_CONTAINER}/lib64" > /etc/ld.so.conf.d/nvidia.conf
  ldconfig
  echo "Updating container's ld cache... DONE."
}

install_devel() {
  echo "Install development tools and downloading kernel sources..."
  {{install_devel}}
  echo "Install development tools and downloading kernel sources... DONE."
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

  # before mount, rm any existing files
  rm -rf bin lib64 drivers
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

copy_binaries()
{
  pushd ${NVIDIA_INSTALL_DIR_CONTAINER}/bin
  # copy nvidia binaries
  cp /usr/bin/nvidia-* .
  # wrap these binaries with LD_LIBRARY_PATH env.
  # fix the issue that these shared object (libEGL/libGLESv2/libGL) would hang X in some environment (i.e. centos 7.5 with gnome)
  # the drawback of this method is that error mesage would contain the wrapped path
  for f in nvidia-*; do
    mv $f wrapped_$f
    echo -e '#!/bin/sh\ncd $(dirname "$0")/..\nLD_LIBRARY_PATH=lib64 bin/'"wrapped_$f" '"$@"' > $f
    chmod +x $f
  done
}

run_nvidia_installer() {
  echo "Running Nvidia installer..."
  pushd "${NVIDIA_INSTALL_DIR_CONTAINER}"
  # --no-drm is added in version 375.66
  # see https://www.nvidia.com/Download/driverResults.aspx/118290/en-us
  no_drm=$(echo "${NVIDIA_DRIVER_VERSION}" | awk '375.66<=$0{print "--no-drm"}')
  sh "${NVIDIA_INSTALLER_RUNFILE}" \
    --utility-prefix="${NVIDIA_INSTALL_DIR_CONTAINER}" \
    --opengl-prefix="${NVIDIA_INSTALL_DIR_CONTAINER}" \
    --no-install-compat32-libs \
    --log-file-name="${NVIDIA_INSTALL_DIR_CONTAINER}/nvidia-installer.log" \
    --silent \
    $no_drm \
    --accept-license \
    {{installer_extra_args}}
  popd
  echo "Running Nvidia installer... DONE."
}

main() {
  install_devel
  configure_nvidia_installation_dirs
  run_nvidia_installer
  copy_binaries
}

main "$@"

EOL
)

  for t in install_devel installer_extra_args; do
    pat="{{"$t"}}"
    v="$(eval ${t}_${OS_ID})"
    templ="${templ/$pat/$v}"
  done
  echo "$templ" > $1
  chmod +x $1
}

build_image()
{
  mkdir -p "${NVIDIA_INSTALL_DIR}/.build"
  pushd "${NVIDIA_INSTALL_DIR}/.build"

  entrypoint=entrypoint.sh
  gen_entrypoint $entrypoint
  cat > Dockerfile <<EOF
FROM ${OS_ID}:${OS_VERSION_ID}
COPY $entrypoint /$entrypoint
CMD /$entrypoint
EOF
  docker build -t "$1" .
  popd
}

install_drivers_loader_service()
{
  cd ${NVIDIA_INSTALL_DIR}
  cat <<-"EOF" > nvidia-drivers-loader.sh
#!/bin/bash
cd "$(dirname $0)/drivers"
# Note: this also load ipmi_msghandler
modprobe ipmi_devintf 2>/dev/null || true

if insmod nvidia.ko; then
  # Count the number of NVIDIA controllers found.
  N=`lspci | grep -i NVIDIA | grep -e '3D controller' -e 'VGA compatible controller' | wc -l`
  for((i=0;i<N;i++)); do
    mknod -m 666 /dev/nvidia$i c 195 $i
  done
  mknod -m 666 /dev/nvidiactl c 195 255
fi
insmod nvidia-uvm.ko && mknod -m 666 /dev/nvidia-uvm c $(awk '/nvidia-uvm/&&$0=$1' /proc/devices) 0 || exit 1
EOF

  chmod +x nvidia-drivers-loader.sh

  cat <<-EOF > /etc/systemd/system/nvidia-drivers-loader.service
[Unit]
Description=auto loader of nvidia drivers
Before=sysinit.target
After=systemd-modules-load.service
DefaultDependencies=no
Conflicts=shutdown.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '(for i in \$(seq 120) ; do  [ -f ${PWD}/nvidia-drivers-loader.sh ] && break; sleep .5; done; bash ${PWD}/nvidia-drivers-loader.sh)&'
RemainAfterExit=yes
Environment="PATH=/usr/sbin:/sbin:/usr/bin:/bin"

[Install]
WantedBy=sysinit.target
EOF

}


pre_run()
{
  # Note: this also load ipmi_msghandler
  modprobe ipmi_devintf 2>/dev/null || true
  NVIDIA_DRIVER_DOWNLOAD_URL="${NVIDIA_DRIVER_DOWNLOAD_URL:-$(get_download_url $NVIDIA_DRIVER_VERSION)}"
  NVIDIA_INSTALLER_RUNFILE="$(basename "${NVIDIA_DRIVER_DOWNLOAD_URL}")"
  download_nvidia_installer
}

post_run()
{
  install_drivers_loader_service
  systemctl enable nvidia-drivers-loader.service
  # try to insmod the drivers anyway, ignore any error
  bash ./nvidia-drivers-loader.sh 2>/dev/null || true
}

run_installer()
{
  pre_run || return 1
  image_name=ief/nvidia-driver-installer:latest

  # build extra args
  extra_args=""
  [ -n "${__DEBUG__:-}" ] && extra_args="--entrypoint /bin/bash"
  [ -n "${http_proxy:-}" ] && extra_args="$extra_args -e http_proxy=$http_proxy"
  [ -n "${https_proxy:-}" ] && extra_args="$extra_args -e https_proxy=$https_proxy"
  [ -n "${no_proxy:-}" ] && extra_args="$extra_args -e no_proxy=$no_proxy"
  run_cmd=""
  [ -n "${__DEBUG__:-}" ] && run_cmd="-c /entrypoint.sh||/bin/bash&&false"

  {
    container_id=$(
      # found already existing container id which also has the same version
      # meanwhile try to clean the orphaned container
      docker ps -a | awk -v image=$image_name 'NF=$2==image' | while read _id; do

         if [ "$no_cache_container" != y ]; then
           docker inspect "$_id" | grep -q "NVIDIA_DRIVER_VERSION=${NVIDIA_DRIVER_VERSION}" && echo $_id && break
         fi
         # try to rm the orphaned container
         docker rm --force $_id >&2|| true
      done
    )

    if [ -n "$container_id" ]; then
      echo "Using already existing installer container $container_id"
      docker start --attach "$container_id"
    else
      build_image $image_name

      docker run -it --privileged --net=host -v /dev:/dev \
        --name nvidia-driver-installer-$NVIDIA_DRIVER_VERSION \
        -v $NVIDIA_INSTALL_DIR:$NVIDIA_INSTALL_DIR -v /:/root \
        -e NVIDIA_INSTALL_DIR_HOST=$NVIDIA_INSTALL_DIR \
        -e NVIDIA_INSTALL_DIR_CONTAINER=$NVIDIA_INSTALL_DIR \
        -e ROOT_MOUNT_DIR=/root \
        -e NVIDIA_DRIVER_VERSION=${NVIDIA_DRIVER_VERSION} \
        -e NVIDIA_INSTALLER_RUNFILE=${NVIDIA_INSTALLER_RUNFILE} \
        $extra_args \
        $image_name $run_cmd
    fi
  } && post_run
  ok=$?
  if [ $ok -eq 0 ]; then
    echo "clean the intermediate container/image"
    docker rm $(docker ps -a | awk -v image=$image_name 'NF=$2==image')
    docker rmi $image_name
  fi
  return $ok

}

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

      echo "Try to load nvidia kernel modules if not inserted"
      if ! check_drivers_exist; then
        insert_drivers
      fi

      if post_check; then
        echo "Found existing driver installation for kernel version ${KERNEL_VERSION} and driver version ${NVIDIA_DRIVER_VERSION}."
        echo "You can use '--no-cache-check' option to disable this cache check."
        return 0

      fi
    fi
  fi
  echo "Cache file ${CACHE_FILE} found but existing versions didn't match."
  return 1
}

reset_cached_version() {
  cat >"${CACHE_FILE}"<<__EOF__
CACHE_KERNEL_VERSION=
CACHE_NVIDIA_DRIVER_VERSION=
__EOF__
}

update_cached_version() {
  cat >"${CACHE_FILE}"<<__EOF__
CACHE_KERNEL_VERSION=${KERNEL_VERSION}
CACHE_NVIDIA_DRIVER_VERSION=${NVIDIA_DRIVER_VERSION}
__EOF__

  echo "Updated cached version as:"
  cat "${CACHE_FILE}"
}

post_check()
{
  echo "checking driver installation..."
  nvidia-smi
}

install()
{
  get_release

  if pre_check; then
    get_latest_nvidia_driver

    [ "$no_cache_check" = y ] || { check_cached_version && return 0; }

    if check_drivers_exist; then
      uninstall_drivers || return 1
    fi

    # reset_cached_version
    if run_installer && post_check; then
      update_cached_version
      echo "Nvidia $NVIDIA_DRIVER_VERSION is installed at ${NVIDIA_INSTALL_DIR} successfully"
      echo "nvidia-smi is located in ${NVIDIA_INSTALL_DIR}/bin, you can add ${NVIDIA_INSTALL_DIR}/bin into PATH in your shell profile!"
    else
      echo "Failed to install nvidia $NVIDIA_DRIVER_VERSION!"
      return 1
    fi
  fi
}

fix()
{
  echo "Fix..."
  # fix binary arguments
  (
  cd ${NVIDIA_INSTALL_DIR}/bin
  for f in nvidia-*; do
    if [ -f "wrapped_$f" ]; then
      echo "fix binary arguments for $f"
      echo -e "#!/bin/sh\nLD_LIBRARY_PATH=${NVIDIA_INSTALL_DIR}/lib64 ${NVIDIA_INSTALL_DIR}/bin/wrapped_$f" '"$@"' > "$f"
      chmod +x "$f"
    fi
  done
  )

  echo "fix nvidia-drivers-loader service"
  install_drivers_loader_service
  systemctl daemon-reload
  echo "Fix... DONE"
}

usage()
{
  echo "Usage: $(basename $0) COMMAND options"
  echo "Supported environment variables:"
  echo "   NVIDIA_DRIVER_VERSION => version to be installed"
  echo "   NVIDIA_DRIVER_DOWNLOAD_URL => driver download url"
  echo "   http_proxy, https_proxy, no_proxy => proxy"
  echo
  echo "Commands:"
  echo "   install: install nvidia drivers"
  echo "         [-y|--yes] no prompt"
  echo "         [--no-cache-check] we cache the last successful version, here no check"
  echo "         [--no-cache-container] default we use the last failed installer container, here no use"
  echo "   clean [-y|--yes]: remove all installed drivers and scripts"
  echo "   fix: fix all installed scripts"
  echo "   -h|help: remove all installed drivers and scripts"
  exit ${1:-1}
}


# default cmd is install
[ $# -eq 0 ] && set install

cmd=$1
shift 1

case "$cmd" in
  install|clean) parse_args "$@"; $cmd; exit $?;;
  fix) fix ;;
  -h|help) usage 0;;
  *) usage 1;;
esac

