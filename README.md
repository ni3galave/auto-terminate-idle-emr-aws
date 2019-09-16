# auto-terminate-idle-emr-aws
Auto terminate idle EMR using Amazon CloudWatch metrics and AWS Lambda.



### Prerequisite Step: 
Create resources that are required to create auto terminate emr's

Use auto_terminate_resource_stack.json file to create stack to generate resource's like Roles, Toppics, Lamda for terminating emr etc.

### To Create Auto Terminate EMR:

Use auto_terminate_emr_stack.json file to create stack for creating emr cluster's with specified default configuration in the current json file.


Refs: [Optimize Amazon EMR costs with idle checks and automatic resource termination using advanced Amazon CloudWatch metrics and AWS Lambda](https://aws.amazon.com/blogs/big-data/optimize-amazon-emr-costs-with-idle-checks-and-automatic-resource-termination-using-advanced-amazon-cloudwatch-metrics-and-aws-lambda/)
