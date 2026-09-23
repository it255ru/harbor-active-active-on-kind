## ⚓ KinD Harbor : Deploy Harbor locally using KinD

### Requirenments
- Linux laptop/workstation
- Docker installed
- Go installed
- `kubectl` installed (matching or within one minor version of the pinned Kubernetes below)

### Pinned versions

This repo pins every moving part explicitly — never install with a floating/latest chart or image. See `backlog.md` for the full migration history; these are the current values `Makefile` / `hack/install.sh` install:

| Component | Pinned version |
|-----------|----------------|
| Kind CLI | `v0.30.0` |
| KinD node image | `kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a` |
| MetalLB chart | `0.16.1` |
| ingress-nginx chart | `4.15.1` (app `1.15.1`) |
| Harbor chart / app | `1.19.2` / `2.15.2` |

If you bump any of these, update `Makefile` / `hack/install.sh` **and** this table together — `helm repo update` alone must never silently move a chart version.

### Harbor Architecture:

<img src="pictures/Harbor-Architecture.png?raw=true" width="800">

### Installing KinD & Harbor on Kubernetes (KinD):

```bash
$ make cluster
# creates kind v0.30.0 cluster "harbor" (context kind-harbor) on node image kindest/node:v1.34.0

$ docker network inspect -f '{{.IPAM.Config}}' kind
[{fc00:f853:ccd:e793::/64  fc00:f853:ccd:e793::1 map[]} {172.20.0.0/16  172.20.0.1 map[]}]

# The subnet Docker actually picked for the "kind" network varies per machine —
# it will NOT always be 172.17.0.0/16 or match the example above. If it differs
# from the Makefile/config default below, update LB_IP + the two YAML files
# together (see "Architecture / coupling" in CLAUDE.md) BEFORE `make add-host`.

Makefile:
LB_IP ?= 172.20.0.100

./hack/config/lb-ipaddresspool.yaml:
spec:
  addresses:
    - 172.20.0.100-172.20.0.110

./hack/config/nginx.yaml:
metallb.universe.tf/loadBalancerIPs: 172.20.0.100

$ make add-host
Adding "core.harbor.domain" to /etc/hosts
$ cat /etc/hosts|tail -n2
# harbor
172.20.0.100	core.harbor.domain
$ make install
# hack/install.sh installs pinned MetalLB 0.16.1, ingress-nginx 4.15.1, Harbor 1.19.2 (app 2.15.2)

$ kubectl get po |grep harb
harbor-core-d9754969d-nl7g5            1/1     Running   0             62m
harbor-database-0                      1/1     Running   0             68m
harbor-jobservice-78bc66d84d-rf2c5     1/1     Running   0             62m
harbor-portal-5c44b6bf64-nsqtw         1/1     Running   0             68m
harbor-redis-0                         1/1     Running   0             68m
harbor-registry-59dc7f8b84-pks5z       2/2     Running   0             62m
harbor-trivy-0                         1/1     Running   0             68m

# Note: no harbor-notary-* pods — Notary was removed from the Harbor chart in 1.19.x.

$ kubectl get svc
NAME                                 TYPE           CLUSTER-IP      EXTERNAL-IP    PORT(S)                      AGE
frr-k8s-webhook-service              ClusterIP      10.96.147.125   <none>         443/TCP                      71m
harbor-core                          ClusterIP      10.96.6.230     <none>         80/TCP                       68m
harbor-database                      ClusterIP      10.96.163.247   <none>         5432/TCP                     68m
harbor-jobservice                    ClusterIP      10.96.114.93    <none>         80/TCP                       68m
harbor-portal                        ClusterIP      10.96.156.255   <none>         80/TCP                       68m
harbor-redis                         ClusterIP      10.96.250.113   <none>         6379/TCP                     68m
harbor-registry                      ClusterIP      10.96.100.222   <none>         5000/TCP,8080/TCP            68m
harbor-trivy                         ClusterIP      10.96.44.188    <none>         8080/TCP                     68m
ingress-nginx-controller             LoadBalancer   10.96.131.116   172.20.0.100   80:30100/TCP,443:32187/TCP   69m
ingress-nginx-controller-admission   ClusterIP      10.96.90.236    <none>         443/TCP                      69m
kubernetes                           ClusterIP      10.96.0.1       <none>         443/TCP                      79m
metallb-webhook-service              ClusterIP      10.96.178.192   <none>         443/TCP                      71m

# frr-k8s-webhook-service is new in MetalLB 0.16.x (bundled FRR-based BGP support); harmless if you only use L2 mode.
```
### Open Browser https://core.harbor.domain and create `python` project (admin:Harbor12345):

<img src="pictures/harbor-create-project.png?raw=true" width="1000">

Setup image vulnarability scanning for the project:

<img src="pictures/harbor-project-python-hello-configure-scan.png?raw=true" width="1000">

Download `python` project REGISTRY CERTIFICATE locally (ca.crt file):

<img src="pictures/harbor-project-python-registry-certificate-download.png?raw=true" width="1000">

### Fast path: `make deploy-app`

Everything from here down — creating the `python` project, trusting the registry, building/pushing the image, trusting Harbor's CA inside the KinD node, creating the pull secret, and deploying the raw-YAML app — is automated by:

```bash
$ make deploy-app
```

It's idempotent (safe to re-run after editing `hello.py`), and the only thing it can't do for you is the one-time host Docker `insecure-registries` change below, which needs an interactive `sudo` password — it'll print the exact commands and stop if that's still missing. The rest of this section walks through what `make deploy-app` does manually, and how to deploy via the `helm-hello-kube` chart or OCI instead.

### Setup laptop docker daemon (docker host): 
```
$ cat /etc/docker/daemon.json
{
    "insecure-registries" : ["core.harbor.domain"]
}
$ sudo systemctl reload docker
```
Merge this into your existing `daemon.json` rather than overwriting it (e.g. `jq '.["insecure-registries"] += ["core.harbor.domain"] | .["insecure-registries"] |= unique' /etc/docker/daemon.json`). Prefer `systemctl reload` over `restart` once the KinD cluster already exists — `restart` stops/restarts the Docker daemon process and can disrupt the running cluster's containers; `reload` (SIGHUP) applies `insecure-registries` without that risk.
### Create docker image and push to Harbor docker registry:
```
$ cd python-docker-hello-kube
$ docker build . -t core.harbor.domain/python/hello:1.0
$ docker login core.harbor.domain (admin:Harbor12345)
$ docker push core.harbor.domain/python/hello:1.0
```

Check Trivy vulnarability scan (CVE count varies by scan date/base image; expect a handful of High/Medium/Low — the demo app's base image is not kept patched, see `backlog.md` "Вне скоупа"):

<img src="pictures/harbor-python-helo-scan-vulnaribilities.png?raw=true" width="1000">

<img src="pictures/harbor-project-python-hello-trivy-SCAN-CVE-2023-30861.png?raw=true" width="1000">


### Setup KinD (ca.crt previously downloaded & /etc/hosts)
```
$ docker ps -a
CONTAINER ID   IMAGE                  COMMAND                  CREATED          STATUS          PORTS                       NAMES
c1a4414010b8   kindest/node:v1.34.0   "/usr/local/bin/entr…"   14 minutes ago   Up 14 minutes   127.0.0.1:44867->6443/tcp   harbor-control-plane

# ca.crt can also be fetched without the UI: curl -sk https://core.harbor.domain/api/v2.0/systeminfo/getcert -o ca.crt
$ docker cp ca.crt harbor-control-plane:/usr/local/share/ca-certificates/
Successfully copied 3.07kB to harbor-control-plane:/usr/local/share/ca-certificates/

$ docker exec -it harbor-control-plane bash
root@harbor-control-plane:/# update-ca-certificates
Updating certificates in /etc/ssl/certs...
rehash: warning: skipping ca-certificates.crt,it does not contain exactly one certificate or CRL
1 added, 0 removed; done.
Running hooks in /etc/ca-certificates/update.d...
done.

root@harbor-control-plane:/# echo "172.20.0.100 core.harbor.domain" >> /etc/hosts
root@harbor-control-plane:/# systemctl restart containerd
```
Restarting `containerd` only restarts the container runtime inside the KinD node — it does not stop already-running pods (verify with `kubectl get nodes` / `kubectl get pods -A` right after).

### Harbor Docker Private registry secret creation

Note: To Pull the image from the private registry, first, we need the create a secret containing the private registry credential. Create a secret object with docker-registry type.

```
$ kubectl create secret docker-registry harbor --docker-server=core.harbor.domain --docker-username=admin --docker-password=Harbor12345 --docker-email=root@testlab.local
secret/harbor created
```

### Deploy python app:
```
$ cat deployment.yml 

apiVersion: v1
kind: Service
metadata:
  name: hello-service
spec:
  selector:
    app: hello
  ports:
  - protocol: "TCP"
    port: 5000
    targetPort: 5000
  type: LoadBalancer

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-deployment
spec:
  selector:
    matchLabels:
      app: hello
  replicas: 2
  template:
    metadata:
      labels:
        app: hello
    spec:
      containers:
      - name: hello
        image: core.harbor.domain/python/hello:1.0
        imagePullPolicy: Always
        ports:
        - containerPort: 5000
        readinessProbe:
          httpGet:
            path: /healthz
            port: 5000
          initialDelaySeconds: 2
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /healthz
            port: 5000
          initialDelaySeconds: 5
          periodSeconds: 10
      imagePullSecrets:
        - name: harbor

$ kubectl apply -f deployment.yml 
service/hello-service created
deployment.apps/hello-deployment created

$ kubectl get po|grep hello
hello-deployment-68684f4cf-5mnjm           1/1     Running   0             12s
hello-deployment-68684f4cf-f2sxv           1/1     Running   0             12s

$ kubectl get svc|grep hello
hello-service                        LoadBalancer   10.96.173.42    172.20.0.101   5000:30430/TCP               64s
$ curl 172.20.0.101:5000
Hello, Kube! (from hello-deployment-68684f4cf-f2sxv)
$ curl 172.20.0.101:5000/healthz
ok

To delete deployment

$ kubectl delete deployment hello-deployment
```
`hello.py` is stdlib-only (`http.server`, no pip dependencies) — the response includes the pod's hostname so you can see load-balancing across replicas, and `/healthz` is what the readiness/liveness probes above check.

### Creating a helm chart for the hello-kube application

In this section we will create a basic helm chart for the hello-kube python application and deploy it in the kubernetes cluster.

```
helm create hello-kube
```
This commnad will give the structure for the helm chart and create folder hello-kube. Since we are using a basic helm chart, 
We clean up the files and folderse in the hello-kube and make it in the below structure (helm-hello-kube folder in this repo)

Now we will edit the deployment.yaml file in the templates folder inside hello-kube
```
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-kube
spec:
  selector:
    matchLabels:
      app:  hello-kube
  replicas: {{ .Values.replicaCount }}
  template:
    metadata:
      labels:
        app:  hello-kube
    spec:
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: 5000
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
```
ater we will edit the service.yaml file

```
apiVersion: v1
kind: Service
metadata:
  name: hello-kube
spec:
  selector:
    app: hello-kube
  ports:
  - protocol: "TCP"
    port: {{ .Values.service.port }}
    targetPort: http
  type: {{ .Values.service.type }}
```
Now we will edit the values.yaml file and add our configurations for deployment which will be passed as variable to deployment.yaml and service.yaml files.

```
# Default values for hello-kube.
# This is a YAML-formatted file.
# Declare variables to be passed into your templates.

replicaCount: 1

image:
  repository: core.harbor.domain/python/hello
  pullPolicy: Always
  # Overrides the image tag whose default is the chart appVersion.
  tag: "1.0"

imagePullSecrets: 
  - name: harbor
service:
  type: LoadBalancer
  port: 5000
```
now install the helm chart
```
$ helm install hello-kube hello-kube
```
To delete the deployment

```
$ helm delete hello-kube
```

Package the application as a helm chart and upload it to a harbor helm chart registry.

```
helm package hello-kube
$ helm package hello-kube
Successfully packaged chart and saved it to: /tmp/kind-harbor-playground/hello-kube-0.1.0.tgz

```
### Push Helm Chart to OCI registry:

There are three options how helm charts can be pushed to Harbor

- 1.As you correctly found out yourself, you can install the helm addon chartmuseum/helm-push and use that to push Helm chart to Harbor
- 2.You create the Helm Chart locally with helm package and upload the tgz file via the Harbor UI
- 3.Since version 3.8 Helm support pushing and pulling Charts from OCI compliant container registries such as Harbor.

To be safe for the future, we recommend you switch to option 3, as Chartmuseum is already marked as deprecated in Harbor.

Here is a quick rundown how to push/pull Helm Chart to OCI compliant Registries
```
Before pulling or pushing Helm charts with the OCI-compatible registry of Harbor, Harbor should be logged with helm registry login command.

$ helm registry login -u admin --ca-file ./ca.crt https://core.harbor.domain
Password: 
Login Succeeded

$ helm push --ca-file ./ca.crt hello-kube-0.1.0.tgz oci://core.harbor.domain/python/hello
Pushed: core.harbor.domain/python/hello/hello-kube:0.1.0
Digest: sha256:688a0df8b5da0e8d79d24952feca765b2def730b540364ea38e7dc41fb4287c1
```

<img src="pictures/harbor-OCI-chart-hello-kube.png?raw=true" width="1000">

Pull and Install Helm Chart from OCI registry:

```
$ helm pull --ca-file ../ca.crt oci://core.harbor.domain/python/hello/hello-kube --version 0.1.0
Pulled: core.harbor.domain/python/hello/hello-kube:0.1.0
Digest: sha256:688a0df8b5da0e8d79d24952feca765b2def730b540364ea38e7dc41fb4287c1
$ ls
hello-kube-0.1.0.tgz
$ helm install hello-kube ./hello-kube-0.1.0.tgz 
NAME: hello-kube
LAST DEPLOYED: Thu Sep 24 01:38:08 2026
NAMESPACE: default
STATUS: deployed
REVISION: 1

$ kubectl get po|grep hell
hello-kube-65f5f8bcf9-759q6                 1/1     Running   0             13s
$ kubectl get svc|grep hello-kube
hello-kube                           LoadBalancer   10.96.107.237   172.20.0.101   5000:30746/TCP               13s
$ curl 172.20.0.101:5000
Hello, Kube! (from hello-kube-65f5f8bcf9-759q6)

$ helm delete hello-kube
release "hello-kube" uninstalled

Note: This is pulling to tgz file to your current directory.

Unlike with the common approach where you would first add a repo and the pull from it in order to be able to install a Chart
you can do it all in one go with an OCI registry:

$ helm install hello-kube --ca-file ./ca.crt oci://core.harbor.domain/python/hello/hello-kube --version 0.1.0
Pulled: core.harbor.domain/python/hello/hello-kube:0.1.0
Digest: sha256:688a0df8b5da0e8d79d24952feca765b2def730b540364ea38e7dc41fb4287c1
NAME: hello-kube
LAST DEPLOYED: Thu Sep 24 01:38:08 2026
NAMESPACE: default
STATUS: deployed
REVISION: 1

$ kubectl get po|grep hello
hello-kube-65f5f8bcf9-759q6                 1/1     Running   0             13s
$ helm list
NAME         	NAMESPACE	REVISION	UPDATED                                 	STATUS  	CHART               	APP VERSION
harbor       	default  	2       	2026-09-24 00:46:18.569307669 +0300 MSK	deployed	harbor-1.19.2       	2.15.2
hello-kube   	default  	1       	2026-09-24 01:38:08.000000000 +0300 MSK	deployed	hello-kube-0.1.0    	1.16.0
ingress-nginx	default  	1       	2026-09-24 00:39:14.804871195 +0300 MSK	deployed	ingress-nginx-4.15.1	1.15.1
metallb      	default  	2       	2026-09-24 00:39:11.796354928 +0300 MSK	deployed	metallb-0.16.1      	v0.16.1

Same procedure for template and upgrade

The oci:// protocol is also available in various other subcommands. Here is a complete list:

helm pull
helm show
helm template
helm install
helm upgrade

The Helm documentation has a https://helm.sh/docs/topics/registries/

```


### Clean env:
```
make cluster-delete
```

[Credits](https://github.com/mmontes11/harbor-kind) 
