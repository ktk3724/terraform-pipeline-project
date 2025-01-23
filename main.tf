# S3 버킷 (아티팩트 저장소)
resource "aws_s3_bucket" "artifact_store" {
  bucket = "${var.project_name}-artifacts-${var.environment}"
}

# S3 버킷 버전 관리 활성화
resource "aws_s3_bucket_versioning" "artifact_store_versioning" {
  bucket = aws_s3_bucket.artifact_store.id
  versioning_configuration {
    status = "Enabled"
  }
}

# S3 버킷 보안 설정
resource "aws_s3_bucket_public_access_block" "artifact_store" {
  bucket = aws_s3_bucket.artifact_store.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 버킷 암호화 설정
resource "aws_s3_bucket_server_side_encryption_configuration" "artifact_encryption" {
  bucket = aws_s3_bucket.artifact_store.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 배포용 S3 버킷 (정적 웹 호스팅)
resource "aws_s3_bucket" "deploy_bucket" {
  bucket = "${var.project_name}-deploy-${var.environment}"
}

# 배포 버킷 웹 호스팅 활성화
resource "aws_s3_bucket_website_configuration" "deploy_bucket" {
  bucket = aws_s3_bucket.deploy_bucket.id

  index_document {
    suffix = "index.html"
  }
}

# 배포 버킷 퍼블릭 액세스 설정
resource "aws_s3_bucket_public_access_block" "deploy_bucket" {
  bucket = aws_s3_bucket.deploy_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# 배포 버킷 정책
resource "aws_s3_bucket_policy" "deploy_bucket" {
  bucket = aws_s3_bucket.deploy_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.deploy_bucket.arn}/*"
      },
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.deploy_bucket]
}

# GitHub 연결을 위한 CodeStar 연결
resource "aws_codestarconnections_connection" "github" {
  name          = "${var.project_name}-github-connection"
  provider_type = "GitHub"
}

# CodeBuild IAM 역할
resource "aws_iam_role" "codebuild_role" {
  name = "${var.project_name}-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
      }
    ]
  })
}

# CodeBuild IAM 정책
resource "aws_iam_role_policy" "codebuild_policy" {
  name = "${var.project_name}-codebuild-policy"
  role = aws_iam_role.codebuild_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Resource = [
          "${aws_s3_bucket.artifact_store.arn}/*",
          aws_s3_bucket.artifact_store.arn
        ]
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:GetObjectVersion"
        ]
      },
      {
        Effect = "Allow"
        Resource = ["*"]
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
      }
    ]
  })
}

# CodeBuild 프로젝트
resource "aws_codebuild_project" "build_project" {
  name          = "${var.project_name}-build"
  description   = "Build project for ${var.project_name}"
  service_role  = aws_iam_role.codebuild_role.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                      = "aws/codebuild/standard:5.0"
    type                       = "LINUX_CONTAINER"
  }

   source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"  # 경로 수정
  }

}

# CodePipeline IAM 역할
resource "aws_iam_role" "pipeline_role" {
  name = "${var.project_name}-pipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codepipeline.amazonaws.com"
        }
      }
    ]
  })
}

# CodePipeline IAM 정책
resource "aws_iam_role_policy" "pipeline_policy" {
  name = "${var.project_name}-pipeline-policy"
  role = aws_iam_role.pipeline_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetBucketVersioning",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          aws_s3_bucket.artifact_store.arn,
          "${aws_s3_bucket.artifact_store.arn}/*",
          aws_s3_bucket.deploy_bucket.arn,
          "${aws_s3_bucket.deploy_bucket.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "codebuild:BatchGetBuilds",
          "codebuild:StartBuild",
          "codestar-connections:UseConnection"
        ]
        Resource = "*"
      }
    ]
  })
}

# CodePipeline
resource "aws_codepipeline" "pipeline" {
  name     = "${var.project_name}-pipeline"
  role_arn = aws_iam_role.pipeline_role.arn

  artifact_store {
    location = aws_s3_bucket.artifact_store.bucket
    type     = "S3"
  }

  # Source 단계 (GitHub)
  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = aws_codestarconnections_connection.github.arn
        FullRepositoryId = "ktk3724/terraform-pipeline-project"
        BranchName      = "master"
      }
    }
  }

  # Build 단계
  stage {
    name = "Build"
    action {
      name            = "Build"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      input_artifacts = ["source_output"]
      version         = "1"

      configuration = {
        ProjectName = aws_codebuild_project.build_project.name
      }
    }
  }

  # Deploy 단계
  stage {
    name = "Deploy"
    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "S3"
      input_artifacts = ["source_output"]
      version         = "1"

      configuration = {
        BucketName = aws_s3_bucket.deploy_bucket.bucket
        Extract    = "true"
      }
    }
  }
}