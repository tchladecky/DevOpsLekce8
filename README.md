# ECS Nginx Demo – s ECR

Nginx aplikace s vlastní `index.html`, nasazená na **AWS ECS Fargate** přes vlastní **ECR registry** pomocí **Terraform** a **GitHub Actions**.

## Architektura

```
GitHub Actions
  ├─ Job 1: docker build → push do ECR
  └─ Job 2: terraform apply → ECS Service
                                  ↓
Internet → ALB (HTTP:80) → ECS Fargate Task
                                  ↓
               nginx:alpine z ECR (vlastní index.html)
```

## Struktura souborů

```
.
├── Dockerfile                        # Staví image na bázi nginx:alpine
├── index.html                        # Vlastní stránka servírovaná nginxem
├── main.tf                           # Kompletní Terraform infrastruktura
├── terraform.tfvars                  # Hodnoty proměnných
└── .github/workflows/deploy.yml     # CI/CD pipeline
```

## Postup nasazení

### 1. Příprava (jednorázové kroky)

```bash
# a) Vytvoř S3 bucket pro Terraform state (jméno musí být unikátní)
aws s3api create-bucket \
  --bucket tfstate-$(aws sts get-caller-identity --query Account --output text)-eu-central-1 \
  --region us-east-1

# b) Uprav bucket v main.tf:
#    backend "s3" { bucket = "tfstate-<číslo-účtu>-eu-central-1" ... }
```

### 2. Vytvoř ECR registry jako první (pomocí -target)

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...

terraform init

# Nasaď POUZE ECR registry
terraform apply -target=aws_ecr_repository.nginx -auto-approve

# Ulož ECR URL do proměnné
ECR_URL=$(terraform output -raw ecr_repository_url)
echo "ECR URL: $ECR_URL"
```

### 3. Build a push Docker image

```bash
# Přihlas se do ECR
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin $ECR_URL

# Build
docker build -t ${ECR_URL}:latest .

# Push
docker push ${ECR_URL}:latest
```

### 4. Nasaď zbytek infrastruktury

```bash
terraform apply -auto-approve
```

### 5. Otestuj

```bash
curl $(terraform output -raw load_balancer_url)
# → Měl by vrátit tvůj index.html
```

## CI/CD (GitHub Actions)

### Nastavení GitHub Secrets

| Secret | Popis |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS access key |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key |

### Co pipeline dělá

1. **Job `docker`** – build image, tag SHA + latest, push do ECR
2. **Job `terraform`** – `terraform apply -var="image_tag=<SHA>"` → nasadí novou verzi do ECS

### Workflow na PR vs push

| Událost | Chování |
|---|---|
| Pull Request | Pouze `docker` job (build + push na SHA) |
| Push do `main` | `docker` + `terraform apply` + test dostupnosti |

## IAM Role – přehled

| Role | Použití |
|---|---|
| `ecs-nginx-demo-task-execution-role` | ECS agent – pull image z ECR, zápis logů do CloudWatch |
| `ecs-nginx-demo-task-role` | Runtime role kontejneru – přidej inline policy pokud kontejner potřebuje volat AWS API |

## Debugging

```bash
# Stav service
aws ecs describe-services \
  --cluster ecs-nginx-demo-cluster \
  --services ecs-nginx-demo-service

# Logy kontejneru
aws logs tail /ecs/ecs-nginx-demo --follow

# ECR images
aws ecr list-images --repository-name ecs-nginx-demo
```

## Čištění

```bash
terraform destroy -auto-approve
# S3 bucket se NEsmaže automaticky – odstraň ručně
```

## URL aplikace

Po nasazení:
```
http://<ALB DNS>   ← terraform output load_balancer_url
```
