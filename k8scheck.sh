#!/bin/bash
# k8scheck
# A K8S cluster integrity checker shell script.
# Author: Dragos Ruiu
# Date: December 05 2023 v1.0
# Set the namespace; use "--all-namespaces" or a specific namespace as needed
NAMESPACE="default"

# Common function to validate CRON schedule format 
validate_cron_schedule() {
    local schedule=$1
    if ! [[ $schedule =~ ^\*{1,2}|\d+|\d+-\d+|\d+/\d+$ ]]; then
        echo "invalid"
    else
        echo "valid"
    fi
}

# Function to check if a GatewayClass exists
check_gateway_class() {
    local gateway_class_name=$1
    if ! kubectl get gatewayclass "$gateway_class_name" &> /dev/null; then
        echo "GatewayClass $gateway_class_name does not exist."
    else
        echo "GatewayClass $gateway_class_name exists."
    fi
}

# Function to check the status of GatewayClass
check_gateway_class_status() {
    local gateway_class_name=$1
    local status=$(kubectl get gatewayclass "$gateway_class_name" -o=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}')
    local message=$(kubectl get gatewayclass "$gateway_class_name" -o=jsonpath='{.status.conditions[?(@.type=="Accepted")].message}')

    if [ "$status" != "True" ]; then
        echo "GatewayClass '$gateway_class_name' is not accepted. Message: '$message'"
    else
        echo "GatewayClass '$gateway_class_name' is accepted."
    fi
}

# Function to analyze CronJobs
analyze_cronjobs() {
    cronjobs=$(kubectl get cronjobs -n $NAMESPACE -o=jsonpath='{.items[*].metadata.name}')

    for cronjob in $cronjobs; do
        local schedule=$(kubectl get cronjob $cronjob -n $NAMESPACE -o=jsonpath='{.spec.schedule}')
        local suspend=$(kubectl get cronjob $cronjob -n $NAMESPACE -o=jsonpath='{.spec.suspend}')
        local deadline=$(kubectl get cronjob $cronjob -n $NAMESPACE -o=jsonpath='{.spec.startingDeadlineSeconds}')

        [[ "$suspend" == "true" ]] && echo "CronJob $cronjob in namespace $NAMESPACE is suspended"
        [[ $(validate_cron_schedule "$schedule") == "invalid" ]] && echo "CronJob $cronjob in namespace $NAMESPACE has an invalid schedule: $schedule"
        [[ $deadline -lt 0 ]] && echo "CronJob $cronjob in namespace $NAMESPACE has a negative starting deadline"
    done
}

# Function to analyze Deployments
analyze_deployments() {
    deployments=$(kubectl get deployments -n $NAMESPACE -o=jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.namespace}{"\n"}{end}')

    while IFS= read -r line; do
        IFS=' ' read -r deployment_name deployment_namespace <<< "$line"
        local desired_replicas=$(kubectl get deployment $deployment_name -n $deployment_namespace -o=jsonpath='{.spec.replicas}')
        local available_replicas=$(kubectl get deployment $deployment_name -n $deployment_namespace -o=jsonpath='{.status.availableReplicas}')
        local total_replicas=$(kubectl get deployment $deployment_name -n $deployment_namespace -o=jsonpath='{.status.replicas}')

        if [[ "$desired_replicas" -ne "$total_replicas" ]] || [[ "$desired_replicas" -ne "$available_replicas" ]]; then
            echo "Deployment $deployment_name in namespace $deployment_namespace has a replica discrepancy: Desired=$desired_replicas, Total=$total_replicas, Available=$available_replicas"
        fi
    done <<< "$deployments"
}

# Function to analyze Gateways and GatewayClasses

analyze_gateways() {
    gateways=$(kubectl get gateways -n "$NAMESPACE" --no-headers -o custom-columns=":metadata.name,:metadata.namespace")

    while IFS= read -r line; do
        IFS=' ' read -r gateway_name gateway_namespace <<< "$line"
        echo "Analyzing Gateway: $gateway_name in namespace: $gateway_namespace"

        # Get GatewayClass name and analyze
        gateway_class_name=$(kubectl get gateway "$gateway_name" -n "$gateway_namespace" -o=jsonpath='{.spec.gatewayClassName}')
        check_gateway_class "$gateway_class_name"

        # Check Gateway status
        status=$(kubectl get gateway "$gateway_name" -n "$gateway_namespace" -o=jsonpath='{.status.conditions[0].status}')
        message=$(kubectl get gateway "$gateway_name" -n "$gateway_namespace" -o=jsonpath='{.status.conditions[0].message}')
        if [ "$status" != "True" ]; then
            echo "Gateway '$gateway_namespace/$gateway_name' is not accepted. Message: '$message'."
        else
            echo "Gateway '$gateway_namespace/$gateway_name' is accepted."
        fi
    done <<< "$gateways"

    # Analyze GatewayClasses
    gateway_classes=$(kubectl get gatewayclass --no-headers -o custom-columns=":metadata.name")
    echo "Analyzing GatewayClasses..."
    while IFS= read -r gc_name; do
        echo "Analyzing GatewayClass: $gc_name"
        check_gateway_class_status "$gc_name"
    done <<< "$gateway_classes"
}

# Function to analyze Horizontal Pod Autoscalers (HPAs)

analyze_hpas() {
    hpas=$(kubectl get hpa -n $NAMESPACE -o=jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.namespace}{"\n"}{end}')

    while IFS= read -r line; do
        IFS=' ' read -r hpa_name hpa_namespace <<< "$line"
        local target_kind=$(kubectl get hpa $hpa_name -n $hpa_namespace -o=jsonpath='{.spec.scaleTargetRef.kind}')
        local target_name=$(kubectl get hpa $hpa_name -n $hpa_namespace -o=jsonpath='{.spec.scaleTargetRef.name}')

        if ! kubectl get "$target_kind" "$target_name" -n "$hpa_namespace" &> /dev/null; then
            echo "HPA $hpa_name in namespace $hpa_namespace references non-existent $target_kind $target_name"
            continue
        fi

        local containers_without_resources=$(kubectl get "$target_kind" "$target_name" -n "$hpa_namespace" -o=jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}' | while read container_name; do
            local requests=$(kubectl get "$target_kind" "$target_name" -n "$hpa_namespace" -o=jsonpath="{.spec.template.spec.containers[?(@.name==\"$container_name\")].resources.requests}")
            local limits=$(kubectl get "$target_kind" "$target_name" -n "$hpa_namespace" -o=jsonpath="{.spec.template.spec.containers[?(@.name==\"$container_name\")].resources.limits}")

            if [[ -z "$requests" ]] || [[ -z "$limits" ]]; then
                echo "$container_name"
            fi
        done | wc -l)

        if [[ $containers_without_resources -gt 0 ]]; then
            echo "HPA $hpa_name in namespace $hpa_namespace targets $target_kind $target_name, which has $containers_without_resources containers without resource requests or limits"
        fi
    done <<< "$hpas"
}

# Function to analyze HTTPRoutes

analyze_httproutes() {
    httproutes=$(kubectl get httproute -n "$NAMESPACE" -o=jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

    for route in $httproutes; do
        echo "Analyzing HTTPRoute: $route in namespace $NAMESPACE"

        local gateways=$(kubectl get httproute $route -n "$NAMESPACE" -o=jsonpath='{range .spec.parentRefs[*]}{.name}{"\n"}{end}')
        for gtw in $gateways; do
            if ! kubectl get gateway $gtw -n "$NAMESPACE" &> /dev/null; then
                echo "  - Gateway $gtw referenced by HTTPRoute $route does not exist in namespace $NAMESPACE"
            fi
        done

        local services=$(kubectl get httproute $route -n "$NAMESPACE" -o=jsonpath='{range .spec.rules[*].backendRefs[*]}{.name}{"\n"}{end}')
        for svc in $services; do
            if ! kubectl get svc $svc -n "$NAMESPACE" &> /dev/null; then
                echo "  - Service $svc referenced by HTTPRoute $route does not exist in namespace $NAMESPACE"
            fi
        done

        echo "Finished analyzing HTTPRoute: $route"
    done
}

# Function to analyze Ingress Resources

analyze_ingresses() {
    ingresses=$(kubectl get ingress -n $NAMESPACE -o=jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.namespace}{"\n"}{end}')

    while IFS= read -r line; do
        IFS=' ' read -r ingress_name ingress_namespace <<< "$line"
        local ingress_class=$(kubectl get ingress $ingress_name -n $ingress_namespace -o=jsonpath='{.spec.ingressClassName}')
        if [ -z "$ingress_class" ]; then
            echo "Ingress $ingress_name in namespace $ingress_namespace does not specify an Ingress class."
        fi

        local services=$(kubectl get ingress $ingress_name -n $ingress_namespace -o=jsonpath='{range .spec.rules[*].http.paths[*].backend.service}{.name}{"\n"}{end}')
        for svc in $services; do
            if ! kubectl get svc $svc -n $ingress_namespace &> /dev/null; then
                echo "  - Service $svc referenced by Ingress $ingress_name does not exist in namespace $ingress_namespace"
            fi
        done

        local secrets=$(kubectl get ingress $ingress_name -n $ingress_namespace -o=jsonpath='{range .spec.tls[*]}{.secretName}{"\n"}{end}')
        for secret in $secrets; do
            if ! kubectl get secret $secret -n $ingress_namespace &> /dev/null; then
                echo "  - Secret $secret used in TLS configuration for Ingress $ingress_name does not exist in namespace $ingress_namespace"
            fi
        done
    done <<< "$ingresses"
}

# Function to analyze Pods
analyze_pods() {
    pods=$(kubectl get pods -n $NAMESPACE -o=jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.namespace}{"\n"}{end}')

    echo "Analyzing Pods in namespace $NAMESPACE..."
    while IFS= read -r line; do
        IFS=' ' read -r pod_name pod_namespace <<< "$line"
        local conditions=$(kubectl get pod $pod_name -n $pod_namespace -o=jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{" "}{.reason}{": "}{.message}{"\n"}{end}')
        local container_statuses=$(kubectl get pod $pod_name -n $pod_namespace -o=jsonpath='{range .status.containerStatuses[*]}{.name}{" "}{.state.waiting.reason}{"\n"}{end}')

        for cond in $conditions; do
            IFS='=' read -r cond_type cond_status <<< "$cond"
            if [[ "$cond_type" == "PodScheduled" && "$cond_status" == "False" ]]; then
                echo "  - Issue with PodScheduled condition: $cond"
            fi
        done

        for status in $container_statuses; do
            IFS=' ' read -r container_name wait_reason <<< "$status"
            if [[ -n "$wait_reason" && "$wait_reason" != "<no value>" ]]; then
                echo "  - Issue with container $container_name: $wait_reason"
            fi
        done
    done <<< "$pods"
}

# Function to analyze Persistent Volume Claims (PVCs)

analyze_pvcs() {
    pvcs=$(kubectl get pvc -n $NAMESPACE -o=jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.namespace}{"\n"}{end}')

    echo "Analyzing PVCs in namespace $NAMESPACE..."
    while IFS= read -r line; do
        IFS=' ' read -r pvc_name pvc_namespace <<< "$line"
        local pvc_status=$(kubectl get pvc $pvc_name -n $pvc_namespace -o=jsonpath='{.status.phase}')
        if [[ "$pvc_status" == "Pending" ]]; then
            local latest_event=$(kubectl get event --field-selector involvedObject.name=$pvc_name,involvedObject.kind=PersistentVolumeClaim -n $pvc_namespace --sort-by='.metadata.creationTimestamp' | tail -1)
            if [[ $latest_event == *"ProvisioningFailed"* ]]; then
                echo "  - Issue with PVC: Provisioning Failed - $latest_event"
            fi
        fi
    done <<< "$pvcs"
}


# Function to analyze Services

analyze_services() {
    services=$(kubectl get svc -n $NAMESPACE -o=jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.namespace}{"\n"}{end}')

    echo "Analyzing Services in namespace $NAMESPACE..."
    while IFS= read -r line; do
        IFS=' ' read -r svc_name svc_namespace <<< "$line"
        local endpoints=$(kubectl get endpoints $svc_name -n $svc_namespace -o=jsonpath='{.subsets[*]}')
        if [ -z "$endpoints" ]; then
            echo "Service $svc_name in namespace $svc_namespace has no endpoints."
        else
            local not_ready_addresses=$(kubectl get endpoints $svc_name -n $svc_namespace -o=jsonpath='{.subsets[*].notReadyAddresses[*].ip}')
            if [ ! -z "$not_ready_addresses" ]; then
                echo "Service $svc_name in namespace $svc_namespace has not ready endpoints: $not_ready_addresses"
            fi
        fi
    done <<< "$services"
}

# Function to analyze StatefulSets

analyze_statefulsets() {
    statefulsets=$(kubectl get statefulsets -n $NAMESPACE -o=jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.namespace}{"\n"}{end}')

    echo "Analyzing StatefulSets in namespace $NAMESPACE..."
    while IFS= read -r line; do
        IFS=' ' read -r sts_name sts_namespace <<< "$line"
        local service_name=$(kubectl get statefulset $sts_name -n $sts_namespace -o=jsonpath='{.spec.serviceName}')
        if ! kubectl get service $service_name -n $sts_namespace &> /dev/null; then
            echo "StatefulSet $sts_name in namespace $sts_namespace is using a non-existent service $service_name."
        fi

        local storage_classes=$(kubectl get statefulset $sts_name -n $sts_namespace -o=jsonpath='{.spec.volumeClaimTemplates[*].spec.storageClassName}')
        for sc in $storage_classes; do
            if ! kubectl get sc $sc &> /dev/null; then
                echo "StatefulSet $sts_name in namespace $sts_namespace is using a non-existent storage class $sc."
            fi
        done
    done <<< "$statefulsets"
}

# Function to analyze webhooks

analyze_webhooks() {
    echo "Analyzing Webhooks in namespace $NAMESPACE..."

    # Merge both mutating and validating webhook configurations
    for webhook_type in mutatingwebhookconfiguration validatingwebhookconfiguration; do
        webhookconfigs=$(kubectl get $webhook_type -n $NAMESPACE -o=jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.namespace}{"\n"}{end}')

        while IFS= read -r line; do
            IFS=' ' read -r webhook_config_name webhook_config_namespace <<< "$line"
            webhooks=$(kubectl get $webhook_type $webhook_config_name -o=jsonpath='{range .webhooks[*]}{.name}{"\n"}{end}')

            for webhook in $webhooks; do
                service_name=$(kubectl get $webhook_type $webhook_config_name -o=jsonpath="{.webhooks[?(@.name==\"$webhook\")].clientConfig.service.name}")
                service_namespace=$(kubectl get $webhook_type $webhook_config_name -o=jsonpath="{.webhooks[?(@.name==\"$webhook\")].clientConfig.service.namespace}")

                if [ -z "$service_name" ]; then
                    continue
                fi

                if ! kubectl get svc $service_name -n $service_namespace &> /dev/null; then
                    echo "Webhook $webhook in $webhook_type $webhook_config_name references non-existent Service $service_name in namespace $service_namespace"
                    continue
                fi

                selector=$(kubectl get svc $service_name -n $service_namespace -o=jsonpath='{.spec.selector}')
                if [ -z "$selector" ]; then
                    continue
                fi

                running_pods=$(kubectl get pods -n $service_namespace -l $selector -o=jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}')
                if [ -z "$running_pods" ]; then
                    echo "No running pods found for Service $service_name referenced by Webhook $webhook in $webhook_type $webhook_config_name"
                fi
            done
        done <<< "$webhookconfigs"
    done
}

# Function to analyze Network Policies

analyze_networkpolicies() {
    networkpolicies=$(kubectl get networkpolicy -n $NAMESPACE -o=jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.namespace}{"\n"}{end}')

    echo "Analyzing NetworkPolicies in namespace $NAMESPACE..."
    while IFS= read -r line; do
        IFS=' ' read -r np_name np_namespace <<< "$line"
        local pod_selector=$(kubectl get networkpolicy $np_name -n $np_namespace -o=jsonpath='{.spec.podSelector.matchLabels}')
        if [ -z "$pod_selector" ]; then
            echo "NetworkPolicy $np_name in namespace $np_namespace does not apply to any pods."
        else
            local matching_pods=$(kubectl get pods -n $np_namespace -l "$pod_selector" --no-headers 2> /dev/null | wc -l)
            if [ "$matching_pods" -eq 0 ]; then
                echo "NetworkPolicy $np_name in namespace $np_namespace does not match any running pods."
            fi
        fi
    done <<< "$networkpolicies"
}

# Function to analyze Nodes

analyze_nodes() {
    nodes=$(kubectl get nodes -o=jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

    echo "Analyzing all nodes in the cluster..."
    for node in $nodes; do
        conditions=$(kubectl get node $node -o=jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{" "}{.reason}{": "}{.message}{"\n"}{end}')

        echo "Analyzing Node: $node"
        for cond in $conditions; do
            IFS='=' read -r cond_type cond_status <<< "$cond"
            case $cond_type in
                Ready)
                    if [ "$cond_status" != "True" ]; then
                        echo "  - Issue with NodeReady condition: $cond"
                    fi
                    ;;
                *)
                    if [ "$cond_status" != "False" ]; then
                        echo "  - Issue with $cond_type condition: $cond"
                    fi
                    ;;
            esac
        done
    done
}


# Function to analyze logs 

analyze_logs() {
    local tail_lines=100  # Number of log lines to check
    local error_pattern="error|exception|fail"

    echo "Analyzing pod logs in namespace $NAMESPACE..."

    # Get all Pods in the specified namespace
    pods=$(kubectl get pods -n $NAMESPACE -o=jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

    # Analyze logs for each pod
    for pod in $pods; do
        # Fetching the last few lines of logs from the pod
        logs=$(kubectl logs --tail=$tail_lines $pod -n $NAMESPACE 2>/dev/null)

        # Searching for error patterns in the log
        if echo "$logs" | grep -E "$error_pattern"; then
            echo "Errors found in logs of Pod $pod in namespace $NAMESPACE"
        else
            echo "No significant errors found in logs of Pod $pod in namespace $NAMESPACE"
        fi
    done
}

echo "Starting Kubernetes resources analysis in namespace: $NAMESPACE"

# Call analysis functions
analyze_cronjobs
analyze_deployments
analyze_gateways
analyze_hpas
analyze_httproutes
analyze_ingresses
analyze_pods
analyze_pvcs
analyze_services
analyze_statefulsets
analyze_webhooks
analyze_networkpolicies
analyze_nodes
analyze_logs

echo "Analysis completed"
