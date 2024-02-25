# kube-mdns

This Python program, deployed as a container in Kubernetes, enables the automatic publishing of mDNS (Multicast DNS) records based on Ingress resources within your local network without manipulating your local DNS Server. It automatically checks for changes in your ingresses and will add / remove mDNS records.

![Example how it works](docs/example.gif)

## How to use
If you want to have an mDNS record for one of your ingresses, you just need to add ".local" to the host of the ingress rule set.

![Example Ingress Yaml](https://imgur.com/kTKdoyl.jpg)

After applying, the pod should be able to recognize the change and will publishing the address 

![Example Log of kube-mdns](https://imgur.com/AssZkf0.jpg)

### Manual entries
Manual entries can also be added using a predefined json file. 
```
[
    {
        "hostname": "homeassistant.local",
        "ip": "192.168.1.101",
        "port": 443, // optional
        "service_type": "_https._tcp.local." // optional
    },
    {
        "hostname": "paperless.local",
        "ip": "192.168.1.120"
    },
    // ...
    // add more json objects like above
]
```
You can add this config with a config map to the deployment.

With the startargument `--config <Path of config.json>` the entries can be added at startup.

### Port selection
kube-mdns will check in the loadBalancer entry of the Ingress object, if the ip also have any ports. It will search for port 443 first and then for port 80. When both not found, it will just use the first port of the list.

If no ports are found in Ingress, it will automatically use 443 as default port. 

You can specify the default port by adding `--port <port-int>` as startargument.

### Servicetype selection
The default servicetype is `_http._tcp.local.`. You can specifiy a different service type by adding `--service-type <service-type>` as start argument.

### Specify interface
By default, kube-mdns will choose the default interface of the pod for broadcasting mDNS requests. You can add `--interface <interface-name>` as startargument to choose manual interface (e.g. using Multus to inject an network interface).

## (Current) Limitations
The program is currently at an early stage. Don't expect too much, currently it works for my needs in my local setup, but I will try to implement some of the still missing features.

- [x] ~~Gets only one load balancer IP for mDNS publishing~~ Implemented with `feature-1`
- [x] ~~No configuration for predefining mDNS entries in your network~~ Implemented with `feature-3`
- [ ] Only works for .local top level domain
- [ ] No configuration through annotations in ingress yaml
- [x] ~~Uses only port 80~~ Implemented with `feature-4-use-port-depending-on-ingress-service`
- [ ] Currently only works with a pod, no database in the background

## How to install
Before you can run kube-mdns, first you need to add a ClusterRole, a ClusterRoleBinding and a ServiceAccount, wihch gives kube-dns the sufficient permissions to access the kubernetes events.

```
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-mdns-clusterrole
rules:
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["extensions","networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-mdns-clusterrolebinding
subjects:
- kind: ServiceAccount
  name: kube-mdns-service-account
  namespace: default
roleRef:
  kind: ClusterRole
  name: kube-mdns-clusterrole
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-mdns-service-account
```

After this, you can deploy kube-mdns in your Kubernetes environment.

```
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kube-mdns
  labels:
    app: kube-mdns
spec:
  selector:
    matchLabels:
      app: kube-mdns
  replicas: 1
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: kube-mdns
    spec:
      serviceAccountName: kube-mdns-service-account
      hostNetwork: true
      containers:
        - image: ghcr.io/dersteph/kube-mdns:latest
          name: kube-mdns
          imagePullPolicy: Always
      restartPolicy: Always
```