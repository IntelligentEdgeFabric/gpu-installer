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
### install

the default install directory is _/var/IEF/nvidia_, don't modify this if you use the IEF service.

```sh
# simple run with default version 384.111, default download url https://us.download.nvidia.com/tesla/384.111/NVIDIA-Linux-x86_64-384.111.run
bash nvidia-gpu-installer.sh

# run with driver version 396.44, default download url https://us.download.nvidia.com/tesla/396.44/NVIDIA-Linux-x86_64-396.44.run
NVIDIA_DRIVER_VERSION=396.44 bash nvidia-gpu-installer.sh

# run with driver version 396.44 and download url http://cn.download.nvidia.com/tesla/396.44/NVIDIA-Linux-x86_64-396.44.run
NVIDIA_DRIVER_VERSION=396.44 NVIDIA_DRIVER_DOWNLOAD_URL=http://cn.download.nvidia.com/tesla/396.44/NVIDIA-Linux-x86_64-396.44.run bash nvidia-gpu-installer.sh
```


