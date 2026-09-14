"""Static acceptance checks complement the cluster's API/schema validation."""
import pathlib
import subprocess
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
PINS = dict(line.split("=", 1) for line in (ROOT / "versions.env").read_text().splitlines() if "=" in line and not line.startswith("#"))


class UniqueLoader(yaml.SafeLoader):
    pass


def mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        assert key not in result, f"duplicate YAML key: {key}"
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)

for path in sorted(ROOT.glob("config/**/*.yaml")):
    if "template" not in path.name:
        list(yaml.load_all(path.read_text(), Loader=UniqueLoader))

for mode in ("standalone", "istio"):
    rendered = subprocess.check_output(["kubectl", "kustomize", str(ROOT / "deploy" / mode)], text=True)
    objects = [o for o in yaml.load_all(rendered, Loader=UniqueLoader) if o]
    deployments = [o for o in objects if o["kind"] == "Deployment"]
    for zone in ("zone-a", "zone-b"):
        local = [o for o in deployments if o["metadata"].get("namespace") == zone]
        assert {o["metadata"]["name"] for o in local} == {"zone-app", "zone-gateway"}, local
        app = next(o for o in local if o["metadata"]["name"] == "zone-app")["spec"]["template"]
        assert app["metadata"]["annotations"]["sidecar.istio.io/inject"] == "false"
        assert len(app["spec"]["containers"]) == 1
        assert not app["spec"].get("initContainers")
        assert not any("csi" in v or "hostPath" in v for v in app["spec"].get("volumes", []))
        container = app["spec"]["containers"][0]
        assert container["readinessProbe"]["httpGet"].get("scheme", "HTTP") == "HTTP"
        assert not any("SPIFFE" in e["name"] for e in container.get("env", []))
        policies = [o for o in objects if o["kind"] == "NetworkPolicy" and o["metadata"].get("namespace") == zone]
        assert any(o["spec"]["podSelector"] == {} and not o["spec"].get("ingress") for o in policies), zone
        app_policy = next(o for o in policies if o["metadata"]["name"] == "app-local-gateway-only")
        app_peers = [p for rule in app_policy["spec"]["ingress"] for p in rule["from"]]
        assert all("namespaceSelector" not in p and "podSelector" in p for p in app_peers), "App admission must remain namespace-local"
        gateway_policy = next(o for o in policies if o["metadata"]["name"] == "gateway-ingress")
        protected = [r for r in gateway_policy["spec"]["ingress"] if any(p["port"] == 8443 for p in r["ports"])]
        assert protected and all("namespaceSelector" in p and "podSelector" in p for r in protected for p in r["from"]), "Gateway mTLS peers span zone namespaces"
    for obj in deployments:
        for container in obj["spec"]["template"]["spec"]["containers"]:
            assert not container["image"].endswith(":latest"), container
            if container["name"] == "envoy":
                assert container["image"] == f"envoyproxy/envoy:{PINS['ENVOY_VERSION']}", "Envoy pin drift"
            elif container["name"] == "app":
                assert container["image"] == PINS["APP_IMAGE"], "App pin drift"
            elif container["name"] == "controller":
                assert container["image"] == PINS["CONTROLLER_IMAGE"], "Controller pin drift"
    assert not any(o["kind"] == "Secret" for o in objects), "Gateway manifests must not carry keys"
    if mode == "istio":
        rules = [o for o in objects if o["kind"] == "DestinationRule"]
        assert {o["metadata"]["name"] for o in rules} == {"zone-a-gateway-mtls", "zone-b-gateway-mtls"}
        for rule in rules:
            settings = rule["spec"]["trafficPolicy"]["portLevelSettings"]
            mtls = next(item for item in settings if item["port"]["number"] == 8443)
            assert mtls["connectionPool"]["http"]["maxRequestsPerConnection"] == 1, rule

        # The bootstrap policy is deliberately separate from the dynamic
        # controller policy. If the latter disappears, the remaining ALLOW
        # policy still selects the gateway and matches only the public 8080
        # entrypoint, so protected 8443 traffic remains denied.
        policies = [o for o in objects if o["kind"] == "AuthorizationPolicy"]
        assert {p["metadata"]["name"] for p in policies} == {"zone-trust-baseline"}, policies
        for policy in policies:
            assert policy["metadata"]["labels"]["app.kubernetes.io/managed-by"] == "zone-trust-bootstrap"
            assert policy["spec"]["rules"] == [{"to": [{"operation": {"ports": ["8080"]}}]}]

        roles = [o for o in objects if o["kind"] == "Role" and o["metadata"]["name"] == "zone-trust-generated-policy"]
        assert {r["metadata"]["namespace"] for r in roles} == {"zone-a", "zone-b"}
        for role in roles:
            named = next(rule for rule in role["rules"] if rule.get("resourceNames") == ["zone-trust-generated"])
            assert set(named["verbs"]) == {"get", "patch", "update", "delete"}
            create = next(rule for rule in role["rules"] if rule.get("verbs") == ["create"])
            assert create["resources"] == ["authorizationpolicies"] and "resourceNames" not in create

        vap = next(o for o in objects if o["kind"] == "ValidatingAdmissionPolicy" and o["metadata"]["name"] == "zone-trust-controller-authorizationpolicy-create")
        assert vap["spec"]["failurePolicy"] == "Fail"
        assert vap["spec"]["matchConstraints"]["resourceRules"] == [{
            "apiGroups": ["security.istio.io"], "apiVersions": ["v1"], "operations": ["CREATE"],
            "resources": ["authorizationpolicies"], "scope": "Namespaced",
        }]
        assert vap["spec"]["matchConditions"][0]["expression"] == "request.userInfo.username == 'system:serviceaccount:control-plane:zone-trust-controller'"
        assert vap["spec"]["validations"][0]["expression"] == "object.metadata.name == 'zone-trust-generated'"
        binding = next(o for o in objects if o["kind"] == "ValidatingAdmissionPolicyBinding" and o["metadata"]["name"] == vap["metadata"]["name"])
        assert binding["spec"]["policyName"] == vap["metadata"]["name"]
        assert binding["spec"]["validationActions"] == ["Deny"]
        assert binding["spec"]["matchResources"]["namespaceSelector"]["matchLabels"] == {"security.poc.example/zone": "true"}
    print(f"PASS {mode}: YAML, overlays, plain apps, deny isolation, image tags, no key Secrets")
