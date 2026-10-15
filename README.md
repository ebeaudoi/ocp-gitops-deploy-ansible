# ocp-gitops-deploy-ansible

GitOps Kustomize manifests to deploy **Red Hat Ansible Automation Platform (AAP)** on OpenShift.

## Index

| Path | Description |
|------|-------------|
| [`ansible/`](ansible/) | AAP operator + `AnsibleAutomationPlatform` instance |
| [`ansible/README.md`](ansible/README.md) | Deploy steps, overlays, layout, and troubleshooting for AAP |
| [`ansible/update-values.sh`](ansible/update-values.sh) | Patch lab overlay channels, catalogs, and Hub settings |
| [`ansible/argoCD/`](ansible/argoCD/) | AppProject `appansible`, Applications, and AAP RBAC for the GitOps controller |

## Quick start

Manual:

```bash
oc apply -k ansible/operator/overlays/lab/
# wait for CSV Succeeded

oc apply -k ansible/instance/overlays/lab/
```

Via Argo CD (project + apps):

```bash
oc apply -k ansible/argoCD/
```

See [`ansible/README.md`](ansible/README.md) for full details and **Troubleshooting**
(Argo CD `applications.argoproj.io` commands, OutOfSync / diff).
