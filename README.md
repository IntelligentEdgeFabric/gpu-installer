# gpu-installer

## nvidia gpu installer

the main idea is installing all nvidia drivers files in one direcotry, stolen from [ubuntu nvidia-driver-installer from google]( https://github.com/GoogleCloudPlatform/container-engine-accelerators/tree/master/nvidia-driver-installer/ubuntu).<br>
But add features/fix issues below:
1. add centos support.
2. fix [Installer freezes node issue](https://github.com/GoogleCloudPlatform/container-engine-accelerators/issues/80).
3. fix machine-rebooting issue: we just need to run this installer only once, not k8s daemonset.

### requirements
1. nvidia gpu card inserted
2. docker service already started
3. by now centos 7.X and ubuntu 16.04+ are supported
### run

the default install directory is _/var/IEF/nvidia_, don't modify this if you use the IEF service.

```sh

# check usage
bash nvidia-gpu-installer.sh -h

# simple run with default version 384.111, default download url https://us.download.nvidia.com/tesla/384.111/NVIDIA-Linux-x86_64-384.111.run
bash nvidia-gpu-installer.sh install

# try to uninstall existing drivers without asking when installing
bash nvidia-gpu-installer.sh install -y

# run with driver version 396.44, default download url https://us.download.nvidia.com/tesla/396.44/NVIDIA-Linux-x86_64-396.44.run
NVIDIA_DRIVER_VERSION=396.44 bash nvidia-gpu-installer.sh install

# run with driver version 396.44 and download url http://cn.download.nvidia.com/tesla/396.44/NVIDIA-Linux-x86_64-396.44.run
NVIDIA_DRIVER_VERSION=396.44 NVIDIA_DRIVER_DOWNLOAD_URL=http://cn.download.nvidia.com/tesla/396.44/NVIDIA-Linux-x86_64-396.44.run bash nvidia-gpu-installer.sh install


# clean drivers
bash nvidia-gpu-installer.sh clean

```


## FAQ
1. How to check gpu drivers are installed successfully?
```sh
# check that nvidia/nvidia-uvm ko are loaded
lsmod |grep -e nvidia -e nvidia-uvm

# check that device files are created
ls /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia?

# check by nvidia-smi
/var/IEF/nvidia/bin/nvidia-smi

```

2. After reboot, gpu drivers are not loaded?
```sh
# check the loader script status
systemctl status nvidia-drivers-loader
if : found "Invalid module format"; then
  echo "your kernel version may change since last installation time, please switch to the old kernel version!!"
fi
```
