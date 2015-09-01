#!/bin/bash -e

function usage {
    echo "USAGE: $0 <command>"
    echo "Commands:"
    echo -e "\tinit \tInitialize worker node services"
    echo -e "\tstart \tStart worker node services"
}

if [ -z $1 ]; then
    usage
    exit 1
fi

CMD=$1

# Sanity check kubelet is available (missing will exit with set -e)
which kubelet
K8S_VER=$(kubelet --version | awk '{print $2}')

function init_config {
    local REQUIRED=( 'ADVERTISE_IP' 'ETCD_ENDPOINTS' 'CONTROLLER_ENDPOINT' 'DNS_SERVICE_IP' )

    if [ -z $ADVERTISE_IP ]; then
        export ADVERTISE_IP=$(awk -F= '/COREOS_PUBLIC_IPV4/ {print $2}' /etc/environment)
    fi
    if [ -z $ETCD_ENDPOINTS ]; then
        export ETCD_ENDPOINTS="http://127.0.0.1:2379"
    fi
    if [ -z $CONTROLLER_ENDPOINT ]; then
        export CONTROLLER_ENDPOINT="http://127.0.0.1:8080"
    fi
    if [ -z $DNS_SERVICE_IP ]; then
        export DNS_SERVICE_IP="10.3.0.10"
    fi

    for REQ in "${REQUIRED[@]}"; do
        if [ -z "$(eval echo \$$REQ)" ]; then
            echo "Missing required config value: ${REQ}"
            exit 1
        fi
    done
}

function init_docker {
    local TEMPLATE=/etc/systemd/system/docker.service.d/40-flannel.conf
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Unit]
Requires=flanneld.service
After=flanneld.service
EOF
    }

    # reload now before docker commands are run in later
    # init steps or dockerd will start before flanneld
    systemctl daemon-reload
}

function init_kubectl {
    [ -f /opt/bin/kubectl ] || {
        mkdir -p /opt/bin
        curl --silent -o /opt/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/$K8S_VER/bin/linux/amd64/kubectl
        chown core:core /opt/bin/kubectl
        chmod +x /opt/bin/kubectl
    }
}

function init_templates {
    local TEMPLATE=/etc/systemd/system/kubelet.service
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Service]
ExecStartPre=/usr/bin/mkdir -p /etc/kubernetes/manifests
ExecStart=/usr/bin/kubelet \
  --api_servers=${CONTROLLER_ENDPOINT} \
  --allow-privileged=true \
  --config=/etc/kubernetes/manifests \
  --hostname-override=${ADVERTISE_IP} \
  --cluster_dns=${DNS_SERVICE_IP} \
  --cluster_domain=cluster.local \
  --kubeconfig=/srv/kubernetes/istv-kubeconfig.yaml \
  --cadvisor-port=0
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
    }

  local TEMPLATE=/srv/kubernetes/istv-kubeconfig.yaml
  [ -f $TEMPLATE ] || {
      echo "TEMPLATE: $TEMPLATE"
      mkdir -p $(dirname $TEMPLATE)
      cat << EOF > $TEMPLATE
apiVersion: v1
kind: Config
clusters:
- name: control
  cluster:
     insecure-skip-tls-verify: true
contexts:
- context:
    cluster: control
  name: default-context
current-context: default-context
EOF
    }


    local TEMPLATE=/etc/kubernetes/manifests/kube-proxy.yaml
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Pod
metadata:
  name: kube-proxy
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-proxy
    image: gcr.io/google_containers/hyperkube:$K8S_VER
    command:
    - /hyperkube
    - proxy
    - --master=${CONTROLLER_ENDPOINT}
    - --kubeconfig=/config/kubeconfig.yaml
    securityContext:
      privileged: true
    volumeMounts:
      - mountPath: /etc/ssl/certs
        name: "ssl-certs"
      - mountPath: /config/kubeconfig.yaml
        name: kubeconfig
        readOnly: true
  volumes:
    - name: "ssl-certs"
      hostPath:
        path: "/usr/share/ca-certificates"
    - name: "kubeconfig"
      hostPath:
        path: "/srv/kubernetes/istv-kubeconfig.yaml"
EOF
    }

  local TEMPLATE=/home/core/.kube/config
  [ -f $TEMPLATE ] || {
      echo "TEMPLATE: $TEMPLATE"
      mkdir -p $(dirname $TEMPLATE)
      cat << EOF > $TEMPLATE
apiVersion: v1
kind: Config
clusters:
- name: default
  cluster:
    server: ${CONTROLLER_ENDPOINT}
    insecure-skip-tls-verify: true
users:
- name: core
  user:
    username: core
    password: core
contexts:
- name: default-context
  context:
    cluster: default
    user: core
current-context: default-context
EOF
    }
}

if [ "$CMD" == "init" ]; then
    echo "Starting initialization"
    init_config
    init_docker
    init_kubectl
    init_templates
    echo "Initialization complete"
    exit 0
fi

if [ "$CMD" == "start" ]; then
    echo "Starting services"
    systemctl daemon-reload
    systemctl enable kubelet; systemctl start kubelet
    echo "Service start complete"
    exit 0
fi

usage
exit 1

