
#!/bin/bash

REGION="us-phoenix-1"
COMPARTMENT_ID="your-compartment-id"
AVAILABILITY_DOMAIN="your-availability-domain"
SSH_KEY_PATH="$HOME/.ssh/id_rsa"
PROJECT_ID="your-oracle-project-id"
MASTER_NODE_NAME="master-node"
WORKER_NODE_NAME="worker-node"
DOCKER_IMAGE="iad.ocir.io/$PROJECT_ID/my-erlang-api:v1"
DOMAIN="your-domain.com"
EMAIL="your-email@example.com"
K8S_NAMESPACE="default"

# Ensure Terraform is installed
if ! command -v terraform &> /dev/null
then
  echo "Terraform not found, installing..."
  sudo apt-get update -y
  sudo apt-get install -y wget unzip
  TERRAFORM_VERSION="1.5.0"
  wget https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip
  unzip terraform_${TERRAFORM_VERSION}_linux_amd64.zip
  sudo mv terraform /usr/local/bin/
  rm terraform_${TERRAFORM_VERSION}_linux_amd64.zip
  echo "Terraform installed successfully."
fi

# Ensure OCI CLI is installed
if ! command -v oci &> /dev/null
then
  echo "OCI CLI not found, installing..."
  sudo apt-get update
  sudo apt-get install -y python3-pip
  pip3 install oci-cli --upgrade
  oci setup config
  echo "OCI CLI installed successfully."
fi

# Provision Oracle Cloud VMs using Terraform
echo "Provisioning Oracle Cloud VMs using Terraform..."

cat <<EOF > main.tf
provider "oci" {
  region = "${REGION}"
}

resource "oci_core_instance" "master" {
  availability_domain = "${AVAILABILITY_DOMAIN}"
  compartment_id      = "${COMPARTMENT_ID}"
  shape               = "VM.Standard.E2.1.Micro"
  display_name        = "${MASTER_NODE_NAME}"
  image_id            = "ocid1.image.oc1.phx.aaaaaaaaybzd22v7pp73xyo77o4tnx4rtvwyclbne3g5eqmf7k6jq7gsjzxa"
  subnet_id           = "subnet-ocid"
  ssh_authorized_keys = file("${SSH_KEY_PATH}")
}

resource "oci_core_instance" "worker" {
  availability_domain = "${AVAILABILITY_DOMAIN}"
  compartment_id      = "${COMPARTMENT_ID}"
  shape               = "VM.Standard.E2.1.Micro"
  display_name        = "${WORKER_NODE_NAME}"
  image_id            = "ocid1.image.oc1.phx.aaaaaaaaybzd22v7pp73xyo77o4tnx4rtvwyclbne3g5eqmf7k6jq7gsjzxa"
  subnet_id           = "subnet-ocid"
  ssh_authorized_keys = file("${SSH_KEY_PATH}")
}

output "master_ip" {
  value = oci_core_instance.master.public_ip
}

output "worker_ip" {
  value = oci_core_instance.worker.public_ip
}
EOF

terraform init
terraform apply -auto-approve

MASTER_IP=$(terraform output -raw master_ip)
WORKER_IP=$(terraform output -raw worker_ip)

echo "Master Node IP: $MASTER_IP"
echo "Worker Node IP: $WORKER_IP"

echo "Setting up Kubernetes on both nodes..."

for ip in $MASTER_IP $WORKER_IP; do
  echo "Configuring node at $ip..."
  ssh -i $SSH_KEY_PATH ubuntu@$ip << EOF
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    sudo usermod -aG docker \$USER
    sudo apt-get update
    sudo apt-get install -y kubelet kubeadm kubectl
    sudo systemctl restart docker
    if [ "\$ip" == "$MASTER_IP" ]; then
      sudo kubeadm init --control-plane-endpoint $MASTER_IP:6443 --pod-network-cidr=10.244.0.0/16
      mkdir -p \$HOME/.kube
      sudo cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config
      sudo chown -R \$USER:\$USER \$HOME/.kube
      kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
    else
      KUBEADM_JOIN_CMD=\$(ssh -i $SSH_KEY_PATH ubuntu@$MASTER_IP "kubeadm token create --print-join-command")
      \$KUBEADM_JOIN_CMD
    fi
EOF
done

echo "Building Docker image for Erlang API..."

cat << EOF > Dockerfile
FROM erlang:latest

WORKDIR /app
COPY . .
CMD ["erl", "-s", "my_api", "-setcookie", "secret"]
EOF

cat << EOF > api.erl
-module(my_api).
-export([start/0, hello/0]).

start() ->
    {ok, _} = cowboy:start_http(http, 100, [{port, 8080}], [cowboy_handler]),
    io:format("API started at port 8080~n").

hello() ->
    io:format("Hello, World!~n").
EOF

docker build -t $DOCKER_IMAGE .

echo "Deploying Erlang API to Kubernetes..."

kubectl apply -f - << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: erlang-api-deployment
  namespace: $K8S_NAMESPACE
spec:
  replicas: 2
  selector:
    matchLabels:
      app: erlang-api
  template:
    metadata:
      labels:
        app: erlang-api
    spec:
      containers:
      - name: erlang-api
        image: $DOCKER_IMAGE
        ports:
        - containerPort: 8080

---

apiVersion: v1
kind: Service
metadata:
  name: erlang-api-service
  namespace: $K8S_NAMESPACE
spec:
  selector:
    app: erlang-api
  ports:
  - protocol: TCP
    port: 80
    targetPort: 8080
  type: ClusterIP
EOF

echo "Setting up Cert-Manager for TLS..."

kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.8.0/cert-manager.yaml
kubectl rollout status deployment/cert-manager -n cert-manager

kubectl apply -f - << EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-prod
  namespace: $K8S_NAMESPACE
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $EMAIL
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

kubectl apply -f - << EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: tls-cert
  namespace: $K8S_NAMESPACE
spec:
  secretName: tls-secret
  dnsNames:
  - $DOMAIN
  issuerRef:
    name: letsencrypt-prod
    kind: Issuer
EOF

echo "Setting up NGINX Ingress..."

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml

kubectl apply -f - << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: erlang-api-ingress
  namespace: $K8S_NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  tls:
  - hosts:
    - $DOMAIN
    secretName: tls-secret
  rules:
  - host: $DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: erlang-api-service
            port:
              number: 80
EOF

echo "Setup complete. Visit https://$DOMAIN to access your API."

On Tue, 12 Nov 2024, 22:43 Thomas de Beer, <tjdebeer@gmail.com> wrote:
#!/bin/bash

REGION="us-phoenix-1"
COMPARTMENT_ID="your-compartment-id"
AVAILABILITY_DOMAIN="your-availability-domain"
SSH_KEY_PATH="$HOME/.ssh/id_rsa"
PROJECT_ID="your-oracle-project-id"
MASTER_INSTANCE_NAME="master-node"
WORKER_INSTANCE_NAME="worker-node"
DOCKER_IMAGE="iad.ocir.io/$PROJECT_ID/my-erlang-api:v1"
DOMAIN="your-domain.com"
EMAIL="your-email@example.com"
K8S_NAMESPACE="default"

if ! command -v terraform &> /dev/null
then
  echo "Terraform not found, installing..."
  sudo apt-get update -y
  sudo apt-get install -y wget unzip
  TERRAFORM_VERSION="1.5.0"
  wget https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip
  unzip terraform_${TERRAFORM_VERSION}_linux_amd64.zip
  sudo mv terraform /usr/local/bin/
  rm terraform_${TERRAFORM_VERSION}_linux_amd64.zip
  echo "Terraform installed successfully."
fi

if ! command -v oci &> /dev/null
then
  echo "OCI CLI not found, installing..."
  sudo apt-get update
  sudo apt-get install -y python3-pip
  pip3 install oci-cli --upgrade
  oci setup config
  echo "OCI CLI installed successfully."
fi

echo "Provisioning Oracle Cloud VMs using Terraform..."

cat <<EOF > main.tf
provider "oci" {
  region = "${REGION}"
}

resource "oci_core_instance" "master" {
  availability_domain = "${AVAILABILITY_DOMAIN}"
  compartment_id      = "${COMPARTMENT_ID}"
  shape               = "VM.Standard.E2.1.Micro"
  display_name        = "${MASTER_INSTANCE_NAME}"
  image_id            = "ocid1.image.oc1.phx.aaaaaaaaybzd22v7pp73xyo77o4tnx4rtvwyclbne3g5eqmf7k6jq7gsjzxa"
  subnet_id           = "subnet-ocid"
  ssh_authorized_keys = file("${SSH_KEY_PATH}")
}

resource "oci_core_instance" "worker" {
  availability_domain = "${AVAILABILITY_DOMAIN}"
  compartment_id      = "${COMPARTMENT_ID}"
  shape               = "VM.Standard.E2.1.Micro"
  display_name        = "${WORKER_INSTANCE_NAME}"
  image_id            = "ocid1.image.oc1.phx.aaaaaaaaybzd22v7pp73xyo77o4tnx4rtvwyclbne3g5eqmf7k6jq7gsjzxa"
  subnet_id           = "subnet-ocid"
  ssh_authorized_keys = file("${SSH_KEY_PATH}")
}

output "master_ip" {
  value = oci_core_instance.master.public_ip
}

output "worker_ip" {
  value = oci_core_instance.worker.public_ip
}
EOF

terraform init
terraform apply -auto-approve

MASTER_IP=$(terraform output -raw master_ip)
WORKER_IP=$(terraform output -raw worker_ip)

echo "Master Node IP: $MASTER_IP"
echo "Worker Node IP: $WORKER_IP"

echo "Setting up Kubernetes on both nodes..."

for ip in $MASTER_IP $WORKER_IP; do
  echo "Configuring node at $ip..."
  ssh -i $SSH_KEY_PATH ubuntu@$ip << EOF
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    sudo usermod -aG docker \$USER
    sudo apt-get update
    sudo apt-get install -y kubelet kubeadm kubectl
    if [ "\$ip" == "$MASTER_IP" ]; then
      sudo kubeadm init --control-plane-endpoint $MASTER_IP:6443 --pod-network-cidr=10.244.0.0/16
      mkdir -p \$HOME/.kube
      sudo cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config
      sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config
    fi
    if [ "\$ip" == "$WORKER_IP" ] || [ "\$ip" == "$MASTER_IP" ]; then
      sudo kubeadm join $MASTER_IP:6443 --token <your-token> --discovery-token-ca-cert-hash <your-ca-cert-hash> --control-plane
    fi
EOF
done

echo "Building Docker image for Erlang API..."

cat << EOF > Dockerfile
FROM erlang:latest

WORKDIR /app
COPY . .
CMD ["erl", "-s", "my_api", "-setcookie", "secret"]
EOF

cat << EOF > api.erl
-module(my_api).
-export([start/0, hello/0]).

start() ->
    {ok, _} = cowboy:start_http(http, 100, [{port, 8080}], [cowboy_handler]),
    io:format("API started at port 8080~n").

hello() ->
    io:format("Hello, World!~n").
EOF

docker build -t $DOCKER_IMAGE .

echo "Deploying Erlang API to Kubernetes..."

kubectl apply -f - << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: erlang-api-deployment
  namespace: $K8S_NAMESPACE
spec:
  replicas: 2
  selector:
    matchLabels:
      app: erlang-api
  template:
    metadata:
      labels:
        app: erlang-api
    spec:
      containers:
      - name: erlang-api
        image: $DOCKER_IMAGE
        ports:
        - containerPort: 8080

---

apiVersion: v1
kind: Service
metadata:
  name: erlang-api-service
  namespace: $K8S_NAMESPACE
spec:
  selector:
    app: erlang-api
  ports:
  - protocol: TCP
    port: 80
    targetPort: 8080
  type: ClusterIP
EOF

echo "Setting up Cert-Manager for TLS..."

kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.8.0/cert-manager.yaml
kubectl rollout status deployment/cert-manager -n cert-manager

kubectl apply -f - << EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-prod
  namespace: $K8S_NAMESPACE
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $EMAIL
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

kubectl apply -f - << EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: tls-cert
  namespace: $K8S_NAMESPACE
spec:
  secretName: tls-secret
  dnsNames:
  - $DOMAIN
  issuerRef:
    name: letsencrypt-prod
    kind: Issuer
EOF

echo "Setting up NGINX Ingress..."

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml

kubectl apply -f - << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: erlang-api-ingress
  namespace: $K8S_NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  tls:
  - hosts:
    - $DOMAIN
    secretName: tls-secret
  rules:
  - host: $DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: erlang-api-service
            port:
              number: 80
EOF

echo "Setup complete. Visit https://$DOMAIN to access your API."
