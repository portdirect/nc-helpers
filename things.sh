#!/bin/bash

function kubectl {
  export KUBECONFIG=/etc/kubernetes/admin/kubeconfig.yaml
  if [ ! -f $HOME/kubectl ]; then
    CONTAINER=$(docker create "$(awk '/hyperkube-amd64/ { print $1 ; exit }' /usr/local/bin/kubectl)")
    docker cp "$CONTAINER:/hyperkube" "$HOME/kubectl"
    docker rm "$CONTAINER"
  fi
  $HOME/kubectl $@
}

function helm {
  export KUBECONFIG=/etc/kubernetes/admin/kubeconfig.yaml
  if [ ! -f $HOME/helm ]; then
    CONTAINER=$(docker create "$(awk '/k8s-helm/ { print $1 ; exit }' /usr/local/bin/helm)")
    docker cp "$CONTAINER:/usr/local/bin/helm" "$HOME/helm"
    docker rm "$CONTAINER"
  fi
  $HOME/helm $@
}

function host_jump {
  HOST=$1
  kubectl -n ucp exec -it "$(kubectl get -n ucp pods -l application=divingbell,component=exec -o wide --no-headers | awk "/${HOST}/ { print \$1; exit }")" -- nsenter -t 1 -m -u -n -i bash
}

function get_openrc {
  SERVICE=$1
  USER=$2
  TEMPLATE=$(mktemp)
  echo '{{ range $k, $v := .data }}export {{$k}}={{ $v | base64decode}}{{"\n"}}{{end}}' > ${TEMPLATE}
  kubectl get -n openstack secrets "${SERVICE}-keystone-${USER}" -o go-template-file=${TEMPLATE}
  rm -f ${TEMPLATE}
  echo "export OS_IDENTITY_API_VERSION=3"
}

function run_os_command {
  SERVICE=$1
  USER=$2
  COMMAND=${@:3}
  TEMPLATE=$(mktemp)
  echo '{{ range $k, $v := .data }}-e {{$k}}={{ $v | base64decode}} {{end}}' > ${TEMPLATE}
  OPENRC=$(kubectl get -n openstack secrets "${SERVICE}-keystone-${USER}" -o go-template-file=${TEMPLATE})
  rm -f ${TEMPLATE}
  HEAT_IMAGE=$(kubectl -n openstack get jobs keystone-db-init -o jsonpath='{$.spec.template.spec.containers[0].image}')
  docker run --rm -e OS_IDENTITY_API_VERSION=3 ${OPENRC} -v /tmp:/tmp ${HEAT_IMAGE} ${COMMAND}
}

function job_rerun {
  NS=$1
  JOB=$2
  JOB_JSON_ORIGINAL=$(mktemp --suffix=".json")
  kubectl get -n "$NS" jobs "$JOB" -o=json > "$JOB_JSON_ORIGINAL"
  JOB_JSON_RE_RUN=$(mktemp --suffix=".json")
  jq 'del(.status) | del(.metadata.creationTimestamp) | del(.metadata.labels."controller-uid") | del(.metadata.resourceVersion) | del(.metadata.selfLink) | del(.metadata.uid) | del(.spec.selector) | del(.spec.template.metadata.creationTimestamp) | del(.spec.template.metadata.labels."controller-uid" )' "$JOB_JSON_ORIGINAL" > "$JOB_JSON_RE_RUN"
  kubectl delete -f "$JOB_JSON_ORIGINAL"
  kubectl create -f "$JOB_JSON_RE_RUN"
}

function get_ceph_creds {
  NS=$1
  mkdir -p /etc/ceph
  MON_POD=$(kubectl -n "$NS" get pods -l application=ceph,component=mon -o name | awk -F '/' '{ print $2; exit }')
  for FILE in /etc/ceph/ceph.conf /etc/ceph/ceph.client.admin.keyring; do
    kubectl exec -it -n "$NS" "$MON_POD" -- cat "$FILE" > $FILE
  done
}
