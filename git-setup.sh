#!/bin/bash

echo "=========================================="
echo "Git Repository Setup"
echo "=========================================="

# Initialize git
git init
git add .
git commit -m "Initial commit: BLAST storage performance benchmark infrastructure"

# Add remote
git remote add origin https://github.com/hmkim/aws-blast-performance.git

# Create main branch and push
git branch -M main
git push -u origin main

echo ""
echo "✓ Repository setup complete!"
echo ""
echo "Next steps:"
echo "1. Visit: https://github.com/hmkim/aws-blast-performance"
echo "2. Add description: AWS infrastructure for comparing BLAST performance across EFS, FSx for Lustre, and S3 storage"
echo "3. Add topics: aws, blast, bioinformatics, genomics, cloudformation, efs, lustre, s3, aws-batch"
