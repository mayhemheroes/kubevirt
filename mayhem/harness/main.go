/*
 * This file is part of the KubeVirt project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Copyright The KubeVirt Authors.
 *
 */

package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"os"
	"reflect"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/util/validation/field"
	v1 "kubevirt.io/api/core/v1"
	"sigs.k8s.io/randfill"

	instancetypeWebhooks "kubevirt.io/kubevirt/pkg/instancetype/webhooks/vm"
	netadmitter "kubevirt.io/kubevirt/pkg/network/admitter"
	"kubevirt.io/kubevirt/pkg/testutils"
	"kubevirt.io/kubevirt/pkg/virt-api/webhooks"
	"kubevirt.io/kubevirt/pkg/virt-api/webhooks/validating-webhook/admitters"
	virtconfig "kubevirt.io/kubevirt/pkg/virt-config"
	"kubevirt.io/kubevirt/pkg/virt-config/featuregate"
)

func main() {
	var data []byte
	var err error
	if len(os.Args) > 1 {
		data, err = os.ReadFile(os.Args[1])
	} else {
		data, err = io.ReadAll(os.Stdin)
	}
	if err != nil || len(data) < 8 {
		os.Exit(0)
	}
	seed := int64(binary.LittleEndian.Uint64(data[:8]))
	fuzz(seed)
}

func fuzz(seed int64) {
	validateNetwork := func(f *field.Path, vmiSpec *v1.VirtualMachineInstanceSpec, clusterCfg *virtconfig.ClusterConfig) []metav1.StatusCause {
		return netadmitter.Validate(f, vmiSpec, clusterCfg)
	}

	const kubeVirtNamespace = "kubevirt"
	kubeVirtServiceAccounts := webhooks.KubeVirtServiceAccounts(kubeVirtNamespace)
	config := fuzzKubeVirtConfig(seed)

	// Fuzz VMI
	vmi := &v1.VirtualMachineInstance{}
	randfill.NewWithSeed(seed).NilChance(0.1).NumElements(0, 15).Funcs(fuzzFuncs()...).Fill(vmi)
	adm := &admitters.VMICreateAdmitter{
		ClusterConfig:           config,
		KubeVirtServiceAccounts: kubeVirtServiceAccounts,
		SpecValidators:          []admitters.SpecValidator{validateNetwork},
	}
	adm.Admit(context.Background(), toAdmissionReview(vmi, webhooks.VirtualMachineInstanceGroupVersionResource))

	// Fuzz VM
	vm := &v1.VirtualMachine{}
	randfill.NewWithSeed(seed).NilChance(0.1).NumElements(0, 15).Funcs(fuzzFuncs()...).Fill(vm)
	vmAdm := &admitters.VMsAdmitter{
		ClusterConfig:           config,
		KubeVirtServiceAccounts: kubeVirtServiceAccounts,
		InstancetypeAdmitter:    instancetypeWebhooks.NewAdmitterStub(),
	}
	vmAdm.Admit(context.Background(), toAdmissionReview(vm, webhooks.VirtualMachineGroupVersionResource))
}

func toAdmissionReview(obj interface{}, gvr metav1.GroupVersionResource) *admissionv1.AdmissionReview {
	raw, err := json.Marshal(obj)
	if err != nil {
		panic(err)
	}
	return &admissionv1.AdmissionReview{
		Request: &admissionv1.AdmissionRequest{
			Resource: gvr,
			Object:   runtime.RawExtension{Raw: raw},
		},
	}
}

func fuzzKubeVirtConfig(seed int64) *virtconfig.ClusterConfig {
	kv := &v1.KubeVirt{}
	randfill.NewWithSeed(seed).Funcs(
		func(dc *v1.DeveloperConfiguration, c randfill.Continue) {
			c.FillNoCustom(dc)
			featureGates := []string{
				featuregate.CPUManager, featuregate.NUMAFeatureGate, featuregate.IgnitionGate,
				featuregate.LiveMigrationGate, featuregate.SRIOVLiveMigrationGate,
				featuregate.CPUNodeDiscoveryGate, featuregate.HypervStrictCheckGate,
				featuregate.SidecarGate, featuregate.HostDevicesGate, featuregate.SnapshotGate,
				featuregate.HotplugVolumesGate, featuregate.HostDiskGate, featuregate.MacvtapGate,
				featuregate.PasstGate, featuregate.DownwardMetricsFeatureGate, featuregate.NonRoot,
				featuregate.Root, featuregate.WorkloadEncryptionSEV,
				featuregate.DockerSELinuxMCSWorkaround, featuregate.PSA, featuregate.VSOCKGate,
			}
			idxs := c.Perm(c.Int() % len(featureGates))
			for idx := range idxs {
				dc.FeatureGates = append(dc.FeatureGates, featureGates[idx])
			}
		},
	).Fill(kv)
	config, _, _ := testutils.NewFakeClusterConfigUsingKV(kv)
	return config
}

func fuzzFuncs() []interface{} {
	return []interface{}{
		func(e *metav1.FieldsV1, c randfill.Continue) {},
		func(objectmeta *metav1.ObjectMeta, c randfill.Continue) {
			c.FillNoCustom(objectmeta)
			objectmeta.DeletionGracePeriodSeconds = nil
			objectmeta.Generation = 0
			objectmeta.ManagedFields = nil
		},
		func(obj *corev1.URIScheme, c randfill.Continue) {
			schemes := []corev1.URIScheme{corev1.URISchemeHTTP, corev1.URISchemeHTTPS}
			*obj = schemes[c.Int()%len(schemes)]
		},
		func(obj *corev1.PullPolicy, c randfill.Continue) {
			policies := []corev1.PullPolicy{corev1.PullAlways, corev1.PullNever, corev1.PullIfNotPresent}
			*obj = policies[c.Int()%len(policies)]
		},
		func(obj *corev1.DNSPolicy, c randfill.Continue) {
			policies := []corev1.DNSPolicy{corev1.DNSClusterFirst, corev1.DNSClusterFirstWithHostNet, corev1.DNSDefault, corev1.DNSNone}
			*obj = policies[c.Int()%len(policies)]
		},
		func(obj *int, c randfill.Continue) { *obj = c.Intn(100000) },
		func(obj *uint, c randfill.Continue) { *obj = uint(c.Intn(100000)) },
		func(obj *int32, c randfill.Continue) { *obj = int32(c.Intn(100000)) },
		func(obj *int64, c randfill.Continue) { *obj = int64(c.Intn(100000)) },
		func(obj *uint64, c randfill.Continue) { *obj = uint64(c.Intn(100000)) },
		func(obj *uint32, c randfill.Continue) { *obj = uint32(c.Intn(100000)) },
		func(obj *corev1.TypedObjectReference, c randfill.Continue) {
			c.FillNoCustom(obj)
			str := c.String(0)
			obj.APIGroup = &str
		},
		func(obj *reflect.Value, c randfill.Continue) {},
	}
}
