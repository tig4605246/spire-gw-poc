"""Check live Gateway API conditions and the generated workload contract."""
import json
import sys


def current_condition(conditions, kind, generation):
    return any(c.get("type") == kind and c.get("status") == "True"
               and c.get("observedGeneration") == generation for c in conditions)


def check(resources):
    def one(kind, zone, name):
        matches = [o for o in resources if o["kind"] == kind
                   and o["metadata"].get("namespace") == zone
                   and o["metadata"]["name"] == name]
        assert len(matches) == 1, (kind, zone, name, "expected exactly one object")
        return matches[0]

    accounts = {}
    for zone in ("zone-a", "zone-b"):
        gateway = one("Gateway", zone, "zone-gateway")
        generation = gateway["metadata"]["generation"]
        assert gateway["spec"]["gatewayClassName"] == "istio", gateway["spec"]
        conditions = gateway.get("status", {}).get("conditions", [])
        for condition in ("Accepted", "Programmed"):
            assert current_condition(conditions, condition, generation), (zone, condition, conditions)
        for route_name, section in (("call-remote-zone", "http-call-entry"),
                                    ("protected-local-app", "https-protected")):
            route = one("HTTPRoute", zone, route_name)
            parents = [p for p in route.get("status", {}).get("parents", [])
                       if p.get("controllerName") == "istio.io/gateway-controller"
                       and p["parentRef"]["name"] == "zone-gateway"
                       and p["parentRef"].get("namespace", zone) == zone
                       and p["parentRef"].get("sectionName") == section]
            assert len(parents) == 1, (zone, route_name, "missing route parent", parents)
            for condition in ("Accepted", "ResolvedRefs"):
                assert current_condition(parents[0].get("conditions", []), condition,
                                         route["metadata"]["generation"]), (zone, route_name, parents)

        deployment = one("Deployment", zone, "zone-gateway-istio")
        service = one("Service", zone, "zone-gateway-istio")
        # These are documented defaults, but drift must fail explicitly.
        account = deployment["spec"]["template"]["spec"]["serviceAccountName"]
        assert account == "zone-gateway-istio", (zone, "unexpected generated account", account)
        sa = one("ServiceAccount", zone, account)
        accounts[zone] = account
        for obj in (deployment, service, sa):
            assert any(r.get("uid") == gateway["metadata"]["uid"]
                       and r.get("kind") == "Gateway" and r.get("controller") is True
                       for r in obj["metadata"].get("ownerReferences", [])), (zone, obj["kind"], "not Gateway-owned")
        assert deployment["spec"]["replicas"] == 1, (zone, "expected single replica")
        status = deployment.get("status", {})
        assert status.get("observedGeneration") == deployment["metadata"]["generation"], status
        assert status.get("readyReplicas") == status.get("updatedReplicas") == 1, status
        pods = [p for p in resources if p["kind"] == "Pod"
                and p["metadata"].get("namespace") == zone
                and not p["metadata"].get("deletionTimestamp")
                and p["metadata"].get("labels", {}).get("spiffe.io/spire-managed-identity") == "true"
                and p["metadata"].get("labels", {}).get("gateway.networking.k8s.io/gateway-name") == "zone-gateway"]
        assert len(pods) == 1, (zone, "expected one managed Gateway Pod", len(pods))
        pod = pods[0]
        assert any(c["type"] == "Ready" and c["status"] == "True"
                   for c in pod.get("status", {}).get("conditions", [])), (zone, "Gateway Pod not Ready")
        spec = pod["spec"]
        labels = pod["metadata"]["labels"]
        assert labels.get("app.kubernetes.io/component") == "zone-gateway", labels
        assert labels.get("security.poc.example/zone") == zone, labels
        assert spec["serviceAccountName"] == account, (zone, spec["serviceAccountName"], account)
        assert spec["nodeSelector"]["security.poc.example/gateway-zone"] == zone, spec.get("nodeSelector")
        assert service["spec"]["type"] == "ClusterIP", service["spec"]
        assert all(labels.get(k) == v for k, v in service["spec"]["selector"].items()), service["spec"]
        assert {8080, 8443} <= {p["port"] for p in service["spec"]["ports"]}, service["spec"]
        containers = spec["containers"]
        assert len(containers) == 1 and containers[0]["name"] == "istio-proxy", containers
        socket = next(v for v in spec["volumes"] if v["name"] == "workload-socket")
        assert socket.get("csi", {}).get("driver") == "csi.spiffe.io" and "emptyDir" not in socket, socket
        assert socket["csi"].get("readOnly") is True, socket
        mounts = [m for m in containers[0]["volumeMounts"] if m["name"] == "workload-socket"]
        assert mounts == [{"name": "workload-socket", "mountPath": "/run/secrets/workload-spiffe-uds", "readOnly": True}], mounts
        print(f"VERIFIED Gateway zone={zone} Programmed=True routes=Accepted,ResolvedRefs account={account} pod={pod['metadata']['name']}")

    for source, destination in (("zone-a", "zone-b"), ("zone-b", "zone-a")):
        rule = one("DestinationRule", source, f"{destination}-gateway-mtls")
        assert rule["spec"]["host"] == f"zone-gateway-istio.{destination}.svc.cluster.local", rule
        settings = next(p for p in rule["spec"]["trafficPolicy"]["portLevelSettings"] if p["port"]["number"] == 8443)
        assert settings["tls"] == {"mode": "ISTIO_MUTUAL", "subjectAltNames": [
            f"spiffe://poc.example/ns/{destination}/sa/{accounts[destination]}"]}, settings
        assert settings["connectionPool"]["http"]["maxRequestsPerConnection"] == 1, settings


if __name__ == "__main__":
    check(json.load(sys.stdin)["items"])
