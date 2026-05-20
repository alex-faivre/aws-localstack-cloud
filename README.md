# aws-localstack-cloud

Lab d'infrastructure n-tiers AWS déployé sur **LocalStack Pro** via Terraform.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  VPC 172.16.0.0/16                                          │
│                                                             │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐    │
│  │ Public AZ-a  │   │ Public AZ-b  │   │ Public AZ-c  │    │
│  │ + NAT GW     │   └──────────────┘   └──────────────┘    │
│  │ + EC2 web-1  │                                          │
│  └──────┬───────┘                                          │
│         │                                                  │
│  ┌──────┴───────┐   ┌──────────────┐   ┌──────────────┐    │
│  │ Web AZ-a     │   │ Web AZ-b     │   │ Web AZ-c     │    │
│  └──────────────┘   └──────────────┘   └──────────────┘    │
│         (routés via NAT GW)                                │
└─────────────────────────────────────────────────────────────┘

      DynamoDB (hors VPC, service managé)
      Secrets Manager (credentials applicatifs)
```

| Composant | Ressource Terraform | Description |
|---|---|---|
| Réseau | `aws_vpc`, `aws_subnet`, `aws_internet_gateway`, `aws_nat_gateway`, `aws_route_table` | VPC `172.16.0.0/16`, 3 AZ, subnets public + web, NAT vers Internet |
| Sécurité | `aws_security_group` | SG ALB (80/443 public), SG web (80 depuis ALB + 22 SSH configurable via `var.allowed_ssh_cidrs`) |
| Calcul | `aws_instance`, `aws_key_pair`, `data.aws_ami` | 1 instance Ubuntu dans le subnet public. AMI résolue par `data "aws_ami"` Canonical filtré sur `var.instance_architecture` (default `x86_64`), overridable par `var.web_ami_id`. Type d'instance via `var.web_instance_type` (default `t3.micro`). Clé SSH `localstack` |
| Données | `aws_dynamodb_table` | Table `lab-factory-table`, `PAY_PER_REQUEST`, PITR + SSE actifs |
| Secrets | `aws_secretsmanager_secret`, `random_password` | Credentials applicatifs (username + password 24 chars généré) |
| DevX | `local_file` | Génère `.env.local` après chaque `apply` |

## Prérequis

- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.5
- [LocalStack Pro](https://docs.localstack.cloud/getting-started/installation/) (token requis) ou compte trial
- AWS CLI v2
- `jq` pour parser le secret JSON

## Mise en route

### 1. Démarrer LocalStack Pro

```bash
export LOCALSTACK_AUTH_TOKEN=ls-...

docker run -d \
  --name localstack-aws \
  -p 4566:4566 \
  -e LOCALSTACK_AUTH_TOKEN \
  -v /var/run/docker.sock:/var/run/docker.sock \
  localstack/localstack-pro:latest
```

Vérifier :
```bash
curl -s http://localhost:4566/_localstack/info | jq '.edition, .is_license_activated'
```

Attendu : `"pro"` et `true`.

### 2. Déployer

```bash
cd aws-n-tiers-localstack/aws-n-tiers-localstack

terraform init
terraform plan
terraform apply
```

L'apply produit automatiquement un fichier `.env.local` avec toutes les variables nécessaires (endpoint LocalStack, credentials test, nom du secret, etc.).

> **Architecture CPU** : par défaut `instance_architecture = "x86_64"` et `web_instance_type = "t3.micro"`. Sur AWS réel avec Graviton ou Mac M-series, override en ligne de commande ou via `terraform.tfvars` :
> ```bash
> terraform apply -var instance_architecture=arm64 -var web_instance_type=t4g.micro
> ```
> Sur LocalStack, le catalogue d'AMI mocké ne contient que du x86_64 — laisser le défaut, ou forcer une AMI précise via `-var web_ami_id=ami-xxxxxxxx`.

### 3. Charger l'environnement

```bash
source .env.local
```

Tu disposes alors de :

| Variable | Usage |
|---|---|
| `AWS_ENDPOINT_URL` | Redirige toutes les commandes AWS CLI vers LocalStack |
| `AWS_REGION` | `eu-west-3` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Credentials factices (`test`/`test`) |
| `DB_SECRET_NAME` / `DB_SECRET_ARN` | Identifiants du secret |
| `DYNAMODB_TABLE_NAME` / `DYNAMODB_TABLE_ARN` | Identifiants de la table |

Astuce : avec [direnv](https://direnv.net) (`brew install direnv` puis `direnv allow`), renommer `.env.local` en `.envrc` charge automatiquement les variables à chaque `cd` dans le dossier.

## Commandes utiles

### Récupérer le password applicatif

```bash
# Bundle JSON complet (username, password, table_name, region)
aws secretsmanager get-secret-value --secret-id "$DB_SECRET_NAME" \
  --query SecretString --output text | jq

# Password seul, capturé dans une variable shell sans affichage
DB_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_NAME" \
  --query SecretString --output text | jq -r .password)
```

### Tester DynamoDB

```bash
aws dynamodb describe-table --table-name "$DYNAMODB_TABLE_NAME"

aws dynamodb put-item --table-name "$DYNAMODB_TABLE_NAME" \
  --item '{"id":{"S":"test-001"},"message":{"S":"hello"}}'

aws dynamodb scan --table-name "$DYNAMODB_TABLE_NAME"
```

### SSH vers l'instance EC2 (limité — voir notes)

```bash
$(terraform output -raw ssh_command)
# Équivalent :
ssh -o StrictHostKeyChecking=no -i ./localstack ubuntu@$(terraform output -raw web_public_ip)
```

> **⚠️ SSH host → VM EC2 impossible sur macOS — limite documentée**
>
> Sur macOS, **SSH depuis le host vers une instance EC2 LocalStack n'est intrinsèquement pas possible**. Citation verbatim de la [doc LocalStack EC2](https://docs.localstack.cloud/aws/services/ec2/) :
> > *"Network access from host to EC2 instance containers is not possible on macOS. This is because Docker Desktop on macOS does not expose the bridge network to the host system."*
>
> Symptômes côté API : `describe-instances` retourne `running` avec une IP publique fictive (54.x.x.x), mais aucun service n'écoute derrière. `ssh` aboutit à un timeout ou un refus.
>
> Testé sur ce repo avec LocalStack Pro `2026.4.3` (stable) **et** `2026.5.0.dev` (dev), avec `EC2_VM_MANAGER=docker` + `DEBUG=1` + image taguée `localstack-ec2/<name>:<ami-id>` exactement comme [le sample officiel `ec2-docker-instances`](https://github.com/localstack-samples/localstack-pro-samples/tree/master/ec2-docker-instances) → aucun container backing n'est spawned. Voir aussi [Issue #8367](https://github.com/localstack/localstack/issues/8367).
>
> **Le code Terraform reste valide pour AWS réel** : `aws_key_pair`, `aws_instance`, `aws_security_group` avec port 22 s'appliqueraient correctement sur un compte AWS et SSH y fonctionnerait nativement.
>
> **Workarounds possibles** si SSH local est indispensable :
> - Remplacer Docker Desktop par **OrbStack** ou **Colima** qui exposent le bridge network au host sur macOS.
> - Ajouter un **container side-car** (`linuxserver/openssh-server`) hors stack Terraform, accessible sur `localhost:2222`.
> - Déployer sur **AWS réel** (retirer les `endpoints` LocalStack du `provider.tf`).

### Détruire

```bash
terraform destroy
```

## Sécurité

- Le **password DB n'apparaît pas dans les outputs Terraform** ni dans `.env.local` (seul l'ARN du secret est exposé). Il est récupéré à la demande via `secretsmanager:GetSecretValue`.
- ⚠️ **Le password EST présent dans le state Terraform** (marqué `sensitive`) parce que `random_password.db.result` et `aws_secretsmanager_secret_version.secret_string` y sont persistés. Conséquences :
  - Le `terraform.tfstate` local **n'est pas chiffré** par défaut → ne pas le commiter (déjà dans `.gitignore`), ne pas le partager.
  - Pour un usage sérieux : utiliser un **backend distant chiffré** (S3 + KMS, Terraform Cloud, HCP Terraform) avec accès restreint.
  - Alternative : utiliser l'argument **`secret_string_wo`** (write-only, Terraform ≥ 1.11 + AWS provider ≥ 5.83) qui n'est pas persisté en state.
- La **clé SSH privée** (`localstack`) est dans `.gitignore` (seule la `.pub` est versionnée).
- Le `.env.local` est généré avec les permissions `0600` et ignoré par git.
- **`terraform.tfvars` est versionné** dans ce repo (les `.gitignore` ré-incluent explicitement `!terraform.tfvars`), mais **ne contient aucun credential** — uniquement des valeurs non sensibles (`project_name`, `aws_region`, `vpc_cidr`, `db_username`). Tout secret doit passer par Secrets Manager.
- **SSH ouvert à `0.0.0.0/0` par défaut** via `var.allowed_ssh_cidrs` — acceptable pour LocalStack en local, mais **à restreindre obligatoirement sur AWS réel** (CIDR de votre IP, bastion, SSM Session Manager).

## Structure du repo

```
.
├── README.md                            # Ce fichier
├── .gitignore
└── aws-n-tiers-localstack/
    └── aws-n-tiers-localstack/
        ├── provider.tf                  # Providers AWS / random / local + endpoints LocalStack
        ├── variables.tf                 # Variables (project_name, region, vpc_cidr, db_username, web_ami_id, web_instance_type, instance_architecture, allowed_ssh_cidrs)
        ├── terraform.tfvars             # Valeurs versionnées non sensibles (pas de credentials)
        ├── network.tf                   # VPC, subnets, IGW, NAT, route tables
        ├── security-groups.tf           # SG ALB et web (SSH paramétrable)
        ├── ec2.tf                       # key_pair, data aws_ami Canonical, instance
        ├── dynamodb.tf                  # Table DynamoDB
        ├── secrets.tf                   # random_password + Secrets Manager
        ├── load-balancer.tf             # ALB (commenté, à activer)
        ├── route53.tf                   # Route53 (commenté, à activer)
        ├── outputs.tf
        ├── env.tf                       # Génère .env.local
        ├── localstack.pub               # Clé SSH publique versionnée
        └── .gitignore
```

## Limitations connues

- **SSH vers la VM EC2 impossible sur macOS** : Docker Desktop n'expose pas le bridge network au host ([doc LocalStack](https://docs.localstack.cloud/aws/services/ec2/)). Voir section "SSH vers l'instance EC2" plus haut pour les workarounds (OrbStack/Colima, side-car, AWS réel).
- **EC2 Docker VM Manager non opérationnel** sur ce setup (Mac ARM + LocalStack Pro stable/dev) même avec la config officielle du sample LocalStack ([Issue #8367](https://github.com/localstack/localstack/issues/8367)). L'instance reste en mock côté API. Le code Terraform reste valide pour AWS réel.
- LocalStack **Community** (gratuit) ne supporte de toute façon que le **mock VM manager** pour EC2.
- Les modules **ALB** et **Route53** sont commentés (`load-balancer.tf`, `route53.tf`) — à activer pour un setup n-tiers complet.
- Le **NAT Gateway sur LocalStack** rencontre parfois un bug `'NoneType' object has no attribute 'shutdown'` au destroy → contournement : `rm terraform.tfstate*` et restart du container LocalStack.
