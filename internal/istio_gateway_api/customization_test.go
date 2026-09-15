package istiogatewayapi

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/strategicpatch"
	"sigs.k8s.io/yaml"
)

// TestGatewayDeploymentCustomizationPreservesGeneratedDeploymentParts applies
// the exact ConfigMap deployment customization as Istiod does. In particular,
// the workload-socket entry must replace its emptyDir source without replacing
// the whole volumes list: automated Gateway deployments have unrelated
// credential and configuration volumes that must survive this customization.
func TestGatewayDeploymentCustomizationPreservesGeneratedDeploymentParts(t *testing.T) {
	for _, customization := range deploymentCustomizations(t) {
		t.Run(customization.namespace, func(t *testing.T) {
			deployment := mergeDeploymentCustomization(t, generatedGatewayDeployment(), customization.deployment)
			volumes := volumesByName(deployment.Spec.Template.Spec.Volumes)

			workload, found := volumes["workload-socket"]
			if !found {
				t.Fatal("workload-socket volume is missing")
			}
			if workload.EmptyDir != nil {
				t.Fatalf("workload-socket retained emptyDir: %#v", workload.EmptyDir)
			}
			if workload.CSI == nil || workload.CSI.Driver != "csi.spiffe.io" || workload.CSI.ReadOnly == nil || !*workload.CSI.ReadOnly {
				t.Fatalf("workload-socket CSI source = %#v, want read-only csi.spiffe.io", workload.CSI)
			}
			if _, found := volumes["credential-socket"]; !found {
				t.Fatal("unrelated credential-socket volume was removed")
			}
			if _, found := volumes["proxy-config"]; !found {
				t.Fatal("unrelated proxy-config volume was removed")
			}

			proxy := containerNamed(t, deployment.Spec.Template.Spec.Containers, "istio-proxy")
			if mountAt(proxy.VolumeMounts, "/var/run/secrets/workload-spiffe-uds") != nil {
				t.Fatal("legacy workload socket mount was not deleted")
			}
			workloadMount := mountAt(proxy.VolumeMounts, "/run/secrets/workload-spiffe-uds")
			if workloadMount == nil || workloadMount.Name != "workload-socket" || !workloadMount.ReadOnly {
				t.Fatalf("new workload socket mount = %#v, want read-only workload-socket", workloadMount)
			}
			if mountAt(proxy.VolumeMounts, "/etc/istio/proxy") == nil {
				t.Fatal("unrelated proxy config mount was removed")
			}
			if mountAt(proxy.VolumeMounts, "/var/run/secrets/credential-uds") == nil {
				t.Fatal("unrelated credential socket mount was removed")
			}

			wait := containerNamed(t, deployment.Spec.Template.Spec.InitContainers, "wait-for-spire-socket")
			waitMount := mountAt(wait.VolumeMounts, "/run/secrets/workload-spiffe-uds")
			if waitMount == nil || waitMount.Name != "workload-socket" || !waitMount.ReadOnly {
				t.Fatalf("wait-for-spire-socket mount = %#v, want read-only workload-socket", waitMount)
			}
		})
	}
}

func deploymentCustomizations(t *testing.T) []struct{ namespace, deployment string } {
	t.Helper()
	path := filepath.Join("..", "..", "config", "istio-gateway-api", "gateway-options.yaml")
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var result []struct{ namespace, deployment string }
	for _, document := range strings.Split(string(contents), "\n---\n") {
		var configMap corev1.ConfigMap
		if err := yaml.Unmarshal([]byte(document), &configMap); err != nil {
			t.Fatalf("parse ConfigMap: %v", err)
		}
		deployment, found := configMap.Data["deployment"]
		if !found {
			t.Fatalf("ConfigMap %s/%s has no data.deployment", configMap.Namespace, configMap.Name)
		}
		result = append(result, struct{ namespace, deployment string }{namespace: configMap.Namespace, deployment: deployment})
	}
	return result
}

func mergeDeploymentCustomization(t *testing.T, original appsv1.Deployment, customization string) appsv1.Deployment {
	t.Helper()
	originalJSON, err := json.Marshal(original)
	if err != nil {
		t.Fatal(err)
	}
	patchJSON, err := yaml.YAMLToJSON([]byte(customization))
	if err != nil {
		t.Fatalf("convert deployment customization to JSON: %v", err)
	}
	mergedJSON, err := strategicpatch.StrategicMergePatch(originalJSON, patchJSON, appsv1.Deployment{})
	if err != nil {
		t.Fatalf("apply strategic deployment customization: %v", err)
	}
	var merged appsv1.Deployment
	if err := json.Unmarshal(mergedJSON, &merged); err != nil {
		t.Fatalf("decode merged deployment: %v", err)
	}
	return merged
}

func generatedGatewayDeployment() appsv1.Deployment {
	readOnly := true
	return appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{Name: "zone-gateway", Namespace: "zone-a"},
		Spec: appsv1.DeploymentSpec{Template: corev1.PodTemplateSpec{Spec: corev1.PodSpec{
			Volumes: []corev1.Volume{
				{Name: "workload-socket", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}},
				{Name: "credential-socket", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}},
				{Name: "proxy-config", VolumeSource: corev1.VolumeSource{ConfigMap: &corev1.ConfigMapVolumeSource{LocalObjectReference: corev1.LocalObjectReference{Name: "proxy-config"}}}},
			},
			Containers: []corev1.Container{{
				Name: "istio-proxy",
				VolumeMounts: []corev1.VolumeMount{
					{Name: "workload-socket", MountPath: "/var/run/secrets/workload-spiffe-uds", ReadOnly: readOnly},
					{Name: "credential-socket", MountPath: "/var/run/secrets/credential-uds", ReadOnly: readOnly},
					{Name: "proxy-config", MountPath: "/etc/istio/proxy", ReadOnly: readOnly},
				},
			}},
		}}},
	}
}

func volumesByName(volumes []corev1.Volume) map[string]corev1.Volume {
	result := make(map[string]corev1.Volume, len(volumes))
	for _, volume := range volumes {
		result[volume.Name] = volume
	}
	return result
}

func containerNamed(t *testing.T, containers []corev1.Container, name string) corev1.Container {
	t.Helper()
	for _, container := range containers {
		if container.Name == name {
			return container
		}
	}
	t.Fatalf("container %q is missing", name)
	return corev1.Container{}
}

func mountAt(mounts []corev1.VolumeMount, path string) *corev1.VolumeMount {
	for i := range mounts {
		if mounts[i].MountPath == path {
			return &mounts[i]
		}
	}
	return nil
}
