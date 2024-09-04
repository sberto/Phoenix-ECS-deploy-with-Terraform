# Default Phoenix Project with Terraform Deploy for ECS

This project serves as a starting point for a Phoenix application. It includes several key features to help you get started with your development and deployment process:

- **Terraform Deployment**: Included in the project is a Terraform script for deploying the application to Amazon's Elastic Container Service (ECS). This allows for easy and automated deployment of your application to a scalable and managed container service. The Terraform script is in the `terraform` directory.

- **Dockerfile**: A Dockerfile is provided for building a Docker image of the application.

- **Docker Compose**: For local development, a Docker Compose file is included. This allows you to easily run your application locally in the same Dockerized environment as it would run in production.

By using this project as a starting point, you can focus on writing your application code, knowing that the foundations for building, running, and deploying your application are already in place.

## TODO
- Improve the `terraform` script split the `main.tf` into multiple files.
- Improve the VPC configuration, splitting between private and public subnets. Currently the security group enables the traffic only from the public ip of the machine running the terraform script).