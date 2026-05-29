#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Cost Anomaly Triage (Bedrock edition) 削除スクリプト
# 削除対象:
#   - CloudFormation スタック（Lambda / EventBridge / SQS / IAM ロール）
#   - SSM Parameter Store（Slack / Teams Webhook URL）
#   - デプロイ用 S3 バケット（空にしてから削除）
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

STACK_NAME="cost-anomaly-triage"
REGION="us-east-1"
SLACK_SSM_PATH="/cost-anomaly-triage/slack-webhook-url"
TEAMS_SSM_PATH="/cost-anomaly-triage/teams-webhook-url"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
DEPLOY_BUCKET="${STACK_NAME}-deploy-${ACCOUNT_ID}"

echo "=============================================="
echo "  Cost Anomaly Triage 削除"
echo "  Stack  : ${STACK_NAME}"
echo "  Region : ${REGION}"
echo "  Account: ${ACCOUNT_ID}"
echo "=============================================="
echo ""
echo "⚠️  以下のリソースを削除します："
echo "   - CloudFormation スタック: ${STACK_NAME}"
echo "   - SSM パラメーター: ${SLACK_SSM_PATH}"
echo "   - SSM パラメーター: ${TEAMS_SSM_PATH}（存在する場合）"
echo "   - S3 バケット: ${DEPLOY_BUCKET}（存在する場合）"
echo ""
echo "続行しますか？ (yes / それ以外でキャンセル)"
read -r CONFIRM
if [ "${CONFIRM}" != "yes" ]; then
    echo "キャンセルしました。"
    exit 0
fi

# ── CloudFormation スタック削除 ───────────────────────────────────────────────
echo ""
echo "🗑️  CloudFormation スタック削除中..."
if aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" > /dev/null 2>&1; then
    aws cloudformation delete-stack \
        --stack-name "${STACK_NAME}" \
        --region "${REGION}"
    echo "   削除リクエスト送信。完了を待機中..."
    aws cloudformation wait stack-delete-complete \
        --stack-name "${STACK_NAME}" \
        --region "${REGION}"
    echo "   ✅ スタック削除完了"
else
    echo "   スタックが存在しないためスキップ"
fi

# ── SSM パラメーター削除 ──────────────────────────────────────────────────────
echo ""
echo "🗑️  SSM パラメーター削除中..."
for SSM_PATH in "${SLACK_SSM_PATH}" "${TEAMS_SSM_PATH}"; do
    if aws ssm get-parameter --name "${SSM_PATH}" --region "${REGION}" > /dev/null 2>&1; then
        aws ssm delete-parameter \
            --name "${SSM_PATH}" \
            --region "${REGION}"
        echo "   ✅ 削除完了: ${SSM_PATH}"
    else
        echo "   存在しないためスキップ: ${SSM_PATH}"
    fi
done

# ── デプロイ用 S3 バケット削除 ────────────────────────────────────────────────
echo ""
echo "🗑️  デプロイ用 S3 バケット削除中..."
if aws s3api head-bucket --bucket "${DEPLOY_BUCKET}" 2>/dev/null; then
    echo "   バケット内オブジェクトを削除中: ${DEPLOY_BUCKET}"
    aws s3 rm "s3://${DEPLOY_BUCKET}" --recursive --region "${REGION}"
    aws s3 rb "s3://${DEPLOY_BUCKET}" --region "${REGION}"
    echo "   ✅ バケット削除完了: ${DEPLOY_BUCKET}"
else
    echo "   バケットが存在しないためスキップ: ${DEPLOY_BUCKET}"
fi

echo ""
echo "=============================================="
echo "✅ 削除完了！"
echo "=============================================="
