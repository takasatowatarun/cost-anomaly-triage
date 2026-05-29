# ─────────────────────────────────────────────────────────────────────────────
# Cost Anomaly Triage (Bedrock edition) 削除スクリプト (PowerShell 版)
# 削除対象:
#   - CloudFormation スタック（Lambda / EventBridge / SQS / IAM ロール）
#   - SSM Parameter Store（Slack / Teams Webhook URL）
#   - デプロイ用 S3 バケット（空にしてから削除）
# ─────────────────────────────────────────────────────────────────────────────
$ErrorActionPreference = "Stop"

$StackName    = "cost-anomaly-triage"
$Region       = "us-east-1"
$SlackSsmPath = "/cost-anomaly-triage/slack-webhook-url"
$TeamsSsmPath = "/cost-anomaly-triage/teams-webhook-url"

$AccountId    = (aws sts get-caller-identity --query Account --output text)
$DeployBucket = "$StackName-deploy-$AccountId"

Write-Host "=============================================="
Write-Host "  Cost Anomaly Triage 削除"
Write-Host "  Stack  : $StackName"
Write-Host "  Region : $Region"
Write-Host "  Account: $AccountId"
Write-Host "=============================================="
Write-Host ""
Write-Host "⚠️  以下のリソースを削除します："
Write-Host "   - CloudFormation スタック: $StackName"
Write-Host "   - SSM パラメーター: $SlackSsmPath"
Write-Host "   - SSM パラメーター: $TeamsSsmPath（存在する場合）"
Write-Host "   - S3 バケット: $DeployBucket（存在する場合）"
Write-Host ""
Write-Host "続行しますか？ (yes / それ以外でキャンセル)"
$confirm = Read-Host
if ($confirm -ne "yes") {
    Write-Host "キャンセルしました。"
    exit 0
}

# ── CloudFormation スタック削除 ───────────────────────────────────────────────
Write-Host ""
Write-Host "🗑️  CloudFormation スタック削除中..."
aws cloudformation describe-stacks `
    --stack-name $StackName `
    --region $Region 1>$null 2>$null
if ($LASTEXITCODE -eq 0) {
    aws cloudformation delete-stack `
        --stack-name $StackName `
        --region $Region
    Write-Host "   削除リクエスト送信。完了を待機中..."
    aws cloudformation wait stack-delete-complete `
        --stack-name $StackName `
        --region $Region
    Write-Host "   ✅ スタック削除完了"
} else {
    Write-Host "   スタックが存在しないためスキップ"
}

# ── SSM パラメーター削除 ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "🗑️  SSM パラメーター削除中..."
foreach ($ssmPath in @($SlackSsmPath, $TeamsSsmPath)) {
    aws ssm get-parameter --name $ssmPath --region $Region 1>$null 2>$null
    if ($LASTEXITCODE -eq 0) {
        aws ssm delete-parameter `
            --name $ssmPath `
            --region $Region
        Write-Host "   ✅ 削除完了: $ssmPath"
    } else {
        Write-Host "   存在しないためスキップ: $ssmPath"
    }
}

# ── デプロイ用 S3 バケット削除 ────────────────────────────────────────────────
Write-Host ""
Write-Host "🗑️  デプロイ用 S3 バケット削除中..."
aws s3api head-bucket --bucket $DeployBucket 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "   バケット内オブジェクトを削除中: $DeployBucket"
    aws s3 rm "s3://$DeployBucket" --recursive --region $Region
    aws s3 rb "s3://$DeployBucket" --region $Region
    Write-Host "   ✅ バケット削除完了: $DeployBucket"
} else {
    Write-Host "   バケットが存在しないためスキップ: $DeployBucket"
}

Write-Host ""
Write-Host "=============================================="
Write-Host "✅ 削除完了！"
Write-Host "=============================================="
