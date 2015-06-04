# Provisioning Red Hat Gluster Storage Volumes for Kubernetes
Kubernetes supports persistent storage via a pool of volumes with defined capacities, and claims against this storage pool. Pods needing persistent storage reference a claim name and are alloted the storage defined by that claim. Neither the claim nor the pod cares about the underlying storage mechanism.

Red Hat Gluster Storage (RHGS) volumes can be used as an underlying storage system. An advantage of using distributed storage in a kubernetes deployment is that all pods can have access to the same storage regardless of which node they are scheduled to run on.

The steps below describe how to make RHGS storage available to the kubernetes volume pool, how to create a claim against that storage, how to create two pods sharing that storage, and how to test that it is all working correctly. You'll need kubernetes version 0.18+ for persistent gluster volumes to work correctly. There is also a script, shown in the addendum, which automates the creation of a RHGS volume and assoicated YAML files so that the volume is available to kubernetes.

###Create a Red Hat Gluster Storage Volume
It is assumed that you have a RHGS volume available. If not please follow the steps outlined in the *Red Hat Storage Administration Guide*, here: https://access.redhat.com/documentation/en-US/Red_Hat_Storage/3/html/Administration_Guide/chap-Red_Hat_Storage_Volumes.html

### Create Endpoints Defining the Volume Topology
Endpoints allow kubernetes to expose various services and to extend its REST API to include non-standard verbs. For RHGS volumes, endpoints define each storage node in the trusted pool. Here is a sample endpoint YAML file:

file: *gluster-endpoints.yaml*
```
kind: Endpoints
apiVersion: v1beta3
metadata:
  name: glusterfs-cluster
subsets:
  -
    addresses:
      - IP: 192.168.122.21 #ip of 1st storage node
    ports:
      - port: 1            #port number is ignored but specified
        protocol: TCP
  -
    addresses:
      - IP: 192.168.122.22 #ip of 2nd storage node
    ports:
      - port: 1
        protocol: TCP
```
The endpoints are created and visible via *kubectl* as follows:
```
kubectl create -f gluster-endoints.yaml

kubectl get endpoints gluster-cluster
NAME                ENDPOINTS
glusterfs-cluster   192.168.122.21:1,192.168.122.22:1
```

###Create a Persistent Volume
For background information on kubernetes persistent volumes and storage claims see: https://github.com/GoogleCloudPlatform/kubernetes/tree/master/examples/persistent-volumes

After you have created a RHGS distributed volume the next step is to make that storage known to kubernetes. The following YAML file defines the RHGS volume:

file: *gluster-pv.yaml*
```
apiVersion: v1beta3
kind: PersistentVolume
metadata:
  name: pv0001   #a name of your choice
spec:
  capacity:
    storage: 2Gi #the size of the rhgs volume to be allocated to kubernetes
  accessModes:
    - ReadWriteMany
  glusterfs:
    path: HadoopVol              #name of a RHGS volume
    endpoints: glusterfs-cluster #name of previously created endpoints
    readOnly: false
```
The persistent volume (pv) is created and visible via *kubectl* as follows:
```
kubectl create -f gluster-pv.yaml 
persistentvolumes/pv0001

kubectl get pv
NAME      LABELS    CAPACITY     ACCESSMODES   STATUS      CLAIM
pv0001    <none>    2147483648   RWX           Available   
```
Note that the size of the PV is 2Gi and that its status is "Available". Once a claim against some (or all) of this storage is created the status will change to "Bound".

###Create a Persistent Volume Claim
After you have created a persistent volume the next step is to create a claim against a portion of the persistent volume. The following YAML defines a claim for 1Gi of persistent storage.

file: *glusterfs-claim.yaml*
```
kind: PersistentVolumeClaim
apiVersion: v1beta3
metadata:
  name: myclaim-1  #a name of your choice
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi  #only 1Gi is being claimed here
```
The persistent volume claim (pvc) is created and visible via *kubectl* as follows:
```
kubectl create -f gluster-claim.yaml 
persistentvolumeclaims/myclaim-1

kubectl get pvc myclaim-1
NAME        LABELS    STATUS    VOLUME
myclaim-1   map[]     Bound     pv0001
```
Note that the size of the PVC is only 1Gi and that the status is now shown as "Bound".

###Create the First Pod Using RHGS Storage
Once the claim (PVC) is bound to a persistent storage volume (PV) the next step is to create a pod to access that storage. The YAML file below creates such a pod. It runs a nginx container with a mount defined as  "/usr/share/nginx/html/test". The document root for nginx is typically "/usr/share/nginx/html" so only files in the "test" directory under the document root will be accessed from our RHGS volume. The nginx container listens on port 80 and defines a volume mount named "mypd" (my-persistent-disk) which uses the previously created "myclaim-1" claim. 

file: *gluster-nginx.yaml*
```
kind: Pod
apiVersion: v1beta3
metadata:
  name: mypod
  labels:
    name: frontendhttp
spec:
  containers:
    - name: myfrontend
      image: fedora/nginx
      ports:
        - containerPort: 80
          name: http-server
      volumeMounts:
      - mountPath: /usr/share/nginx/html/test
        name: mypd
  volumes:
    - name: mypd
      persistentVolumeClaim:
        claimName: myclaim-1

```
The pod is created and visible via *kubectl* as follows:
```
kubectl create -f gluster-nginx.yaml 
pods/mypod

kubectl get pod mypod
POD       IP        CONTAINER(S)   IMAGE(S)       HOST      LABELS              STATUS    CREATED     MESSAGE
mypod                                             f21-3/    name=frontendhttp   Pending   5 seconds   
                    myfrontend     fedora/nginx     

```
Note that the pod's status is "Pending" because it takes time for the nginx image to be pulled from the docker registry, afterwich the volume claim will be statisfied by mounting the volume on the node hosting the pod (which is "f21-3", seen above).

After a few minutes we see that the pod's status is "Running".
```
kubectl get pod mypod
POD       IP           CONTAINER(S)   IMAGE(S)       HOST      LABELS              STATUS    CREATED          MESSAGE
mypod     172.17.0.1                                 f21-3/    name=frontendhttp   Running   2 minutes        
                       myfrontend     fedora/nginx                                 Running   About a minute 
```

###Create the Second Pod Using RHGS Storage
The YAML file below creates an httpd-server pod with the mount defined as "/usr/local/apache2/htdocs/test". The document root for httpd is typically "/usr/local/apache2/htdocs" so only files in the "test" directory under the document root will be accessed from our RHGS volume. The httpd container also listens on port 80 (but will not conflict with nginx since internally they are using different ports), and defines a volume mount with the same "mypd" name (though it could be any name). This pod shares the same storage claim as the nginx pod, "myclaim-1". 

file: *gluster-httpd.yaml*
```
kind: Pod
apiVersion: v1beta3
metadata:
  name: my-httpd
  labels:
    name: httpd
spec:
  containers:
    - name: myhttpd-front
      image: httpd
      ports:
        - containerPort: 80
          name: httpd-server
      volumeMounts:
      - mountPath: /usr/local/apache2/htdocs/test
        name: mypd
  volumes:
    - name: mypd
      persistentVolumeClaim:
        claimName: myclaim-1
```
The pod is created and visible via *kubectl* as follows:
```
kubectl create -f gluster-httpd.yaml 
pods/my-httpd

kubectl get pod my-httpd
POD        IP           CONTAINER(S)    IMAGE(S)   HOST      LABELS       STATUS    CREATED      MESSAGE
my-httpd   172.17.0.4                              f21-2/    name=httpd   Running   52 minutes   
                        myhttpd-front   httpd                             Running   52 minutes   

```
The *kubectl describe pod* command provides more details about a specific pod and can be useful for understanding why a pod is not running.

```
kubectl describe pod my-httpd

Name:				my-httpd
Image(s):			httpd
Node:				f21-2/
Labels:				name=httpd
Status:				Running
Replication Controllers:	<none>
Containers:
  myhttpd-front:
    Image:		httpd
    State:		Running
      Started:		Thu, 04 Jun 2015 12:36:18 -0700
    Ready:		True
    Restart Count:	0
Conditions:
  Type		Status
  Ready 	True 
No events.
```
If there were issues running the "my-httpd" pod then error events would be displayed at the end of the output.


###Prove it's Working
We will show that the pods have been mounted to access the RHGS volume and that a file ("index.html") on that volume is available to both pods.

First note the IP addresses and nodes for each pod:
```
kubectl get pod
POD        IP           CONTAINER(S)    IMAGE(S)       HOST      LABELS              STATUS    CREATED         MESSAGE
my-httpd   172.17.0.4                                  f21-2/    name=httpd          Running   About an hour   
                        myhttpd-front   httpd                                        Running   About an hour   
mypod      172.17.0.3                                  f21-3/    name=frontendhttp   Running   25 minutes      
                        myfrontend      fedora/nginx                                 Running   24 minutes 
```
The nginx pod ("mypod") is running on the "f21-3" node with an ip address of 172.17.0.3, while the httpd pod ("my-httpd") is running on the "f21-2" node with an ip address of 172.17.0.4.

First, on any one of the RHGS storage nodes we see that the volume ("HadoopVol") is mounted on "/mnt/glusterfs/HadoopVol", and that we've created a file there named "index.html":
```
ssh rhs-1.vm #192.168.122.21

mount | grep glusterfs
rhs-1.vm:/HadoopVol on /mnt/glusterfs/HadoopVol type fuse.glusterfs (rw,default_permissions,allow_other,max_read=131072)

cat /mnt/glusterfs/HadoopVol/index.html

<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="Content-Type" content="text/html;charset=utf-8"/>
  </head>
  <body>
    <div id="body">
    <p>Test paragraph...</p>
  </body>
</html>
```
Next, we ssh into f21-3 to look at the nginx container and to verify that the glusterfs mount is present. Lastly, we access the index.html file residing on the RHGS volume.

On the "f21-3" node get the container id using *docker ps*:
```
ssh f21-3

docker ps
CONTAINER ID        IMAGE                                  COMMAND             CREATED             STATUS              PORTS               NAMES
3d3397bf69eb        fedora/nginx:latest                    "/usr/sbin/nginx"   3 minutes ago       Up 3 minutes                            k8s_myfrontend.32ed1327_mypod_default_6cee84e0-0a37-11e5-bb68-5254007d1adf_c524f139   
8cc34564272c        gcr.io/google_containers/pause:0.8.0   "/pause"            3 minutes ago       Up 3 minutes                            k8s_POD.fa30ecd5_mypod_default_6cee84e0-0a37-11e5-bb68-5254007d1adf_bfc1f373    
```
We see that the container id is "3d3397bf69eb". We shell into this container to see the RHGS mount and to *cat* the index.html file, as follows:
```
# still on f21-3:
docker exec -it 3d3397bf69eb /bin/bash
## now we're running bash from within the container

bash-4.3# mount | grep gluster
192.168.122.21:HadoopVol on /usr/share/nginx/html/test type fuse.glusterfs (rw,relatime,user_id=0,group_id=0,default_permissions,allow_other,max_read=131072)

bash-4.3# cat /usr/share/nginx/html/test/index.html
<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="Content-Type" content="text/html;charset=utf-8"/>
  </head>
  <body>
    <div id="body">
    <p>Test paragraph...</p>
  </body>
</html>

bash-4.3# exit
```
Above we see that the RHGS volume (named "HadoopVol"), which was made available to the kubernetes persistent volume, has been mounted within the container executing inside the "mypod" pod. We also see that "/usr/share/nginx/html/test" is the target of the mount point. And, we have accessed the index.html file, on the RHGS volume, using *cat*. 

We can also use *curl <ip-of-target-pod>* to fetch the same file:
```
ssh f21-3 #same kubernetes node running the pod

curl 172.17.0.3:80/test/index.html
<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="Content-Type" content="text/html;charset=utf-8"/>
  </head>
  <body>
    <div id="body">
    <p>Test paragraph...</p>
  </body>
</html>
```

We can ssh into f21-2, where the httpd pod is running, and perform the same steps to show that the RHGS volume has been mounted in the pod's container and that the index.html file can be accessed, just as we did on node f21-2. And, as we did above, we can use *curl* to access the index.html file too:
```
ssh f21-2
curl 172.17.0.4:80/test/index.html

<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="Content-Type" content="text/html;charset=utf-8"/>
  </head>
  <body>
    <div id="body">
    <p>Test paragraph...</p>
  </body>
</html>

```

Note: to access files on the RHGS volume from a node other than the node where the pod is running requires a network overlay, such as flannel, and is beyond the scope of this document.


##Addendum
To help automate the creation of a RHGS volume and the creation of the endpoints and persistent volume (pv) YAML files, a script named *newvol.sh* is provided.

The *newvol.sh* script performs the following:

* optionally creates a new gluster volume if the supplied volume does not exist
in the trusted storage pool,
* if the volume is new:
 * ensures that the underlying bricks are mounted on an xfs file system.
 * creates and starts a new gluster volume.
* creates an endpoints yaml file representing the glusterfs storage nodes. This file is named "*vname*-endpoints.yaml".
* creates a persistent volume (pv) yaml file representing the new storage capacity. This file is named "*vname*-pv.yaml".
* executes kubectl to make the new storage visible to kubernetes.

### Usage:

```
 newvol.sh [--replica <r>] [--kube-master <node> ] [--volname <vname>] \
           --size <n>  <nodeSpec | storage-node>
```
  arg | meaning and default
  :-: | ------------------
  r | replica count for each volume, default=2.
  node | name of kube-master node, default is localhost
  vname | volume name, default is a random 16 character name starting with an uppercase letter.
  n | size of volume to be provisioned to kubernetes, eg. 20Gi.
  nodeSpec | list of storage-node:brick-mnt-path:brick-dev-path if *vname* is new. Eg. *"rhs-node-1:/mnt/brick:/dev/vg1/lv1 rhs-node-2:/mnt/brick:/dev/vg1/lv1 ..."*. If *vname* already exists then just a single storage node spanned by *vname* is required.

The endpoints yaml file is named "*vname*-endpoints.yaml" and the persistent volume yaml file is named  "*vname*-pv.yaml". So, if the supplied volume name is "MyVol" then the endpoints file will be named "MyVol-endpoints.yaml" and the PV file will be named "MyVol-pv.yaml". These files are overwritten if they already exist.
