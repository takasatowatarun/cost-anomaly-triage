#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Cost Anomaly Triage (Bedrock edition) デプロイスクリプト
# 前提: aws cli / sam cli がインストール済みで、適切な IAM 権限があること
#       Bedrock で Claude Haiku 4.5 のモデルアクセスが有効化されていること
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

STACK_NAME="cost-anomaly-triage"
REGION="us-east-1"   # ← 変更不可。CAD の EventBridge は us-east-1 のみ
ENV="dev"
SLACK_SSM_PATH="/cost-anomaly-triage/slack-webhook-url"
TEAMS_SSM_PATH="/cost-anomaly-triage/teams-webhook-url"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
DEPLOY_BUCKET="${STACK_NAME}-deploy-${ACCOUNT_ID}"

echo "=============================================="
echo "  Cost Anomaly Triage (Bedrock edition)"
echo "  Stack  : ${STACK_NAME}"
echo "  Region : ${REGION}"
echo "  Account: ${ACCOUNT_ID}"
echo "=============================================="

# ── S3 バケット確認 ───────────────────────────────────────────────────────────
echo ""
echo "📦 デプロイ用 S3 バケット確認..."
if aws s3api head-bucket --bucket "${DEPLOY_BUCKET}" 2>/dev/null; then
    echo "   既存バケットを使用: ${DEPLOY_BUCKET}"
else
    aws s3 mb "s3://${DEPLOY_BUCKET}" --region "${REGION}"
    echo "   バケット作成完了: ${DEPLOY_BUCKET}"
fi

# ── SSM: Slack Webhook URL ────────────────────────────────────────────────────
echo ""
_register_ssm() {
    local NAME="$1"
    local LABEL="$2"
    local REQUIRED="$3"   # "required" or "optional"

    EXISTING=$(aws ssm get-parameter --name "${NAME}" --region "${REGION}" \
        --query 'Parameter.Value' --output text 2>/dev/null || echo "")

    if [ -n "${EXISTING}" ]; then
        echo "   SSM パラメーター既存: ${NAME}"
        echo "   （更新する場合は y、スキップは Enter）"
        read -r UPDATE
        if [ "${UPDATE}" = "y" ]; then
            echo "   新しい ${LABEL} を入力してください (入力は非表示):"
            read -rs VALUE
            echo ""
            aws ssm put-parameter \
                --name "${NAME}" \
                --value "${VALUE}" \
                --type SecureString \
                --overwrite \
                --region "${REGION}"
            echo "   更新完了: ${NAME}"
        fi
    else
        if [ "${REQUIRED}" = "optional" ]; then
            echo "   ${LABEL} を入力してください（スキップする場合は Enter）(入力は非表示):"
            read -rs VALUE
            echo ""
            if [ -z "${VALUE}" ]; then
                echo "   スキップ: ${NAME}"
                return
            fi
        else
            echo "   ${LABEL} を入力してください (入力は非表示):"
            read -rs VALUE
            echo ""
        fi
        aws ssm put-parameter \
            --name "${NAME}" \
            --value "${VALUE}" \
            --type SecureString \
            --region "${REGION}"
        echo "   SSM パラメーター登録完了: ${NAME}"
    fi
}

echo "🔔 Slack Webhook URL の設定"
_register_ssm "${SLACK_SSM_PATH}" "Slack Incoming Webhook URL" "required"

echo ""
echo "💬 Teams Webhook URL の設定（任意）"
_register_ssm "${TEAMS_SSM_PATH}" "Teams Incoming Webhook URL" "optional"

# Teams SSM が存在するか確認してデプロイパラメーターを決定
TEAMS_SSM_EXISTS=$(aws ssm get-parameter --name "${TEAMS_SSM_PATH}" --region "${REGION}" \
    --query 'Parameter.Name' --output text 2>/dev/null || echo "")
if [ -n "${TEAMS_SSM_EXISTS}" ]; then
    TEAMS_PARAM="${TEAMS_SSM_PATH}"
else
    TEAMS_PARAM=""
fi

# ── Bedrock モデルアクセス確認 ────────────────────────────────────────────────
echo ""
echo "🤖 Bedrock モデルアクセス確認..."
MODEL_ACCESS=$(aws bedrock get-foundation-model \
    --model-identifier "anthropic.claude-haiku-4-5-20251001-v1:0" \
    --region "${REGION}" \
    --query 'modelDetails.modelLifecycle.status' \
    --output text 2>/dev/null || echo "ERROR")

if [ "${MODEL_ACCESS}" = "ERROR" ]; then
    echo "   ⚠️  モデルアクセスの確認に失敗しました。"
    echo "   AWS コンソール → Bedrock → Model access で"
    echo "   Claude Haiku 4.5 を有効化してください。"
    echo "   https://us-east-1.console.aws.amazon.com/bedrock/home?region=us-east-1#/modelaccess"
    exit 1
fi
echo "   Claude Haiku 4.5: ${MODEL_ACCESS}"

# ── SAM ビルド & デプロイ ──────────────────────────────────────────────────
echo ""
echo "🔨 SAM build..."
sam build

echo ""
echo "🚀 SAM deploy..."
sam deploy \
    --stack-name "${STACK_NAME}" \
    --s3-bucket  "${DEPLOY_BUCKET}" \
    --region     "${REGION}" \
    --capabilities CAPABILITY_IAM \
    --no-confirm-changeset \
    --parameter-overrides \
        SlackWebhookSsmPath="${SLACK_SSM_PATH}" \
        TeamsWebhookSsmPath="${TEAMS_PARAM}" \
        Env="${ENV}"

# ── 完了 ──────────────────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo "✅ デプロイ完了！"
echo ""
echo "動作確認（サンプルイベントで Lambda を直接実行）:"
FUNCTION_NAME=$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='FunctionName'].OutputValue" \
    --output text)
echo ""
echo "  aws lambda invoke \\"
echo "    --function-name ${FUNCTION_NAME} \\"
echo "    --payload file://tests/sample_event.json \\"
echo "    --cli-binary-format raw-in-base64-out \\"
echo "    --region ${REGION} \\"
echo "    /tmp/output.json && cat /tmp/output.json"
echo "=============================================="
