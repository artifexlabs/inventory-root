# inventory Helm chart

Reference Kubernetes deployment of the inventory stack (added 2026-08-17;
**unvalidated by decision** — no cluster is available yet;
[deploy/docker-compose.yml](../../docker-compose.yml) remains the executable
reference). One release runs postgres (StatefulSet + PVC), a Liquibase
migrate hook Job, the three clustered bus members as single-replica
Recreate Deployments, and the native web app.

## Cluster fabric translation

Compose pins the bus members to static IPs on an internal network; here each
member binds its **pod IP** (downward API) and JGroups TCPPING discovers
peers through the three ClusterIP **service names** on :7800. Ports 7800
(JGroups) and 15701 (bus transport) exist only as ClusterIP ports — the
never-publish invariant holds; bus membership is access. Healthy = every
member logs `ISPN000094: Received new cluster view ... (3)`.

## Before installing

1. Pull secret for the private GHCR images:
   `kubectl create secret docker-registry ghcr --docker-server=ghcr.io
   --docker-username=<user> --docker-password=<read:packages token>`
2. Override the four dev secrets (`postgresPassword`, `busToken`,
   `adminEmail`, `adminPassword`) and set `image.tag` to a release version.

```sh
helm install inventory deploy/helm/inventory \
  --set image.tag=0.1.0 --set busToken=$(openssl rand -hex 24) \
  --set postgresPassword=... --set adminPassword=...
```

## Changelog copies (maintenance rule)

`files/changelog/` holds COPIES of
`inventory-impl-root/inventory-impl-changeset/src/main/resources/db/**` — compose bind-mounts the
originals, but a cluster has no repo checkout. **When a changeset is added
under inventory-impl-changeset: re-copy it here AND add its volume item in
`templates/migrate-job.yaml`.** The migrate Job then applies it on the next
`helm upgrade`, before the apps restart.
