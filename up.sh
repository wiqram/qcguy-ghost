#!/bin/sh

set -e
#echo "in UP.sh >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"-e url=https://www.qcguy.com
#./build.sh

#check if minikube is installed, if not install it with appropriate memory and cpus
if kubectl version; then
    echo "Command succeeded"
#    minikube delete
  else
    echo "Command failed"
    minikube start --cpus 4 --memory 16384
    #minikube start
    #set strictARP to true to allow for MetalLB loadbalancer
    #kubectl get configmap kube-proxy -n kube-system -o yaml | sed -e "s/strictARP: false/strictARP: false/" | kubectl apply -f - -n kube-system
    #To install MetalLB, apply the manifest
    #kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.11.0/manifests/namespace.yaml
    #kubectl apply -f metallb.yaml
    #This will deploy MetalLB to your cluster, under the metallb-system namespace
    #now install metallb config
    #kubectl apply -f metallb-config.yaml
    #
fi
#allow minikube to connect to local docker images
eval $(minikube -p minikube docker-env)
#create k8s namespace for yolo
kubectl create namespace qcguy --dry-run=client -o yaml | kubectl apply -f -
#create configmap for qcguy
kubectl create configmap qcguy-configmap --from-file=./config -n qcguy
#create k8s namespace for qcguy
kubectl apply -f compiled.yaml


#docker run --restart=always --network 5million -d --name qcguy -p 2368:2368 -v /home/vik/IdeaProjects/qcguy-cms/config/config.production.json:/var/lib/ghost/config.production.json -v some-ghost-data:/var/lib/ghost/content ghost