# Mosquitto: hydroflow -> infra namespace cutover

WP5 moves the shared MQTT broker out of the `hydroflow` namespace into a new
`infra` namespace, since it is no longer hydroflow-specific — it is consumed
by chickenflow (ESP32 door sensors, hardcoded to LB IP 192.168.100.207),
hydroflow-backend, and gpu-inference (mqtt-inference-worker).

**The LoadBalancer IP 192.168.100.207 is immovable** (hardcoded into the
ESP32 firmware, not just DNS) and **the hostPath-backed PV
(`/mnt/frigate/mosquitto` on k3frigate) must survive the move** so retained
messages / the persistence DB aren't lost. Both constraints mean this is not
a simple "apply new, delete old" — the IP and the PV can each only be held by
one Service/PVC at a time, so there is a required order and a brief broker
downtime window.

## Apply / cutover order

1. **Apply the new namespace + ConfigMap** (safe at any time, no conflicts):
   ```
   kubectl apply -f apps/infra-mosquitto/namespace.yaml
   kubectl apply -f apps/infra-mosquitto/cm-mosquitto-config.yaml
   ```

2. **Stop the old broker cleanly** (avoid mid-write corruption of the
   persistence DB on the shared hostPath):
   ```
   kubectl delete deploy mosquitto -n hydroflow
   ```

3. **Release the LB IP.** Deleting the old Service returns 192.168.100.207 to
   MetalLB's pool. **This starts the broker-downtime window** — ESP32 sensors,
   hydroflow-backend, and mqtt-inference-worker all lose their MQTT connection
   here:
   ```
   kubectl delete svc mosquitto -n hydroflow
   ```

4. **Release the PV so it can be re-bound.** Delete the old PVC, then clear
   its stale `claimRef` on the PV (a Retain-policy PV doesn't auto-clear this
   on PVC deletion — it goes to `Released`, not `Available`, and won't bind a
   new claim until the claimRef is removed):
   ```
   kubectl delete pvc mosquitto-pvc -n hydroflow
   kubectl patch pv mosquitto-pv --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]'
   ```
   (Skip the patch if `claimRef` is already absent — check with
   `kubectl get pv mosquitto-pv -o yaml` first.)

5. **Apply the new PV/PVC, Deployment, and Service in infra:**
   ```
   kubectl apply -f apps/infra-mosquitto/pvc-stub.yaml
   kubectl apply -f apps/infra-mosquitto/deploy.yaml
   kubectl apply -f apps/infra-mosquitto/svc.yaml
   ```
   `pvc-stub.yaml` defines the *same* PV (`mosquitto-pv`, same hostPath) plus
   a new namespaced PVC (`infra/mosquitto-pvc`) that binds to it via
   `volumeName`. `svc.yaml` requests the now-free 192.168.100.207 — MetalLB
   should assign it immediately since there's no competing claim.

6. **Verify:**
   ```
   kubectl get svc -n infra mosquitto     # EXTERNAL-IP should read 192.168.100.207
   kubectl logs -n infra deploy/mosquitto # watch for reconnecting clients
   ```
   ESP32 firmware auto-reconnects on its own (existing documented behavior),
   as should hydroflow-backend's and mqtt-inference-worker's MQTT clients —
   this hasn't been verified in this WP and is worth a spot-check after
   cutover.

7. **Remove the old namespace's leftovers** (ConfigMap; Deployment/Service/
   PVC are already gone from steps 2-4):
   ```
   kubectl delete cm mosquitto-config -n hydroflow
   ```
   The `apps/hydroflow-mosquitto/` manifests have already been deleted from
   this repo as part of WP5 — nothing left to re-apply from there.

## Downtime

Expected downtime is the window between step 3 (old Service deleted, IP
released) and step 5's Service apply completing + MetalLB assigning the IP —
on the order of seconds to low tens of seconds depending on MetalLB speaker
convergence. All known consumers reconnect automatically; no manual
intervention needed on the client side.

## Data / retained-message implications

`persistence true` / `persistence_location /mosquitto/data/` is enabled, so
retained topics and queued QoS>0 messages live in the persistence DB under
the hostPath. Because this move reuses the **same** PV object and the
**same** hostPath directory (only the PVC's namespace changes), that DB is
untouched by this migration and retained messages survive — *provided* the
PV object itself is not deleted (only its PVC/claimRef is) and the hostPath
directory on k3frigate is not touched. If the PV were deleted and recreated
from scratch, or the hostPath directory were wiped, retained messages would
be lost — same as the prior one6t -> k3frigate migration documented in
`pvc-stub.yaml`, where broker state is expected to rebuild as publishers
reconnect if that ever happens.
