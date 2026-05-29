# ─────────────────────────────────────────────────────────────────────────────
# Cost Anomaly Triage (Bedrock edition) デプロイスクリプト (PowerShell 版)
# 前提: aws cli / sam cli がインストール済みで、適切な IAM 権限があること
#       Bedrock で Claude Haiku 4.5 のモデルアクセスが有効化されていること
# ─────────────────────────────────────────────────────────────────────────────
# Windows PowerShell 5.1 では Stop にすると AWS CLI が stderr に書いた瞬間
# NativeCommandError で停止してしまうため Continue を採用し、
# 重要な箇所では $LASTEXITCODE を見て明示的に throw する。
$ErrorActionPreference = "Continue"

$StackName     = "cost-anomaly-triage"
$Region        = "us-east-1"   # ← 変更不可。CAD の EventBridge は us-east-1 のみ
$Env           = "dev"
$SlackSsmPath  = "/cost-anomaly-triage/slack-webhook-url"
$TeamsSsmPath  = "/cost-anomaly-triage/teams-webhook-url"

$AccountId    = (aws sts get-caller-identity --query Account --output text)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($AccountId)) {
    throw "AWS CLI の認証情報を取得できません。aws configure を確認してください。"
}
$DeployBucket = "$StackName-deploy-$AccountId"

Write-Host "=============================================="
Write-Host "  Cost Anomaly Triage (Bedrock edition)"
Write-Host "  Stack  : $StackName"
Write-Host "  Region : $Region"
Write-Host "  Account: $AccountId"
Write-Host "=============================================="

# ── S3 バケット確認 ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "📦 デプロイ用 S3 バケット確認..."
aws s3api head-bucket --bucket $DeployBucket 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "   既存バケットを使用: $DeployBucket"
} else {
    aws s3 mb "s3://$DeployBucket" --region $Region
    Write-Host "   バケット作成完了: $DeployBucket"
}

# ── SSM パラメーター登録ヘルパー ──────────────────────────────────────────────
function Register-SsmParameter {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][ValidateSet("required", "optional")][string]$Required
    )

    $existing = aws ssm get-parameter --name $Name --region $Region `
        --query 'Parameter.Value' --output text 2>$null
    if ($LASTEXITCODE -ne 0) { $existing = "" }

    if (-not [string]::IsNullOrEmpty($existing)) {
        Write-Host "   SSM パラメーター既存: $Name"
        Write-Host "   （更新する場合は y、スキップは Enter）"
        $update = Read-Host
        if ($update -eq "y") {
            $value = Read-Host "   新しい $Label を入力"
            if ([string]::IsNullOrWhiteSpace($value)) {
                Write-Host "   空入力のためスキップ: $Name"
                return
            }
            aws ssm put-parameter `
                --name $Name `
                --value $value `
                --type SecureString `
                --overwrite `
                --region $Region | Out-Null
            Write-Host "   更新完了: $Name"
        }
    } else {
        if ($Required -eq "optional") {
            $value = Read-Host "   $Label を入力（スキップする場合は Enter）"
            if ([string]::IsNullOrWhiteSpace($value)) {
                Write-Host "   スキップ: $Name"
                return
            }
        } else {
            $value = Read-Host "   $Label を入力"
            if ([string]::IsNullOrWhiteSpace($value)) {
                throw "$Label が入力されていません。処理を中断します。"
            }
        }
        aws ssm put-parameter `
            --name $Name `
            --value $value `
            --type SecureString `
            --region $Region | Out-Null
        Write-Host "   SSM パラメーター登録完了: $Name"
    }
}

Write-Host ""
Write-Host "🔔 Slack Webhook URL の設定"
Register-SsmParameter -Name $SlackSsmPath -Label "Slack Incoming Webhook URL" -Required "required"

Write-Host ""
Write-Host "💬 Teams Webhook URL の設定（任意）"
Register-SsmParameter -Name $TeamsSsmPath -Label "Teams Incoming Webhook URL" -Required "optional"

# Teams SSM が存在するか確認してデプロイパラメーターを決定
$teamsSsmExists = aws ssm get-parameter --name $TeamsSsmPath --region $Region `
    --query 'Parameter.Name' --output text 2>$null
if ($LASTEXITCODE -ne 0) { $teamsSsmExists = "" }

if (-not [string]::IsNullOrEmpty($teamsSsmExists)) {
    $TeamsParam = $TeamsSsmPath
} else {
    $TeamsParam = ""
}

# ── Bedrock モデルアクセス確認 ────────────────────────────────────────────────
Write-Host ""
Write-Host "🤖 Bedrock モデルアクセス確認..."
$modelAccess = aws bedrock get-foundation-model `
    --model-identifier "anthropic.claude-haiku-4-5-20251001-v1:0" `
    --region $Region `
    --query 'modelDetails.modelLifecycle.status' `
    --output text 2>$null
if ($LASTEXITCODE -ne 0) { $modelAccess = "ERROR" }

if ($modelAccess -eq "ERROR") {
    Write-Host "   ⚠️  モデルアクセスの確認に失敗しました。"
    Write-Host "   AWS コンソール → Bedrock → Model access で"
    Write-Host "   Claude Haiku 4.5 を有効化してください。"
    Write-Host "   https://us-east-1.console.aws.amazon.com/bedrock/home?region=us-east-1#/modelaccess"
    exit 1
}
Write-Host "   Claude Haiku 4.5: $modelAccess"

# ── SAM ビルド & デプロイ ──────────────────────────────────────────────────
Write-Host ""
Write-Host "🔨 SAM build..."
sam build
if ($LASTEXITCODE -ne 0) { throw "sam build に失敗しました" }

Write-Host ""
Write-Host "🚀 SAM deploy..."
sam deploy `
    --stack-name $StackName `
    --s3-bucket  $DeployBucket `
    --region     $Region `
    --capabilities CAPABILITY_IAM `
    --no-confirm-changeset `
    --parameter-overrides `
        "SlackWebhookSsmPath=$SlackSsmPath" `
        "TeamsWebhookSsmPath=$TeamsParam" `
        "Env=$Env"
if ($LASTEXITCODE -ne 0) { throw "sam deploy に失敗しました" }

# ── 完了 ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=============================================="
Write-Host "✅ デプロイ完了！"
Write-Host ""
Write-Host "動作確認（サンプルイベントで Lambda を直接実行）:"
$FunctionName = aws cloudformation describe-stacks `
    --stack-name $StackName `
    --region $Region `
    --query "Stacks[0].Outputs[?OutputKey=='FunctionName'].OutputValue" `
    --output text
Write-Host ""
Write-Host "  aws lambda invoke ``"
Write-Host "    --function-name $FunctionName ``"
Write-Host "    --payload file://tests/sample_event.json ``"
Write-Host "    --cli-binary-format raw-in-base64-out ``"
Write-Host "    --region $Region ``"
Write-Host "    output.json ; Get-Content output.json"
Write-Host "=============================================="
