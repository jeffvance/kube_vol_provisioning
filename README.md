# Provisioning Gluster Volumes for Kubernetes

The newvol.sh script creates and starts a new gluster volume (after ensuring that the underlying bricks are mounted on an xfs file system), creates a yaml file representing the new storage capacity, and executes kubectl to make the new storage visible to kubernetes.

## Usage:

```
 newvol.sh [--replica <r>] [--kube-master <node> ] [--volname <name>] \
           [-f <yaml>] --size <n>  <nodeSpecList>

  r | replica count for each volume, default=2
  node | name of kube-master node, default is localhost
  name | volume name, default is a random name
  n | size of volume to be provisioned to kubernetes
  nodeSpecList | list of node:brick-mnt-path:brick-dev-path ...

```
