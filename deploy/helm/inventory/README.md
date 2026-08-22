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

1. Override the four dev secrets (`postgresPassword`, `busToken`,
   `adminEmail`, `adminPassword`) and set `image.tag` to a release version.
   (Images are public on Docker Hub — no pull secret needed.)

```sh
helm install inventory deploy/helm/inventory \
  --set image.tag=0.1.0 --set busToken=$(openssl rand -hex 24) \
  --set postgresPassword=... --set adminPassword=...
```

## Schema migration

The migrate Job runs the `inventory-migrate` image — Liquibase with the
`inventory-impl-changeset` jar on its classpath — so the changelog arrives
versioned inside the image (changelog-from-jar, PLAN.md Phase 19 step 4).
The old hand-copied `files/changelog/` ConfigMap and its re-copy
maintenance rule are RETIRED: a new changeset ships by releasing a new
image and bumping `image.tag`; the Job applies it on the next
`helm upgrade`, before the apps restart.
