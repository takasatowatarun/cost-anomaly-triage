"""
Cost Anomaly Detection 自動トリアージ
EventBridge → Lambda → Cost Explorer + Bedrock (Claude Haiku 4.5) → Slack / Teams
"""

import json
import os
import boto3
import urllib3
from datetime import datetime, timedelta

http = urllib3.PoolManager()
bedrock_client = boto3.client("bedrock-runtime", region_name="us-east-1")
ce_client      = boto3.client("ce",              region_name="us-east-1")
ssm_client     = boto3.client("ssm")

MODEL_ID = "us.anthropic.claude-haiku-4-5-20251001-v1:0"

# プロンプトテンプレートをモジュールロード時に読み込む（Lambda の再利用で効率化）
_PROMPT_TEMPLATE = open(
    os.path.join(os.path.dirname(__file__), "prompts", "triage.txt"),
    encoding="utf-8",
).read()


def lambda_handler(event, context):
    print(json.dumps(event))

    # Slack Webhook URL（必須）
    slack_webhook_url = ssm_client.get_parameter(
        Name=os.environ["SLACK_WEBHOOK_SSM_PATH"],
        WithDecryption=True,
    )["Parameter"]["Value"]

    # Teams Webhook URL（任意・未設定の場合はスキップ）
    teams_webhook_url = None
    teams_ssm_path = os.environ.get("TEAMS_WEBHOOK_SSM_PATH", "")
    if teams_ssm_path:
        try:
            teams_webhook_url = ssm_client.get_parameter(
                Name=teams_ssm_path,
                WithDecryption=True,
            )["Parameter"]["Value"]
        except Exception as e:
            print(f"Teams Webhook URL の取得をスキップ: {e}")

    # EventBridge から直接受信
    detail = event.get("detail", {})
    anomaly = _parse_anomaly(detail)
    daily_costs = _get_cost_trend(anomaly["account_id"], anomaly["service"])
    result = _analyze_with_bedrock(anomaly, daily_costs)

    _post_to_slack(anomaly, result, slack_webhook_url)

    if teams_webhook_url:
        _post_to_teams(anomaly, result, teams_webhook_url)

    return {"statusCode": 200, "body": json.dumps(result, ensure_ascii=False)}


def _parse_anomaly(detail: dict) -> dict:
    root_cause = (detail.get("rootCauses") or [{}])[0]
    impact = detail.get("impact", {})
    return {
        "account_id":   detail.get("accountId") or root_cause.get("linkedAccount", "Unknown"),
        "service":      root_cause.get("service", "Unknown"),
        "usage_type":   root_cause.get("usageType", "Unknown"),
        "region":       root_cause.get("region", "Unknown"),
        "total_impact": float(impact.get("totalImpact", 0)),
        "anomaly_id":   detail.get("anomalyId", ""),
        "details_link": detail.get("anomalyDetailsLink", ""),
    }


def _get_cost_trend(account_id: str, service: str) -> list[dict]:
    end_date   = datetime.now().strftime("%Y-%m-%d")
    start_date = (datetime.now() - timedelta(days=14)).strftime("%Y-%m-%d")

    try:
        resp = ce_client.get_cost_and_usage(
            TimePeriod={"Start": start_date, "End": end_date},
            Granularity="DAILY",
            Filter={
                "And": [
                    {"Dimensions": {"Key": "LINKED_ACCOUNT", "Values": [account_id]}},
                    {"Dimensions": {"Key": "SERVICE",         "Values": [service]}},
                ]
            },
            Metrics=["UnblendedCost"],
        )
        return [
            {
                "date": r["TimePeriod"]["Start"],
                "cost": round(float(r["Total"]["UnblendedCost"]["Amount"]), 2),
            }
            for r in resp["ResultsByTime"]
        ]
    except Exception as e:
        print(f"Cost Explorer error: {e}")
        return []


def _analyze_with_bedrock(anomaly: dict, daily_costs: list) -> dict:
    # str.format だとプロンプト中の JSON サンプルの { } が変数扱いになるため replace で差し込む
    prompt = (
        _PROMPT_TEMPLATE
        .replace("{account_id}",   anomaly["account_id"])
        .replace("{service}",      anomaly["service"])
        .replace("{usage_type}",   anomaly["usage_type"])
        .replace("{region}",       anomaly["region"])
        .replace("{total_impact}", f"{anomaly['total_impact']:.2f}")
        .replace("{daily_costs}",  json.dumps(daily_costs, ensure_ascii=False))
    )

    resp = bedrock_client.converse(
        modelId=MODEL_ID,
        messages=[{"role": "user", "content": [{"text": prompt}]}],
        inferenceConfig={"maxTokens": 512},
    )

    result_text = resp["output"]["message"]["content"][0]["text"]

    # Claude がコードブロック(```json ... ```)で包んで返す場合があるので剥がす
    stripped = result_text.strip()
    if stripped.startswith("```"):
        lines = stripped.splitlines()
        inner = "\n".join(lines[1:-1]) if lines[-1].strip() == "```" else "\n".join(lines[1:])
        stripped = inner.strip()

    try:
        return json.loads(stripped)
    except Exception:
        return {
            "verdict":     "要確認",
            "reason":      result_text,
            "resolution":  "手動確認が必要です",
            "next_action": "マネジメントコンソールで確認してください",
            "confidence":  "low",
        }


def _post_to_slack(anomaly: dict, result: dict, webhook_url: str) -> None:
    verdict    = result.get("verdict", "不明")
    emoji      = "✅" if verdict == "静観" else "🚨"
    conf_label = {"high": "高 🟢", "medium": "中 🟡", "low": "低 🔴"}.get(
        result.get("confidence", ""), "不明"
    )
    details_link = anomaly.get("details_link", "")
    link_line = f"🔗 <{details_link}|Cost Anomaly Detection で詳細を確認>\n" if details_link else ""

    # ワークフロービルダー用: body / title / account の3変数
    payload = {
        "title": f"{emoji} Cost Anomaly 自動調査結果 - 判定: {verdict}（信頼度: {conf_label}）",
        "account": f"{anomaly['account_id']} / {anomaly['service']} / {anomaly['usage_type']} / ${anomaly['total_impact']:.2f}",
        "body": (
            f"【原因推定】{result.get('reason', '')}\n"
            f"【収束見込み】{result.get('resolution', '')}\n"
            f"【ネクストアクション】{result.get('next_action', '')}\n"
            f"{link_line}"
            f"⚠️ この結果は自動生成です。最終判断は担当者が行ってください。"
        ),
    }

    http.request(
        "POST",
        webhook_url,
        headers={"Content-Type": "application/json"},
        body=json.dumps(payload).encode(),
    )


def _post_to_teams(anomaly: dict, result: dict, webhook_url: str) -> None:
    verdict    = result.get("verdict", "不明")
    emoji      = "✅" if verdict == "静観" else "🚨"
    conf_label = {"high": "高 🟢", "medium": "中 🟡", "low": "低 🔴"}.get(
        result.get("confidence", ""), "不明"
    )
    details_link = anomaly.get("details_link", "")

    payload = {
        "type": "message",
        "attachments": [
            {
                "contentType": "application/vnd.microsoft.card.adaptive",
                "content": {
                    "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                    "type": "AdaptiveCard",
                    "version": "1.4",
                    "body": [
                        {
                            "type": "TextBlock",
                            "text": f"{emoji} Cost Anomaly 自動調査結果",
                            "weight": "Bolder",
                            "size": "Large",
                        },
                        {
                            "type": "FactSet",
                            "facts": [
                                {"title": "判定", "value": f"{verdict}（信頼度: {conf_label}）"},
                                {"title": "アカウント", "value": anomaly["account_id"]},
                                {"title": "サービス", "value": anomaly["service"]},
                                {"title": "Usage Type", "value": anomaly["usage_type"]},
                                {"title": "インパクト", "value": f"${anomaly['total_impact']:.2f}"},
                            ],
                        },
                        {"type": "TextBlock", "text": "---", "separator": True},
                        {"type": "TextBlock", "text": f"**原因推定**\n{result.get('reason', '')}", "wrap": True},
                        {"type": "TextBlock", "text": f"**収束見込み**\n{result.get('resolution', '')}", "wrap": True},
                        {"type": "TextBlock", "text": f"**ネクストアクション**\n{result.get('next_action', '')}", "wrap": True},
                        {
                            "type": "TextBlock",
                            "text": "⚠️ この結果は自動生成です。最終判断は担当者が行ってください。",
                            "isSubtle": True,
                            "wrap": True,
                        },
                    ],
                    "actions": (
                        [{"type": "Action.OpenUrl", "title": "詳細を確認", "url": details_link}]
                        if details_link else []
                    ),
                },
            }
        ],
    }

    http.request(
        "POST",
        webhook_url,
        headers={"Content-Type": "application/json"},
        body=json.dumps(payload).encode(),
    )
