# qcguy-ghost

Ghost CMS on Kubernetes, backed by an in-cluster MySQL 8 StatefulSet.

**Docs**
- [`RESTORE.md`](RESTORE.md) — disaster recovery: restoring qcguy on a fresh host from backups
- [`VAULT-SECRETS.md`](VAULT-SECRETS.md) — how the Ghost config/secrets flow through Vault
- [`docs/superpowers/specs/`](docs/superpowers/specs/) · [`docs/superpowers/plans/`](docs/superpowers/plans/) — SQLite→MySQL migration design + plan

---

kubectl create namespace qcguy --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap qcguy-configmap --from-file=./config -n qcguy 

kubectl get events -n qcguy

kubectl get configmaps -n qcguy

kubectl describe configmap qcguy-config -n qcguy

kubectl delete pvc -n qcguy qcguy-content

kubectl delete pvc -n qcguy pv-qcguy

kubectl get pv -n qcguy 

kubectl exec -it -n ingress-nginx ingress-nginx-controller-5f66978484-g5fkn cat /etc/nginx/nginx.conf

docker cp images/size/w400/2021/12/. minikube:/mnt/data/images/size/w400/2021/12

docker cp images/size/w750/2021/12/. minikube:/mnt/data/images/size/w750/2021/12

docker cp images/size/w960/2021/12/. minikube:/mnt/data/images/size/w960/2021/12

docker cp images/size/w1140/2021/12/. minikube:/mnt/data/images/size/w1140/2021/12

docker cp images/size/w1920/2021/12/. minikube:/mnt/data/images/size/w1920/2021/12


"security": {
"staffDeviceVerification": false
},