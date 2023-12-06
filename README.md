# How to add warm pools for Amazon EC2 Auto Scaling to self-managed node groups in Amazon Elastic Kubernetes Service 
This example demonstrates how to configure an EKS self-managed node group with a warm pool. The key components that make this work are the [user data](./user_data/), initial lifecycle policy, warm pool configuration, and the additional [IAM permissions](./policies/NodeAdditional.json). Though not the focus of this example, the user-data also demonstrates how to configure nodes to work with a http proxy.

## Prerequisites
* Terraform
* AWS CLI is installed

## Deploy
* When you create an Amazon EKS cluster, the IAM entity user or role that creates the cluster is automatically granted `system:masters` permissions in the cluster's role-based access control (RBAC) configuration in the Amazon EKS control plane. It is a best practice to create the cluster with a dedicated IAM role and regularly audit who can assume this role. Whether you choose to employ this strategy or not for this example, just be sure to use the same credentials that created the cluster to access the cluster via `kubectl` and the AWS console. 
* Deploy the cluster and supporting resources using the template in [examples/main.tf](examples/main.tf).
```bash
cd examples
terraform init
terraform apply
# enter "yes", if ready
```
* Deploy the self-managed node group. Open [main.tf](examples/main.tf), find the `module "smng"` code block, and change `count` to `1`. Then, repeat the `terraform` commands from the previous step.

## Test
* Navigate to the Auto Scaling groups console, select the auto scaling group, choose the Instance Management tab, and verify instances are in the warm pool.
* Select one of the active instance IDs on that page, which will open an instance summary page. Terminate the instance via the Instance state button, and monitor the ASG to verify an instance from the warm pool becomes active; note the time it took to join the cluster versus the initial time to launch via `kubectl` or the EKS console.


## Destroy
- Destroy the stack
```bash
terraform destroy
```
