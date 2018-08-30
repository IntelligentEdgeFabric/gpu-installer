# gpu-installer

## nvidia gpu installer

### requirements
1. nvidia gpu card inserted
2. docker service already started
3. by now centos 7.X and ubuntu 16.04+ are supported
### install

```sh
# simple run with default version 384.111, default download url https://us.download.nvidia.com/tesla/384.111/NVIDIA-Linux-x86_64-384.111.run
bash nvidia-gpu-installer.sh

# run with driver version 396.44, default download url https://us.download.nvidia.com/tesla/396.44/NVIDIA-Linux-x86_64-396.44.run
NVIDIA_DRIVER_VERSION=396.44 bash nvidia-gpu-installer.sh

# run with driver version 396.44 and download url http://cn.download.nvidia.com/tesla/396.44/NVIDIA-Linux-x86_64-396.44.run
NVIDIA_DRIVER_VERSION=396.44 NVIDIA_DRIVER_DOWNLOAD_URL=http://cn.download.nvidia.com/tesla/396.44/NVIDIA-Linux-x86_64-396.44.run bash nvidia-gpu-installer.sh
```

