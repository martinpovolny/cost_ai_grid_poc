// Package controller watches Kubernetes resources and emits cost CloudEvents.
package controller

// +kubebuilder:rbac:groups="",resources=pods;nodes;persistentvolumeclaims;services;namespaces,verbs=get;list;watch

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	toolscache "k8s.io/client-go/tools/cache"
	"sigs.k8s.io/controller-runtime/pkg/cache"

	"github.com/myersCody/cost_ai_grid_poc/kube-cost-agent/internal/emitter"
)

// Field name constants used as CloudEvent data keys.
const (
	fieldClusterID = "cluster_id"
	fieldTenant    = "tenant"
	fieldNamespace = "namespace"
	fieldNode      = "node"
	fieldAction    = "action"
	fieldLabels    = "labels"
	fieldSpot      = "spot"
)

// Controller watches Kubernetes resources and emits cost CloudEvents.
type Controller struct {
	cache                 cache.Cache
	emitter               *emitter.Emitter
	clusterID             string
	defaultTenant         string
	excludeNamespaces     map[string]bool
	heartbeatInterval     time.Duration
	nodeReconcileInterval time.Duration
	logger                logr.Logger
	lastHeartbeat         map[string]time.Time // pod key -> last heartbeat time
	mu                    sync.RWMutex
}

// New creates a Controller that watches Pods, Nodes, PVCs, and Services,
// emitting CloudEvents via the given emitter.
func New(
	c cache.Cache,
	em *emitter.Emitter,
	clusterID string,
	defaultTenant string,
	excludeNS []string,
	heartbeatInterval time.Duration,
	nodeReconcileInterval time.Duration,
	logger logr.Logger,
) *Controller {
	nsMap := make(map[string]bool, len(excludeNS))
	for _, ns := range excludeNS {
		nsMap[ns] = true
	}
	return &Controller{
		cache:                 c,
		emitter:               em,
		clusterID:             clusterID,
		defaultTenant:         defaultTenant,
		excludeNamespaces:     nsMap,
		heartbeatInterval:     heartbeatInterval,
		nodeReconcileInterval: nodeReconcileInterval,
		logger:                logger.WithName("controller"),
		lastHeartbeat:         make(map[string]time.Time),
	}
}

// Start implements manager.Runnable. It registers event handlers on informers
// for Pods, Nodes, PVCs, and Services, starts heartbeat and node-reconcile
// goroutines, and blocks until ctx is cancelled.
func (c *Controller) Start(ctx context.Context) error {
	c.logger.Info("Starting cost controller")

	// Get informers from the cache.
	podInformer, err := c.cache.GetInformer(ctx, &corev1.Pod{})
	if err != nil {
		return fmt.Errorf("failed to get Pod informer: %w", err)
	}
	nodeInformer, err := c.cache.GetInformer(ctx, &corev1.Node{})
	if err != nil {
		return fmt.Errorf("failed to get Node informer: %w", err)
	}
	pvcInformer, err := c.cache.GetInformer(ctx, &corev1.PersistentVolumeClaim{})
	if err != nil {
		return fmt.Errorf("failed to get PVC informer: %w", err)
	}
	svcInformer, err := c.cache.GetInformer(ctx, &corev1.Service{})
	if err != nil {
		return fmt.Errorf("failed to get Service informer: %w", err)
	}

	// Register event handlers.
	if _, err := podInformer.AddEventHandler(toolscache.ResourceEventHandlerFuncs{
		AddFunc:    c.onPodAdd,
		DeleteFunc: c.onPodDelete,
	}); err != nil {
		return fmt.Errorf("failed to add pod event handler: %w", err)
	}
	if _, err := nodeInformer.AddEventHandler(toolscache.ResourceEventHandlerFuncs{
		AddFunc:    c.onNodeAdd,
		DeleteFunc: c.onNodeDelete,
	}); err != nil {
		return fmt.Errorf("failed to add node event handler: %w", err)
	}
	if _, err := pvcInformer.AddEventHandler(toolscache.ResourceEventHandlerFuncs{
		AddFunc:    c.onPVCAdd,
		DeleteFunc: c.onPVCDelete,
	}); err != nil {
		return fmt.Errorf("failed to add pvc event handler: %w", err)
	}
	if _, err := svcInformer.AddEventHandler(toolscache.ResourceEventHandlerFuncs{
		AddFunc:    c.onServiceAdd,
		DeleteFunc: c.onServiceDelete,
	}); err != nil {
		return fmt.Errorf("failed to add service event handler: %w", err)
	}

	// Start heartbeat goroutine for pods.
	go c.heartbeatLoop(ctx)

	// Start node reconcile goroutine.
	go c.nodeReconcileLoop(ctx)

	c.logger.Info("Cost controller started, waiting for shutdown")
	<-ctx.Done()
	c.logger.Info("Cost controller stopped")
	return nil
}

// NeedLeaderElection returns true so only one replica emits events.
func (c *Controller) NeedLeaderElection() bool {
	return true
}

// ---------------------------------------------------------------------------
// Event handlers
// ---------------------------------------------------------------------------

func (c *Controller) onPodAdd(obj any) {
	pod, ok := obj.(*corev1.Pod)
	if !ok {
		return
	}
	if c.shouldExclude(pod.Namespace) {
		return
	}
	data := c.podEventData(pod, "CREATED")
	subject := fmt.Sprintf("%s/%s", pod.Namespace, pod.Name)
	c.emitter.Emit("kube.pod.lifecycle", subject, data)
	c.logger.V(1).Info("Emitted Pod lifecycle event", "action", "CREATED", "pod", subject)
}

func (c *Controller) onPodDelete(obj any) {
	pod, ok := obj.(*corev1.Pod)
	if !ok {
		// Handle DeletedFinalStateUnknown from the cache.
		tombstone, ok := obj.(toolscache.DeletedFinalStateUnknown)
		if !ok {
			return
		}
		pod, ok = tombstone.Obj.(*corev1.Pod)
		if !ok {
			return
		}
	}
	if c.shouldExclude(pod.Namespace) {
		return
	}
	data := c.podEventData(pod, "DELETED")
	subject := fmt.Sprintf("%s/%s", pod.Namespace, pod.Name)
	c.emitter.Emit("kube.pod.lifecycle", subject, data)
	c.logger.V(1).Info("Emitted Pod lifecycle event", "action", "DELETED", "pod", subject)

	// Clean up heartbeat tracking.
	c.mu.Lock()
	delete(c.lastHeartbeat, subject)
	c.mu.Unlock()
}

func (c *Controller) onNodeAdd(obj any) {
	node, ok := obj.(*corev1.Node)
	if !ok {
		return
	}
	data := c.nodeEventData(node, "CREATED")
	c.emitter.Emit("kube.node.lifecycle", node.Name, data)
	c.logger.V(1).Info("Emitted Node lifecycle event", "action", "CREATED", "node", node.Name)
}

func (c *Controller) onNodeDelete(obj any) {
	node, ok := obj.(*corev1.Node)
	if !ok {
		tombstone, ok := obj.(toolscache.DeletedFinalStateUnknown)
		if !ok {
			return
		}
		node, ok = tombstone.Obj.(*corev1.Node)
		if !ok {
			return
		}
	}
	data := c.nodeEventData(node, "DELETED")
	c.emitter.Emit("kube.node.lifecycle", node.Name, data)
	c.logger.V(1).Info("Emitted Node lifecycle event", "action", "DELETED", "node", node.Name)
}

func (c *Controller) onPVCAdd(obj any) {
	pvc, ok := obj.(*corev1.PersistentVolumeClaim)
	if !ok {
		return
	}
	if c.shouldExclude(pvc.Namespace) {
		return
	}
	data := c.pvcEventData(pvc, "CREATED")
	subject := fmt.Sprintf("%s/%s", pvc.Namespace, pvc.Name)
	c.emitter.Emit("kube.pvc.lifecycle", subject, data)
	c.logger.V(1).Info("Emitted PVC lifecycle event", "action", "CREATED", "pvc", subject)
}

func (c *Controller) onPVCDelete(obj any) {
	pvc, ok := obj.(*corev1.PersistentVolumeClaim)
	if !ok {
		tombstone, ok := obj.(toolscache.DeletedFinalStateUnknown)
		if !ok {
			return
		}
		pvc, ok = tombstone.Obj.(*corev1.PersistentVolumeClaim)
		if !ok {
			return
		}
	}
	if c.shouldExclude(pvc.Namespace) {
		return
	}
	data := c.pvcEventData(pvc, "DELETED")
	subject := fmt.Sprintf("%s/%s", pvc.Namespace, pvc.Name)
	c.emitter.Emit("kube.pvc.lifecycle", subject, data)
	c.logger.V(1).Info("Emitted PVC lifecycle event", "action", "DELETED", "pvc", subject)
}

func (c *Controller) onServiceAdd(obj any) {
	svc, ok := obj.(*corev1.Service)
	if !ok {
		return
	}
	if svc.Spec.Type != corev1.ServiceTypeLoadBalancer {
		return
	}
	if c.shouldExclude(svc.Namespace) {
		return
	}
	data := c.serviceEventData(svc, "CREATED")
	subject := fmt.Sprintf("%s/%s", svc.Namespace, svc.Name)
	c.emitter.Emit("kube.service.lifecycle", subject, data)
	c.logger.V(1).Info("Emitted Service lifecycle event", "action", "CREATED", "service", subject)
}

func (c *Controller) onServiceDelete(obj any) {
	svc, ok := obj.(*corev1.Service)
	if !ok {
		tombstone, ok := obj.(toolscache.DeletedFinalStateUnknown)
		if !ok {
			return
		}
		svc, ok = tombstone.Obj.(*corev1.Service)
		if !ok {
			return
		}
	}
	if svc.Spec.Type != corev1.ServiceTypeLoadBalancer {
		return
	}
	if c.shouldExclude(svc.Namespace) {
		return
	}
	data := c.serviceEventData(svc, "DELETED")
	subject := fmt.Sprintf("%s/%s", svc.Namespace, svc.Name)
	c.emitter.Emit("kube.service.lifecycle", subject, data)
	c.logger.V(1).Info("Emitted Service lifecycle event", "action", "DELETED", "service", subject)
}

// ---------------------------------------------------------------------------
// Heartbeat and reconciliation loops
// ---------------------------------------------------------------------------

// heartbeatLoop emits kube.pod.heartbeat events for all running pods at
// regular intervals.
func (c *Controller) heartbeatLoop(ctx context.Context) {
	ticker := time.NewTicker(c.heartbeatInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			c.emitPodHeartbeats(ctx)
		}
	}
}

// nodeReconcileLoop emits kube.node.heartbeat events for all nodes at
// regular intervals.
func (c *Controller) nodeReconcileLoop(ctx context.Context) {
	ticker := time.NewTicker(c.nodeReconcileInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			c.emitNodeHeartbeats(ctx)
		}
	}
}

func (c *Controller) emitPodHeartbeats(ctx context.Context) {
	var podList corev1.PodList
	if err := c.cache.List(ctx, &podList); err != nil {
		c.logger.Error(err, "Failed to list Pods for heartbeat")
		return
	}

	now := time.Now()
	for i := range podList.Items {
		pod := &podList.Items[i]
		if pod.Status.Phase != corev1.PodRunning {
			continue
		}
		if c.shouldExclude(pod.Namespace) {
			continue
		}

		key := fmt.Sprintf("%s/%s", pod.Namespace, pod.Name)

		c.mu.RLock()
		last, found := c.lastHeartbeat[key]
		c.mu.RUnlock()

		if !found {
			// First heartbeat — use pod start time or creation time.
			if pod.Status.StartTime != nil {
				last = pod.Status.StartTime.Time
			} else {
				last = pod.CreationTimestamp.Time
			}
		}

		durationSec := now.Sub(last).Seconds()

		cpuReq, memReq := aggregateRequests(pod)

		data := map[string]any{
			fieldClusterID:     c.clusterID,
			fieldTenant:        c.resolveTenant(pod.Namespace),
			fieldNamespace:     pod.Namespace,
			"pod":              pod.Name,
			fieldNode:          pod.Spec.NodeName,
			"cpu_request":      cpuReq.AsApproximateFloat64(),
			"memory_request":   memReq.Value(),
			"duration_seconds": durationSec,
		}

		c.emitter.Emit("kube.pod.heartbeat", key, data)

		c.mu.Lock()
		c.lastHeartbeat[key] = now
		c.mu.Unlock()
	}
}

func (c *Controller) emitNodeHeartbeats(ctx context.Context) {
	var nodeList corev1.NodeList
	if err := c.cache.List(ctx, &nodeList); err != nil {
		c.logger.Error(err, "Failed to list Nodes for heartbeat")
		return
	}

	for i := range nodeList.Items {
		node := &nodeList.Items[i]
		data := c.nodeEventData(node, "HEARTBEAT")
		c.emitter.Emit("kube.node.heartbeat", node.Name, data)
	}
}

// ---------------------------------------------------------------------------
// Data extraction helpers
// ---------------------------------------------------------------------------

func (c *Controller) podEventData(pod *corev1.Pod, action string) map[string]any {
	cpuReq, memReq := aggregateRequests(pod)
	cpuLim, memLim := aggregateLimits(pod)
	gpuCount := countGPUs(pod)
	ownerKind, ownerName := resolveOwner(pod)

	return map[string]any{
		fieldClusterID: c.clusterID,
		fieldTenant:    c.resolveTenant(pod.Namespace),
		fieldAction:    action,
		fieldNamespace: pod.Namespace,
		"pod":          pod.Name,
		fieldNode:      pod.Spec.NodeName,
		"cpu_request":  cpuReq.AsApproximateFloat64(),
		"cpu_limit":    cpuLim.AsApproximateFloat64(),
		"mem_request":  memReq.Value(),
		"mem_limit":    memLim.Value(),
		"gpu_count":    gpuCount,
		"qos":          string(pod.Status.QOSClass),
		"owner_kind":   ownerKind,
		"owner_name":   ownerName,
		fieldLabels:    pod.Labels,
	}
}

func (c *Controller) nodeEventData(node *corev1.Node, action string) map[string]any {
	labels := node.Labels
	instanceType := labels["node.kubernetes.io/instance-type"]
	zone := labels["topology.kubernetes.io/zone"]
	region := labels["topology.kubernetes.io/region"]

	// Spot detection: check labels used by major cloud providers / OpenShift offerings.
	// AWS/ROSA/OSD: node.kubernetes.io/lifecycle=spot (standard), karpenter.sh/capacity-type=spot
	// ARO (Azure):  kubernetes.azure.com/scalesetpriority=spot
	// GCP/OSD-GCP:  cloud.google.com/gke-spot=true
	spot := false
	if v, ok := labels["node.kubernetes.io/lifecycle"]; ok && v == fieldSpot {
		spot = true
	}
	if v, ok := labels["karpenter.sh/capacity-type"]; ok && v == fieldSpot {
		spot = true
	}
	if v, ok := labels["kubernetes.azure.com/scalesetpriority"]; ok && v == fieldSpot {
		spot = true
	}
	if v, ok := labels["cloud.google.com/gke-spot"]; ok && v == "true" {
		spot = true
	}

	return map[string]any{
		fieldClusterID:  c.clusterID,
		fieldAction:     action,
		fieldNode:       node.Name,
		"instance_type": instanceType,
		"zone":          zone,
		"region":        region,
		fieldSpot:       spot,
		"capacity_cpu":  node.Status.Capacity.Cpu().AsApproximateFloat64(),
		"capacity_mem":  node.Status.Capacity.Memory().Value(),
		"alloc_cpu":     node.Status.Allocatable.Cpu().AsApproximateFloat64(),
		"alloc_mem":     node.Status.Allocatable.Memory().Value(),
	}
}

func (c *Controller) pvcEventData(pvc *corev1.PersistentVolumeClaim, action string) map[string]any {
	data := map[string]any{
		fieldClusterID:  c.clusterID,
		fieldTenant:     c.resolveTenant(pvc.Namespace),
		fieldAction:     action,
		fieldNamespace:  pvc.Namespace,
		"pvc":           pvc.Name,
		"storage_class": ptrString(pvc.Spec.StorageClassName),
		"volume_name":   pvc.Spec.VolumeName,
		"access_modes":  accessModesToStrings(pvc.Spec.AccessModes),
		"phase":         string(pvc.Status.Phase),
		fieldLabels:     pvc.Labels,
	}

	// Requested storage size.
	if req, ok := pvc.Spec.Resources.Requests[corev1.ResourceStorage]; ok {
		data["requested_bytes"] = req.Value()
	}

	// Actual capacity (populated after binding).
	if pvc.Status.Capacity != nil {
		if cap, ok := pvc.Status.Capacity[corev1.ResourceStorage]; ok {
			data["capacity_bytes"] = cap.Value()
		}
	}

	return data
}

func (c *Controller) serviceEventData(svc *corev1.Service, action string) map[string]any {
	var lbIPs []string
	for _, ingress := range svc.Status.LoadBalancer.Ingress {
		if ingress.IP != "" {
			lbIPs = append(lbIPs, ingress.IP)
		} else if ingress.Hostname != "" {
			lbIPs = append(lbIPs, ingress.Hostname)
		}
	}

	return map[string]any{
		fieldClusterID: c.clusterID,
		fieldTenant:    c.resolveTenant(svc.Namespace),
		fieldAction:    action,
		fieldNamespace: svc.Namespace,
		"service":      svc.Name,
		"type":         string(svc.Spec.Type),
		"lb_endpoints": lbIPs,
		"ports":        servicePorts(svc),
		fieldLabels:    svc.Labels,
	}
}

// ---------------------------------------------------------------------------
// Tenant and namespace helpers
// ---------------------------------------------------------------------------

// resolveTenant returns the defaultTenant if set, otherwise the namespace name.
func (c *Controller) resolveTenant(namespace string) string {
	if c.defaultTenant != "" {
		return c.defaultTenant
	}
	return namespace
}

// shouldExclude returns true if the namespace should be skipped. Checks
// exact matches and also skips any namespace with the "openshift-" prefix.
func (c *Controller) shouldExclude(namespace string) bool {
	if c.excludeNamespaces[namespace] {
		return true
	}
	if strings.HasPrefix(namespace, "openshift-") {
		return true
	}
	return false
}

// ---------------------------------------------------------------------------
// Resource aggregation helpers
// ---------------------------------------------------------------------------

// aggregateRequests sums CPU and memory requests across all containers.
func aggregateRequests(pod *corev1.Pod) (cpu, mem resource.Quantity) {
	for i := range pod.Spec.Containers {
		if r := pod.Spec.Containers[i].Resources.Requests; r != nil {
			if v, ok := r[corev1.ResourceCPU]; ok {
				cpu.Add(v)
			}
			if v, ok := r[corev1.ResourceMemory]; ok {
				mem.Add(v)
			}
		}
	}
	return cpu, mem
}

// aggregateLimits sums CPU and memory limits across all containers.
func aggregateLimits(pod *corev1.Pod) (cpu, mem resource.Quantity) {
	for i := range pod.Spec.Containers {
		if l := pod.Spec.Containers[i].Resources.Limits; l != nil {
			if v, ok := l[corev1.ResourceCPU]; ok {
				cpu.Add(v)
			}
			if v, ok := l[corev1.ResourceMemory]; ok {
				mem.Add(v)
			}
		}
	}
	return cpu, mem
}

// countGPUs counts nvidia.com/gpu requests across all containers.
func countGPUs(pod *corev1.Pod) int64 {
	gpuResource := corev1.ResourceName("nvidia.com/gpu")
	var total int64
	for i := range pod.Spec.Containers {
		if r := pod.Spec.Containers[i].Resources.Requests; r != nil {
			if v, ok := r[gpuResource]; ok {
				total += v.Value()
			}
		}
		if l := pod.Spec.Containers[i].Resources.Limits; l != nil {
			if v, ok := l[gpuResource]; ok && total == 0 {
				total += v.Value()
			}
		}
	}
	return total
}

// resolveOwner returns the kind and name of the first owner reference, or
// empty strings if none.
func resolveOwner(pod *corev1.Pod) (kind, name string) {
	if len(pod.OwnerReferences) > 0 {
		ref := pod.OwnerReferences[0]
		return ref.Kind, ref.Name
	}
	return "", ""
}

// ---------------------------------------------------------------------------
// Misc helpers
// ---------------------------------------------------------------------------

func ptrString(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func accessModesToStrings(modes []corev1.PersistentVolumeAccessMode) []string {
	out := make([]string, len(modes))
	for i, m := range modes {
		out[i] = string(m)
	}
	return out
}

func servicePorts(svc *corev1.Service) []map[string]any {
	ports := make([]map[string]any, len(svc.Spec.Ports))
	for i, p := range svc.Spec.Ports {
		ports[i] = map[string]any{
			"name":     p.Name,
			"port":     p.Port,
			"protocol": string(p.Protocol),
		}
	}
	return ports
}
