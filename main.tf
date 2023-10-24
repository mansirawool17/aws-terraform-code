terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "5.22.0"
    }
  }
}

provider "aws" {
  # Configuration options
  region = "us-east-1"
}

variable "cidr" { 
  default = "10.0.0.0/16"
}

#creating vpc 
resource "aws_vpc" "myvpc" {
    cidr_block = var.cidr
}

#creating subnet
resource "aws_subnet" "subnets" {
    count = 3
    vpc_id = aws_vpc.myvpc.id
    cidr_block = element(["10.0.1.0/24","10.0.2.0/24","10.0.3.0/24"],count.index)
    availability_zone = element(["us-east-1a","us-east-1b","us-east-1c"],count.index)
    map_public_ip_on_launch = true
}

#creating internet-gateway
resource "aws_internet_gateway" "myig" {
    vpc_id = aws_vpc.myvpc.id
}

#creating route table
resource "aws_route_table" "myrt" {
    vpc_id = aws_vpc.myvpc.id

    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.myig.id
    }
}

#creating security group
resource "aws_security_group" "mysg" {
    name = "sg"
    vpc_id = aws_vpc.myvpc.id
    ingress {
        description = "http from vpc"
        from_port = 80
        to_port = 80
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    ingress {
        description = "ssh"
        from_port = 22
        to_port = 22
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    egress {
        from_port = 0
        to_port = 0
        protocol = -1 #to specify all ports
        cidr_blocks = ["0.0.0.0/0"]
    }
    tags = {
        name = "mysg1"
    }
}

#creating ec2-instace - master
resource "aws_instance" "master" {
    ami = "ami-0fc5d935ebf8bc3bc"
    instance_type = "t2.medium"
    vpc_security_group_ids = [aws_security_group.mysg.id]
    subnet_id = aws_subnet.subnets[2].id
    tags = {
      name = "master"
    }
}

#creating load balancer
resource "aws_lb" "mylb" {
  name = "my-lb"
  internal = false
  load_balancer_type = "application"
  subnets = [aws_subnet.subnets[0].id,aws_subnet.subnets[1].id]
  security_groups = [aws_security_group.mysg.id]
}

#create a target group
resource "aws_lb_target_group" "mytg" {
  name = "mytargetgroup"
  port = 80
  protocol = "HTTP"
  vpc_id = aws_vpc.myvpc.id
  health_check {
    path = "/"
    protocol = "HTTP"
    port = "traffic-port"
    interval = 30
    timeout = 10
    healthy_threshold = 2
    unhealthy_threshold = 2
  }
}

#creating listener
resource "aws_alb_listener" "myarn" {
  load_balancer_arn = aws_lb.mylb.arn
  port = 80
  protocol = "HTTP"
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      status_code = "200"
    }
  }
}

#creating listener rule 
resource "aws_lb_listener_rule" "myrule" {
  listener_arn = aws_alb_listener.myarn.arn
  priority = 100
  action {
    type = "forward"
    target_group_arn = aws_lb_target_group.mytg.arn
  }
  condition {
    path_pattern {
      values = ["/example"]
    }
  }
}

#defining launch configuration 
resource "aws_launch_configuration" "mylc" {
  name_prefix = "mylc-"
  image_id = "ami-0fc5d935ebf8bc3bc"
  instance_type = "t2.micro"
  security_groups = [aws_security_group.mysg.id]
}

#creating auto-scaling group
resource "aws_autoscaling_group" "myag" {
  name = "myagroup"
  launch_configuration = aws_launch_configuration.mylc.name
  vpc_zone_identifier = [element(aws_subnet.subnets[*].id, 0), element(aws_subnet.subnets[*].id, 1)]
  min_size = 2
  max_size = 4
  desired_capacity = 2
  health_check_type = "EC2"
  health_check_grace_period = 300
  target_group_arns = [aws_lb_target_group.mytg.arn]
}


#creting sns topic 
resource "aws_sns_topic" "mysns" {
  name = "MySNSTopic"
}

#subscribing endpoints
resource "aws_sns_topic_subscription" "mysnssub" {
  topic_arn = aws_sns_topic.mysns.arn
  protocol = "email"
  endpoint = "rawool8421@gmail.com"
  confirmation_timeout_in_minutes = 5
}

#defining scaling policies
resource "aws_autoscaling_policy" "myap1" {
  name = "myapolicy-scaleup"
  adjustment_type = "ChangeInCapacity"
  scaling_adjustment = 1
  cooldown = 300
  autoscaling_group_name = aws_autoscaling_group.myag.name
}

#creating cloudwatch to monitor cpu utilization and scale in/out resources using auto scalling group 
resource "aws_cloudwatch_metric_alarm" "scaleoutalarm" {
  alarm_name = "ScaleOutAlarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods = 1
  metric_name = "CPUUtilization"
  namespace = "AWS/EC2"
  period = 300
  statistic = "Average"
  threshold = 60
  alarm_description = "Scale out if CPU utilization is high"
  alarm_actions = [aws_autoscaling_policy.myap1.arn,aws_sns_topic.mysns.arn]
  dimensions = {
    autoscaling_group_name = aws_autoscaling_group.myag.name
  }
  insufficient_data_actions = []
  ok_actions = []
}

resource "aws_autoscaling_policy" "myap2" {
  name = "myapolicy-scaledown"
  adjustment_type = "ChangeInCapacity"
  scaling_adjustment = -1
  cooldown = 300
  autoscaling_group_name = aws_autoscaling_group.myag.name
}

resource "aws_cloudwatch_metric_alarm" "scaleinalarm" {
  alarm_name = "ScaleInAlarm"
  comparison_operator = "LessThanThreshold"
  evaluation_periods = 1
  metric_name = "CPUUtilization"
  namespace = "AWS/EC2"
  period = 300
  statistic = "Average"
  threshold = 20
  alarm_description = "Scale in if CPU utilization is low"
  alarm_actions = [aws_autoscaling_policy.myap2.arn,aws_sns_topic.mysns.arn]
  dimensions = {
    autoscaling_group_name = aws_autoscaling_group.myag.name
  }
  insufficient_data_actions = []
  ok_actions = []
}
