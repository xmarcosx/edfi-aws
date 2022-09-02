# edfi-aws

MacOS
```sh
brew install awscli;
aws configure;
```

VPC, subnets, and routing tables
```sh
# set environment variables
AWS_DEFAULT_REGION=us-east-1;
AWS_VPC_ID="";
AWS_PUBLIC_SUBNET="";
AWS_PRIVATE_SUBNET_1="";
AWS_PRIVATE_SUBNET_2="";
AWS_IGW_ID="";
AWS_ROUTE_TABLE_ID="";


# create vpc (virtual private cloud)
AWS_VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query Vpc.VpcId --output text);

# create two subnets in vpc
# public subnet
aws ec2 create-subnet --vpc-id $AWS_VPC_ID --availability-zone us-east-1a --cidr-block 10.0.0.0/24;
# private subnet 1
aws ec2 create-subnet --vpc-id $AWS_VPC_ID --availability-zone us-east-1b --cidr-block 10.0.1.0/24;
# private subnet 2
aws ec2 create-subnet --vpc-id $AWS_VPC_ID --availability-zone us-east-1c --cidr-block 10.0.2.0/24;

# create internet gateway as a first step to making a subnet public
AWS_IGW_ID=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text);

# attach gateway to vpc
aws ec2 attach-internet-gateway --vpc-id $AWS_VPC_ID --internet-gateway-id $AWS_IGW_ID;

# crete route table for vpc
# A route table contains a set of rules, called routes, that determine where network traffic from your subnet or gateway is directed.
AWS_ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id $AWS_VPC_ID --query RouteTable.RouteTableId --output text);

aws ec2 create-route --route-table-id $AWS_ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $AWS_IGW_ID;

# run command below and note the subnet id of the first subnet
aws ec2 describe-subnets --filters "Name=vpc-id,Values=${AWS_VPC_ID}" --query "Subnets[*].{ID:SubnetId,CIDR:CidrBlock}";

# associate route table with subnet
# this turns subnet into a public subnet
aws ec2 associate-route-table  --subnet-id <SUBNET_ID> --route-table-id $AWS_ROUTE_TABLE_ID;

# instances launched in subnet will automatically receive public ip
aws ec2 modify-subnet-attribute --subnet-id <SUBNET_ID> --map-public-ip-on-launch;
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

PUBLIC_SECURITY_GROUP=XXXXXXX;

# allow ssh access from current ip address
aws ec2 authorize-security-group-ingress \
    --group-id <SEC_GROUP_ID> \
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
    --security-group-ids <SEC_GROUP_ID> \
    --subnet-id <SUBNET_ID>;

# retrieve public ip address
aws ec2 describe-instances \
    --instance-id <EC2_INSTANCE_ID> \
    --query "Reservations[*].Instances[*].{State:State.Name,Address:PublicIpAddress}";

# connect via ssh
ssh -i "AwsKeyPair.pem" ec2-user@XXX.XXX.XXX.XXX;
```


RDS
```sh
# create security group for private db instance
# take note of the security group id
aws ec2 create-security-group \
    --group-name postgresql-access \
    --description "Security group for PostgreSQL access" \
    --vpc-id $AWS_VPC_ID;

PRIVATE_SECURITY_GROUP=XXXXXXXXX;

aws ec2 authorize-security-group-ingress \
    --group-id $PRIVATE_SECURITY_GROUP \
    --protocol tcp \
    --port 5432 \
    --source-group $PUBLIC_SECURITY_GROUP;

aws rds create-db-subnet-group \
    --db-subnet-group-name db-subnet-group \
    --db-subnet-group-description "Subnet group for PostgreSQL" \
    --subnet-ids $AWS_PRIVATE_SUBNET_1 $AWS_PRIVATE_SUBNET_2;

aws rds create-db-cluster \
    --db-cluster-identifier edfi-ods-cluster \
    --engine aurora-postgresql \
    --engine-version 11.16 \
    --master-username postgres \
    --master-user-password S3cur3Passwd \
    --db-subnet-group-name db-subnet-group \
    --backup-retention-period 7 \
    --vpc-security-group-ids $PRIVATE_SECURITY_GROUP;

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

# install psql cli
sudo yum install postgresql;

# clone this git repo to vm
git clone https://github.com/xmarcosx/edfi-aws.git;

# download and import ed-fi db templates
cd edfi-aws;
bash init.sh;

# PostgreSQL full server name example: edfi-ods.XXXXXX.us-east-1.rds.amazonaws.com
bash import-ods-data.sh <POSTGRESPASSWORD> <POSTGRESQL FULL SERVER NAME> # DEV TODO: replace with postgres password

# shutdown vm
sudo shutdown;

#psql -h edfi-ods.XXXXXX.us-east-1.rds.amazonaws.com -U postgres;


```

Clean up
```sh
aws ec2 delete-security-group --group-id <SEC_GROUP_ID>;
aws ec2 delete-subnet --subnet-id <SUBNET_ID>;
aws ec2 delete-route-table --route-table-id $AWS_ROUTE_TABLE_ID;
aws ec2 detach-internet-gateway --internet-gateway-id $AWS_IGW_ID --vpc-id $AWS_VPC_ID;
aws ec2 delete-internet-gateway --internet-gateway-id $AWS_IGW_ID;
aws ec2 delete-vpc --vpc-id $AWS_VPC_ID;
```
