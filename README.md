# How to add warm pools for Amazon EC2 Auto Scaling to self-managed node groups in Amazon Elastic Kubernetes Service
This example demonstrates how to configure an [Amazon Elastic Kubernetes Service](https://aws.amazon.com/eks/) (EKS) self-managed node group with an [Amazon EC2 Auto Scaling](https://aws.amazon.com/ec2/autoscaling/) [warm pool](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-warm-pools.html). The key components that enable this are the [user data](./user_data/), initial lifecycle policy, warm pool configuration, and the additional [IAM permissions](./policies/NodeAdditional.json). Though not the focus of this example, the user-data also demonstrates how to configure nodes to work with a http proxy.

Using a warm pool with EKS gives you the ability to decrease the time it takes for nodes to join the cluster because you can pre-initialize the [Amazon EC2](https://aws.amazon.com/pm/ec2/) instances. Reasons for long startup times include installing/building software and configuring hosts, writing massive amounts of data to disk, or longer initialization times for a particular instance type family. Where possible, startup times should be reduced by creating [Amazon Machine Images](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AMIs.html) (AMIs) that are more ["fully baked"](https://docs.aws.amazon.com/whitepapers/latest/workspaces-linux-best-practices/fully-baked.html). Another reason to use a warm pool might be to preserve data in memory for stateful applications, though there may be better options for that, e.g. StatefulSets with persistent volumes.

However, when using a warm pool with EKS, you should prevent instances that are entering the warm pool from registering with the cluster as a node. Otherwise, the cluster might schedule resources on the instance as it prepares to be stopped or unavailable, leading to potentially unpredictable behavior. Instead, newly launched instances headed for the warm pool should go through their full initialization, but skip the bootstrapping process that registers nodes with the cluster. When these instances are selected to go into service during a scale out, they can skip the bulk of their initialization and run the bootstrap script to join the cluster. The implementation in this repo uses a [self-managed node group](https://docs.aws.amazon.com/eks/latest/userguide/worker.html) so that you provision and manage the entire lifecycle of the instances, launch template, and auto scaling group, rather than using EKS [managed node groups](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html), which automates the provisioning and lifecycle management of nodes in an auto scaling group for you.

Notes:
* Warm pools are not compatible with [mixed instance policies](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-mixed-instances-groups.html) in auto scaling groups.
* Warm pool instance reuse policies do not currently work with Cluster Autoscaler because it terminates instances directly, rather than adjusting the desired capacity.

## Prerequisites
* [Terraform](https://www.terraform.io/)
* [AWS Command Line Interface](https://aws.amazon.com/cli/)(CLI)
* [kubectl](https://docs.aws.amazon.com/eks/latest/userguide/install-kubectl.html)
* [Helm](https://helm.sh/)

## Deploy
* When you create an EKS cluster, the IAM entity user or role that creates the cluster is automatically granted `system:masters` permissions in the cluster's role-based access control (RBAC) configuration in the EKS control plane. It is a best practice to create the cluster with a dedicated IAM role and regularly audit who can assume this role. Whether you choose to employ this strategy or not for this example, just be sure to use the same credentials that created the cluster to access the cluster via `kubectl` and the AWS console.
* Deploy the cluster and supporting resources using the template in [examples/main.tf](examples/main.tf).
```bash
cd examples
terraform init
terraform apply
# enter "yes", if ready
```
* Deploy the self-managed node group. Open [main.tf](examples/main.tf), find the `module "smng"` code block, and change `count` to `1`. Then, repeat the `terraform apply` command from the previous step.

## Test
* Add the cluster to your kubeconfig file for use with kubectl by running the command in the `configure_kubectl` output value. For example:
```bash
aws eks update-kubeconfig --region us-west-2 --name example --alias example
```
* Verify the nodes have joined the cluster.
```bash
kubectl get nodes
```
* Navigate to the **Auto Scaling Groups** page in the **EC2** console, select the auto scaling group, choose the **Instance management** tab, and verify instances are in the **Warm pool instances** section.

### Scale-out with Cluster Autoscaler
* [Cluster Autoscaler](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/aws/README.md) (CA) requires permissions to examine and modify auto scaling groups. You can use either [IAM roles for service accounts](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) (IRSA) or [EKS pod identities](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html) (EKSPI) to associate the CA service account with an IAM role that has the required permissions. This example currently uses IRSA, but will be updated to use EKSPI in the future.
* Deploy CA. If you made any changes to the EKS cluster version, network configuration, etc. update the arguments in the script accordingly. See the [Helm chart](https://github.com/kubernetes/autoscaler/tree/master/charts) for reference - be sure to select the appropriate tag based on the version of the cluster and CA you wish to deploy.
```bash
sh ../helm/install_cluster_autoscaler.sh
```
* Verify it successfully deployed by running the command generated by the chart.
* Create and scale a test deployment. Update `<image>` with the image you wish to use, e.g. nginx. The number of replicas specified below is based on the default instance type being used for the nodes. If you change this, pick a number based on the available number of pods from the **Capacity allocation** dashboard associated with each node in the EKS console **Compute** tab.
```bash
kubectl create deployment ca-demo --image=<image>
kubectl scale deployment ca-demo --replicas=15
```
* Navigate back to the **Instance Management** tab for the auto scaling group and refresh both the **Instances** and **Warm pool instances** tables until you see that an instance from the warm pool was promoted to **InService**.
* Verify the new node(s) joined the cluster and all the pods scheduled for the deployment are running. Note the time it took to join the cluster versus the initial time to launch and join.
```bash
kubectl get nodes
kubectl get pods --show-labels; kubectl get pods -l=app=ca-demo
```
* To observe behavior on scale-in, delete the deployment.
```bash
kubectl delete deployment ca-demo
```
* Warm pools can also be beneficial in case of unplanned instance failures. To test, simply terminate one of the active instances/nodes and verify a recovery instance joins from the warm pool.

## Proxy configuration
* If traffic to/from pods on the worker nodes will be routed through a proxy, you need to apply a ConfigMap with the proxy environment variables and patch the `kube-proxy` and `aws-node` DaemonSets to use the ConfigMap. See [How can I automate the configuration of HTTP proxy for Amazon EKS containerd nodes](https://repost.aws/knowledge-center/eks-http-proxy-containerd-automation) for details.

## Destroy
- Destroy the stack
```bash
terraform destroy
```
