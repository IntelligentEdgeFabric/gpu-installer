# gpu-installer

## nvidia gpu installer

主要原理是通过docker运行nvidia驱动，使所有的驱动文件安装到一个文件夹下，源自于Google 项目[ubuntu nvidia-driver-installer from google](https://github.com/GoogleCloudPlatform/container-engine-accelerators/tree/master/nvidia-driver-installer/ubuntu).<br>

在此基础上修复了一些问题，增加一些功能：

1. 修复安装时节点卡住问题 [Installer freezes node issue](https://github.com/GoogleCloudPlatform/container-engine-accelerators/issues/80)（不支持aufs，aufs下不支持overlay）.
2. 机器重启后自动加载nvidia驱动.
3. 支持centos.



### 条件
1. 已插入nvidia卡(代码通过lspci检测）
2. docker服务已安装并启动（参考[centos](https://docs.docker.com/install/linux/docker-ce/centos/)/[ubuntu](https://docs.docker.com/install/linux/docker-ce/ubuntu/) 安装docker)，并且能联网拉取镜像(代理环境下可以参考[这里配置docker](https://docs.docker.com/config/daemon/systemd/#httphttps-proxy))
3. 目前支持centos 7.X 和ubuntu 16.04+
4. 网络已通


### 用法

安装目录是/var/IEF/nvidia

#### 安装选项
```sh
# 指定驱动版本号396.44和下载url
NVIDIA_DRIVER_VERSION=396.44 NVIDIA_DRIVER_DOWNLOAD_URL=http://cn.download.nvidia.com/tesla/396.44/NVIDIA-Linux-x86_64-396.44.run bash nvidia-gpu-installer.sh install

# OR: 只指定驱动版本号396.44 
# 注：如果没有指定驱动下载url，脚本会尝试从http://us.download.nvidia.com/XFree86/Linux-x86_64、https://us.download.nvidia.com/tesla检测可用下载url
NVIDIA_DRIVER_VERSION=396.44 bash nvidia-gpu-installer.sh install

# 都不指定，驱动版本号默认为384.111
bash nvidia-gpu-installer.sh install

# OR: 在网络代理情况下
export http_proxy=http://10.90.2.2:808
export https_proxy=http://10.90.2.2:808
bash nvidia-gpu-installer.sh install

# OR: 默认情况下脚本会检测要安装的驱动版本和上次成功安装的版本，如果不一致才进行安装。一些异常情况下请尝试关闭此功能
bash nvidia-gpu-installer.sh install --no-cache-check

# OR: 默认情况下当检测到版本不一致且nvidia驱动已被加载，脚本会提示用户是否尝试卸载驱动。加-y选项不提示用户
bash nvidia-gpu-installer.sh install -y

# OR: 默认情况下脚本会继续使用上次安装失败的容器，这可以避免工具的重新下载，加快安装进度。一些异常情况下请尝试关闭此功能
bash nvidia-gpu-installer.sh install --no-cache-container
```


```sh

# 如果nvidia-smi -L输出错误，请修复
bash nvidia-gpu-installer.sh fix

# 查看一些选项
bash nvidia-gpu-installer.sh -h

# 卸载驱动文件
bash nvidia-gpu-installer.sh clean
```


## 常见问题
1. 检测驱动加载成功的方法
```sh
# 检测内核驱动nvidia和nvidia-uvm已被加载
lsmod |grep -e nvidia -e nvidia-uvm

# 检测设备文件已被创建
ls /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia?

# 运行nvidia-smi工具，查看状态
/var/IEF/nvidia/bin/nvidia-smi

```

2. 重启后驱动没有加载成功
```sh
# 检测加载脚本的状态
systemctl status nvidia-drivers-loader
# 如果发现"Invalid module format"错误，内核版本已改变，请考虑切回原有内核版本或者重新运行此脚本进行安装
```

3. 报"E: Failed to fetch ... Hash Sum mismatch" 错误
<br>网络不稳定，请尝试重新运行此脚本

## 已知问题
通过此脚本安装可能会使图形界面不可用，Ubuntu/Centos某些情况可能出现，但是还不知具体冲突原因。
如果遇到此问题，请尝试以下方法：
1. 查看并安装[GPU卡对应得nvidia官方最新的驱动版本](https://www.nvidia.cn/Download/index.aspx?lang=cn)
2. Ubuntu下可以重装图形界面，可以参考这个[链接](https://www.computersnyou.com/4945/re-install-xorg-xserver-completely-ubuntu/)