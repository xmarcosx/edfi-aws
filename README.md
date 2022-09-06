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



# Table of Contents  
* [Environment variables](#environment-variables)
* [Networking](#networking)
* [Jumpbox](#jumpbox)
* [Amazon RDS](#amazon-rds)
* [Ed-Fi API](#ed-fi-api)


## Environment variables
Throughout the installer, you will be creating resources in AWS. Those resources are given unique ids which you will store in various environment variables to be used in future commands. Run the first command below to create an environment variable `AWS_DEFAULT_REGION` that is set to use `us-east-1`. This will be your default region for new resources in AWS.

```sh
AWS_DEFAULT_REGION=us-east-1;
```


## Networking
Let's start by creating a new VPC (Virtual Private Cloud), several subnets, and other pieces of networking infrastructure. A VPC is a virtual network dedicated to your AWS account. Within a VPC are one or more subnets. A subnet is a range of IP addresses in your VPC. You launch AWS resources, such as Amazon EC2 instances, into your subnets. You can connect a subnet to the internet, and route traffic to and from your subnets using route tables.

### VPC
Copy and paste the command below to create a vpc and automatically store its id in `AWS_VPC_ID`
```sh
AWS_VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query Vpc.VpcId --output text);
echo $AWS_VPC_ID;
```

Note, if you run `echo $AWS_VPC_ID`, you will see the env variable, `AWS_VPC_ID`, has been set to the VPC ID of the newly created VPC.

### Subnets
You will create three subnets in your VPC. Two will be private and one will be public. It is important that we don't expose all resources to the public internet. For example, exposing your RDS instance that runs your Ed-Fi ODS to the public internet would be a bad idea.

Copy and paste the commands below to create your subnets.
```sh
AWS_PUBLIC_SUBNET=$(aws ec2 create-subnet \
    --vpc-id $AWS_VPC_ID \
    --availability-zone us-east-1a \
    --cidr-block 10.0.0.0/24 \
    --query Subnet.SubnetId --output text);
echo $AWS_PUBLIC_SUBNET;
```

```sh
AWS_PRIVATE_SUBNET_1=$(aws ec2 create-subnet \
    --vpc-id $AWS_VPC_ID \
    --availability-zone us-east-1b \
    --cidr-block 10.0.1.0/24 \
    --query Subnet.SubnetId --output text);
echo $AWS_PRIVATE_SUBNET_1;
```

```sh
AWS_PRIVATE_SUBNET_2=$(aws ec2 create-subnet \
    --vpc-id $AWS_VPC_ID \
    --availability-zone us-east-1c \
    --cidr-block 10.0.2.0/24 \
    --query Subnet.SubnetId --output text);
echo $AWS_PRIVATE_SUBNET_1;
```

You've created three new subnets which are viewable at the URL below, but at this point they are all private. Let's make one of them public.

https://us-east-1.console.aws.amazon.com/vpc/home?region=us-east-1#subnets:


### Internet gateway
An internet gateway allows communication between your VPC and the internet. It enables resources in your public subnets (such as EC2 instances) to connect to the internet if they have a public ip address.

Run the commands below to create an internet gateway and attach it to your VPC.
```sh
AWS_IGW_ID=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text);
echo $AWS_IGW_ID;
```
```sh
aws ec2 attach-internet-gateway --vpc-id $AWS_VPC_ID --internet-gateway-id $AWS_IGW_ID;
```

We are now going to create a route table. A route table contains a set of rules, called routes, that determine where network traffic from your subnet or gateway is directed. If a subnet is associated with a route table that has a route to an internet gateway, it's known as a public subnet. If a subnet is associated with a route table that does not have a route to an internet gateway, it's known as a private subnet.

Run the commands below to create a route table, route, associate the route table with the first subnet you created, and finally to configure the subnet to automatically assignn public ip addresses to any resources created in it.
```sh
AWS_ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id $AWS_VPC_ID --query RouteTable.RouteTableId --output text);
echo $AWS_ROUTE_TABLE_ID;
```
```sh
aws ec2 create-route --route-table-id $AWS_ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $AWS_IGW_ID;
```
```sh
aws ec2 associate-route-table  --subnet-id $AWS_PUBLIC_SUBNET --route-table-id $AWS_ROUTE_TABLE_ID;
```
```sh
aws ec2 modify-subnet-attribute --subnet-id $AWS_PUBLIC_SUBNET --map-public-ip-on-launch;
```


## Jumpbox
Later on, we will create a PostgreSQL RDS (Relational Database Service) instance that will serve as your Ed-Fi ODS. This will exist in a private subnet and will not be accessible from the internet. However, we will need to connect to it initially so that we can seed it with the various tables required by Ed-Fi. To do that, we will create an EC2 VM (virtual machine) that will serve as our jumpbox. This Linux VM will be publicly accessible from the internet allowing us to SSH into it and from there, connect to our PostgreSQL instance.

We will authenticate with the VM using a key pair. A key pair, consisting of a public key and a private key, is a set of security credentials that you use to prove your identity when connecting to an Amazon EC2 instance.

Run the command below to create a new key pair. This will create the key pair in AWS and store the private key in a .pem file on your machine. You will also run a `chmod` command to restrict access to it.
```sh
aws ec2 create-key-pair --key-name MyKeyPair --query "KeyMaterial" --output text > AwsKeyPair.pem;
```
```sh
chmod 400 AwsKeyPair.pem;
```

We are now going to create a security group. A security group controls the traffic that is allowed to reach and leave the resources that it is associated with. We are going to create a security group that allows access to port 22 when the traffic originates from your public ip address.

```sh
AWS_PUBLIC_SECURITY_GROUP=$(aws ec2 create-security-group --group-name SSHAccess --description "Security group for SSH access" --vpc-id $AWS_VPC_ID --query GroupId --output text);
echo $AWS_PUBLIC_SECURITY_GROUP;
```

```sh
aws ec2 authorize-security-group-ingress \
    --group-id $AWS_PUBLIC_SECURITY_GROUP \
    --protocol tcp \
    --port 22 \
    --cidr $(curl http://checkip.amazonaws.com)/32;
```

Run the command below to create your VM. This VM has 1 vCPU and 1 GB of RAM, and runs Amazon's linux distro.
```sh
AWS_EC2_INSTANCE_ID=$(aws ec2 run-instances \
    --image-id ami-a4827dc9 \
    --count 1 \
    --instance-type t2.micro \
    --key-name MyKeyPair \
    --security-group-ids $AWS_PUBLIC_SECURITY_GROUP \
    --subnet-id $AWS_PUBLIC_SUBNET \
    --query "Instances[*].InstanceId" --output text);
echo $AWS_EC2_INSTANCE_ID;
```


### Amazon RDS
We are going to use Aurora PostgreSQL on Amazon RDS for our Ed-Fi ODS. Using a managed service for our ODS is going to provide us with automated backups, automatic minor version upgrades, and flexible compute, memory, and storage.

Before we create the RDS instance, we are going to create a security group. This security group will authorize access to port 5432, the default port for PostgreSQL.
```sh
AWS_ODS_SECURITY_GROUP=$(aws ec2 create-security-group --group-name postgresql-access --description "Security group for PostgreSQL access" --vpc-id $AWS_VPC_ID --query GroupId --output text);
echo $AWS_ODS_SECURITY_GROUP;
```
```sh
aws ec2 authorize-security-group-ingress \
    --group-id $AWS_ODS_SECURITY_GROUP \
    --protocol tcp \
    --port 5432 \
    --source-group $AWS_PUBLIC_SECURITY_GROUP;
```
```sh
AWS_DEFAULT_SECURITY_GROUP=$(aws ec2 describe-security-groups \
    --filters Name=vpc-id,Values=$AWS_VPC_ID Name=group-name,Values=default \
    --query "SecurityGroups[*].GroupId" --output text);
echo $AWS_DEFAULT_SECURITY_GROUP;
```
```sh
aws ec2 authorize-security-group-ingress \
    --group-id $AWS_ODS_SECURITY_GROUP \
    --protocol tcp \
    --port 5432 \
    --source-group $AWS_DEFAULT_SECURITY_GROUP;
```

The command below is going to create a subnet group consisting of our two private subnets.
```sh
aws rds create-db-subnet-group \
    --db-subnet-group-name db-subnet-group \
    --db-subnet-group-description "Subnet group for PostgreSQL cluster" \
    --subnet-ids $AWS_PRIVATE_SUBNET_1 $AWS_PRIVATE_SUBNET_2;
```

You will now create a RDS cluster that uses Amazon's Aurora PostgreSQL as the engine, is compatible with PostgreSQL v11.16, will run in your two private subnets thanks to your subnet group, and uses the password you set below as your postgres user's password.
```sh
EDFI_ODS_PASSWORD='XXXXXXXXXXX';
```
```sh
aws rds create-db-cluster \
    --db-cluster-identifier edfi-ods-cluster \
    --engine aurora-postgresql \
    --engine-version 11.16 \
    --master-username postgres \
    --master-user-password $EDFI_ODS_PASSWORD \
    --db-subnet-group-name db-subnet-group \
    --backup-retention-period 7 \
    --vpc-security-group-ids $AWS_ODS_SECURITY_GROUP;
```

This RDS instance is configured to have 2 vCPUs and 4 GB of memory.
```sh
aws rds create-db-instance \
    --db-cluster-identifier edfi-ods-cluster \
    --engine aurora-postgresql \
    --db-instance-identifier edfi-ods \
    --db-instance-class db.t3.medium \
    --no-publicly-accessible \
    --no-multi-az;
```

If you navigate to the URL below, you will see your new instance being created.

https://us-east-1.console.aws.amazon.com/rds/home?region=us-east-1#databases:


We are now going to SSH into your VM, connect to your PostgreSQL instance, create the databases listed below, and seed them with data.
* EdFi_Admin
* EdFi_Security
* EdFi_Ods_2021
* EdFi_Ods_2022
* EdFi_Ods_2023

Run the command below and take note of the public ip address of your VM.
```sh
aws ec2 describe-instances \
    --instance-id $AWS_EC2_INSTANCE_ID \
    --query "Reservations[*].Instances[*].{State:State.Name,Address:PublicIpAddress}";
```

Run the command below and take note of your RDS instance's endpoint.
```sh
aws rds describe-db-instances \
    --db-instance-identifier edfi-ods \
    --region $AWS_DEFAULT_REGION \
    --query "DBInstances[*].Endpoint.Address" --output text;
```

Run the command below to SSH into your VM. Since this is the first time you're connecting to it, you will be asked if you're sure you'd like to connect. Enter yes and hit enter.
```sh
ssh -i "AwsKeyPair.pem" ec2-user@XXX.XXX.XXX.XXX;
```

Run the command below to install a few pre-requisites.
```sh
sudo yum install postgresql git;
```

Clone this repo to your VM so you have access to the scripts we need to run.
```sh
git clone https://github.com/xmarcosx/edfi-aws.git;
```

`cd` into the folder and download the database backups from the Ed-Fi Alliance's Azure Artifacts repository.
```sh
cd edfi-aws;
bash init.sh;
```

Run the command below to seed your databases. Be sure to replace the brackets with your values!
```sh
# ie. bash import-ods-data.sh SuperSecret edfi-ods.XXXXX.us-east-1.rds.amazonaws.com
bash import-ods-data.sh <POSTGRES PASSWORD> <RDS ENDPOINT ADDRESS>
```

Go ahead and shutdown your VM to reduce billing charges.
```
sudo shutdown -H now;
```

You have successfully deployed your Ed-Fi ODS! Let's move on to the Ed-Fi API.


### Ed-Fi API
We are going to use AWS App Runner for the Ed-Fi API. AWS App Runner is a fully managed service used to deploy containerized web applications and APIs. We can provide App Runner with a containter image and it will deploy it automatically, load balance traffic with encryption, scale to meet traffic needs, and communicate with other AWS services and applications that run in a private Amazon VPC.

Before we can create the App Runner application, we need a container image. We can going to build an image and push it to Elastic Container Registry (ECR), a container registry.

Run the command below to create a repository.
```sh
AWS_API_REPOSITORY_URI=$(aws ecr create-repository \
    --repository-name edfi-api \
    --image-scanning-configuration scanOnPush=true \
    --region $AWS_DEFAULT_REGION \
    --query "repository.repositoryUri" --output text);
echo $AWS_API_REPOSITORY_URI;
```

From within your `edfi-aws` folder. Run the command to build a Docker image.
```sh
docker build -t edfi-api edfi-api/.;
```

Run the command below to log into ECR.
```sh
aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $AWS_API_REPOSITORY_URI;
```

Tag your image with your ECR repository URL.
```sh
docker tag edfi-api:latest $AWS_API_REPOSITORY_URI;
```

Push the image to ECR.
```sh
docker push $AWS_API_REPOSITORY_URI;
```

You have successfully created a Docker image of the Ed-Fi API and pushed it to your AWS ECS repository. We are now going to deploy an App Runner service using that image. Head to https://us-east-1.console.aws.amazon.com/apprunner/home?region=us-east-1#/welcome

Click *Create an App Runner service*

**Source**
* **Repository type:** Container registry
* **Provider:** Amazon ECR
* **Container image URI:** Click *Browse* and select:
    * **Image repository:** edfi-api
    * **Image tag:** latest
    * Click *Continue*

**Deployment settings**
* **Deployment trigger:** Manual
* Select *Create new service role*
* Click *Next*

**Service settings**
* **Service name:** edfi-api
* **Virtual CPU & memory:** 2 vCPUs and 4 GB memory
* Add two environment variables
    * **Key:** DB_HOST
        * Set the value to your ODS endpoint
    * **Key:** DB_PASS
        * Set the value to your postgres user password
* **Port:** 80

**Networking**
* **Outgoing network traffic:** Custom VPC
    * Click *Add new*
    * **VPC connector name:** vpc-connector
    * **VPC:** Select the VPC you created earlier
    * **Subnets:** Select your two private subnets (10.0.1.0/24 and 10.0.2.0/24)
    * **Security groups:** Select your default security group
    * Click *Add*
* Click *Next*
* Click *Create & deploy*


### Ed-Fi Admin App
We are going to use AWS App Runner for the Ed-Fi Admin App.

Run the command below to create a repository.
```sh
AWS_ADMIN_APP_REPOSITORY_URI=$(aws ecr create-repository \
    --repository-name edfi-admin-app \
    --image-scanning-configuration scanOnPush=true \
    --region $AWS_DEFAULT_REGION \
    --query "repository.repositoryUri" --output text);
echo $AWS_ADMIN_APP_REPOSITORY_URI;
```

From within your `edfi-aws` folder. Run the command to build a Docker image.
```sh
docker build -t edfi-admin-app edfi-admin-app/.;
```

Run the command below to log into ECR.
```sh
aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $AWS_ADMIN_APP_REPOSITORY_URI;
```

Tag your image with your ECR repository URL.
```sh
docker tag edfi-admin-app:latest $AWS_ADMIN_APP_REPOSITORY_URI;
```

Push the image to ECR.
```sh
docker push $AWS_ADMIN_APP_REPOSITORY_URI;
```

You have successfully created a Docker image of the Ed-Fi Admin App and pushed it to your AWS ECS repository. We are now going to deploy an App Runner service using that image. Head to https://us-east-1.console.aws.amazon.com/apprunner/home?region=us-east-1#/welcome

Click *Create service*

**Source**
* **Repository type:** Container registry
* **Provider:** Amazon ECR
* **Container image URI:** Click *Browse* and select:
    * **Image repository:** edfi-admin-app
    * **Image tag:** latest
    * Click *Continue*

**Deployment settings**
* **Deployment trigger:** Manual
* Select *Use existing service role*
* Select the role from the dropdown
* Click *Next*

**Service settings**
* **Service name:** edfi-admin-app
* **Virtual CPU & memory:** 1 vCPUs and 2 GB memory
* Add two environment variables
    * **Key:** API_URL
        * Set the value to your Ed-Fi API base url (ie. https://XXXXXXX.us-east-1.awsapprunner.com)
    * **Key:** ENCRYPTION_KEY
        * Set the value to the output of this command: `/usr/bin/openssl rand -base64 32`
    * **Key:** DB_HOST
        * Set the value to your ODS endpoint
    * **Key:** DB_PASS
        * Set the value to your postgres user password
* **Port:** 80

**Networking**
* **Outgoing network traffic:** Custom VPC
* Select the VPC connector created when you deployed the Ed-Fi API
* Click *Next*
* Click *Create & deploy*
