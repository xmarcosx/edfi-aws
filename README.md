# Ed-Fi on AWS
The AWS CLI commands below will deploy the following Ed-Fi components on AWS. This installer uses the AWS CLI in place of infrastructure as code solutions such as Terraform because the purpose of the installer is to explain each step along the way. Take your time and read through each section to ensure you understand each component of the Ed-Fi platform on AWS.

* Ed-Fi API and ODS Suite 3 v5.3
* Ed-Fi Admin App v2.3.2
* TPDM Core v1.1.1

![AWS](/img/aws.png)


## Costs
| Component             | AWS product | Configuration                                   | Yearly cost            |
| --------------------- | -------------------- | ----------------------------------------------- | ---------------------- |
| Ed-Fi ODS             | Aurora PostgreSQL on RDS            | PostgreSQL 11,<br>2 vCPUs,<br>4 GB of memory      |               |
| Ed-Fi API             | App Runner                       | 2 vCPU,<br>4 GB of memory                                                         |  |
| Ed-Fi Admin App       | App Runner                       | 1 vCPU,<br>2 GB of memory                                                         |  |


## Prerequisites
You will need both the AWS cli and Docker Desktop installed on your machine.

### MacOS
```sh
brew install docker;
brew install awscli;
aws configure;
```

### Windows

* [AWS cli download](https://awscli.amazonaws.com/AWSCLIV2.msi)


## Environment variables
Throughout the installer, you will be creating resources in AWS. Those resources are given unique ids which you will store in various environment variables to be used in future commands. Run the first command below to create an environment variable `AWS_DEFAULT_REGION` that is set to use `us-east-1`. This will be your default region for new resources in AWS.

```sh
AWS_DEFAULT_REGION=us-east-1;
```

View the list of environment variables below as your "scratchpad." As you run through the steps below, you will be asked to store various values as environment variables. Come back up here and update the values.
```sh
AWS_VPC_ID="vpc-";
AWS_PUBLIC_SUBNET="subnet-";
AWS_PRIVATE_SUBNET_1="subnet-";
AWS_PRIVATE_SUBNET_2="subnet-";
AWS_IGW_ID="igw-";
AWS_ROUTE_TABLE_ID="rtb-";
AWS_PUBLIC_SECURITY_GROUP="sg-";
AWS_EC2_INSTANCE_ID="i-";
AWS_ODS_SECURITY_GROUP="sg-";
AWS_API_REPOSITORY_URI="XXXXXXX.dkr.ecr.us-east-1.amazonaws.com/edfi-api";

EDFI_ODS_PASSWORD="XXXXXXXXX";
```


## Networking
Let's start by creating a new VPC (Virtual Private Cloud), several subnets, and other pieces of networking infrastructure. A VPC is a virtual network dedicated to your AWS account. Within a VPC are one or more subnets. A subnet is a range of IP addresses in your VPC. You launch AWS resources, such as Amazon EC2 instances, into your subnets. You can connect a subnet to the internet, and route traffic to and from your subnets using route tables.

### VPC
Run the command below to create a vpc and automatically store its id in `AWS_VPC_ID`
```sh
AWS_VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query Vpc.VpcId --output text);
```

Note, if you run `echo $AWS_VPC_ID`, you will see the env variable, `AWS_VPC_ID`, has been set to the VPC ID of the newly created VPC.

### Subnets
You will create three subnets in your VPC. Two will be private and one will be public. It is important that we don't expose all resources to the public internet. For example, exposing your RDS instance that runs your Ed-Fi ODS to the public internet would be a bad idea.

Run the command below to create your first subnet. This will return information on the newly created subnet. Copy the `SubnetId` value and run the 2nd command to store it in your `AWS_PUBLIC_SUBNET` variable.
```sh
aws ec2 create-subnet --vpc-id $AWS_VPC_ID --availability-zone us-east-1a --cidr-block 10.0.0.0/24;
AWS_PUBLIC_SUBNET="subnet-XXXXXXXXX";
```

Create two more subnets, assigning the ids to `AWS_PRIVATE_SUBNET_1` and `AWS_PRIVATE_SUBNET_2`.
```sh
aws ec2 create-subnet --vpc-id $AWS_VPC_ID --availability-zone us-east-1b --cidr-block 10.0.1.0/24;
AWS_PRIVATE_SUBNET_1="subnet-XXXXXXXXX";

aws ec2 create-subnet --vpc-id $AWS_VPC_ID --availability-zone us-east-1c --cidr-block 10.0.2.0/24;
AWS_PRIVATE_SUBNET_2="subnet-XXXXXXXXX";
```

You've created three new subnets, but at this point they are all private. Let's make one of them public.

### Internet gateway
An internet gateway allows communication between your VPC and the internet. It enables resources in your public subnets (such as EC2 instances) to connect to the internet if the resource has a public ip address.

Run the commands below to create an internet gateway and attach it to your VPC.
```sh
AWS_IGW_ID=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text);
aws ec2 attach-internet-gateway --vpc-id $AWS_VPC_ID --internet-gateway-id $AWS_IGW_ID;
```


```sh
# crete route table for vpc
AWS_ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id $AWS_VPC_ID --query RouteTable.RouteTableId --output text);

aws ec2 create-route --route-table-id $AWS_ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $AWS_IGW_ID;

# associate route table with subnet
# this turns subnet into a public subnet
aws ec2 associate-route-table  --subnet-id $AWS_PUBLIC_SUBNET --route-table-id $AWS_ROUTE_TABLE_ID;

# instances launched in subnet will automatically receive public ip
aws ec2 modify-subnet-attribute --subnet-id $AWS_PUBLIC_SUBNET --map-public-ip-on-launch;
```

EC2 jumpbox
```sh
# create ssh key file
aws ec2 create-key-pair --key-name MyKeyPair --query "KeyMaterial" --output text > AwsKeyPair.pem;

# restrict access to file
chmod 400 AwsKeyPair.pem;

# create security group in vpc
# take note of the security group id
aws ec2 create-security-group \
    --group-name SSHAccess \
    --description "Security group for SSH access" \
    --vpc-id $AWS_VPC_ID;

# allow ssh access from current ip address
aws ec2 authorize-security-group-ingress \
    --group-id $AWS_PUBLIC_SECURITY_GROUP \
    --protocol tcp \
    --port 22 \
    --cidr $(curl http://checkip.amazonaws.com)/32;

# create ec2 vm
# take note of the instance id
aws ec2 run-instances \
    --image-id ami-a4827dc9 \
    --count 1 \
    --instance-type t2.micro \
    --key-name MyKeyPair \
    --security-group-ids $AWS_PUBLIC_SECURITY_GROUP \
    --subnet-id $AWS_PUBLIC_SUBNET;

# retrieve public ip address
aws ec2 describe-instances \
    --instance-id $AWS_EC2_INSTANCE_ID \
    --query "Reservations[*].Instances[*].{State:State.Name,Address:PublicIpAddress}";
```


RDS
```sh
# create security group for private db instance
# take note of the security group id
aws ec2 create-security-group \
    --group-name postgresql-access \
    --description "Security group for PostgreSQL access" \
    --vpc-id $AWS_VPC_ID;

aws ec2 authorize-security-group-ingress \
    --group-id $AWS_ODS_SECURITY_GROUP \
    --protocol tcp \
    --port 5432 \
    --source-group $AWS_PUBLIC_SECURITY_GROUP;

aws rds create-db-subnet-group \
    --db-subnet-group-name db-subnet-group \
    --db-subnet-group-description "Subnet group for PostgreSQL" \
    --subnet-ids $AWS_PRIVATE_SUBNET_1 $AWS_PRIVATE_SUBNET_2;

aws rds create-db-cluster \
    --db-cluster-identifier edfi-ods-cluster \
    --engine aurora-postgresql \
    --engine-version 11.16 \
    --master-username postgres \
    --master-user-password $EDFI_ODS_PASSWORD \
    --db-subnet-group-name db-subnet-group \
    --backup-retention-period 7 \
    --vpc-security-group-ids $AWS_ODS_SECURITY_GROUP;

aws rds create-db-instance \
    --db-cluster-identifier edfi-ods-cluster \
    --engine aurora-postgresql \
    --db-instance-identifier edfi-ods \
    --db-instance-class db.t3.medium \
    --no-publicly-accessible \
    --no-multi-az;
```

Seeding the ODS
```sh
# connect via ssh
ssh -i "AwsKeyPair.pem" ec2-user@XXX.XXX.XXX.XXX;

# install psql and git
sudo yum install postgresql git;

# clone this git repo to vm
git clone https://github.com/xmarcosx/edfi-aws.git;

# download and import ed-fi db templates
cd edfi-aws;
bash init.sh;

# PostgreSQL full server name example: edfi-ods.XXXXXX.us-east-1.rds.amazonaws.com
bash import-ods-data.sh <POSTGRESPASSWORD> <POSTGRESQL FULL SERVER NAME> # DEV TODO: replace with postgres password

# shutdown vm
sudo shutdown -H now;
```

Push Docker image to ECR
```sh
# note repository uri and save to AWS_API_REPOSITORY_URI
aws ecr create-repository \
    --repository-name edfi-api \
    --image-scanning-configuration scanOnPush=true \
    --region $AWS_DEFAULT_REGION;

docker build -t edfi-api edfi-api/.;

aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin XXXXXXXXX.dkr.ecr.us-east-1.amazonaws.com;
docker tag edfi-api:latest $AWS_API_REPOSITORY_URI;
docker push $AWS_API_REPOSITORY_URI;
```

Ed-Fi Web API on App Runner
```sh
aws apprunner create-service --cli-input-json file://api.json;
```
