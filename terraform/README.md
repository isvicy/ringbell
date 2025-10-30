# bootstrap instructions

This is a step-by-step instruction on how to bootstrap a Talos Kubernetes cluster using Terraform and **libvirt**.

## vms and talos cluster

```bash
terraform init --upgrade

# Phase 1: create libvirt resources (VMs & disks)
terraform apply \
  -target=libvirt_pool.talos \
  -target=libvirt_volume.talos_base \
  -target=module.controlplanes \
  -target=module.workers

# Phase 2: apply Talos machine configs, install kube-vip, bootstrap etcd, and fetch kubeconfig
terraform apply

terraform output -raw kubeconfig > ~/.kube/config
```

After this step, you should have a working talos kubernetes cluster with kube-vip load balancer.
But you will also find that all nodes are in NotReady state because we have not installed any CNI plugin yet.

## cilium installation
We choose Cilium as the CNI plugin for this cluster. You can choose any other CNI plugin as you like.

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

# This command is from the [official docs](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium?utm_source=chatgpt.com), you can read more details there.
helm install \
    cilium \
    cilium/cilium \
    --version 1.18.0 \
    --namespace kube-system \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=true \
    --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
    --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
    --set cgroup.autoMount.enabled=false \
    --set cgroup.hostRoot=/sys/fs/cgroup \
    --set k8sServiceHost=localhost \
    --set k8sServicePort=7445
```

After Cilium is installed, you should see all nodes in Ready state. Now you have a fully functional Talos Kubernetes cluster!

** BELOW THIS LINE ARE ADDITIONAL FOR MY PERSONAL NEEDS, IGNORE IF NOT NEEDED **
