# Example PRD: Add Webhook Support

## Goal
Add a webhook endpoint that receives Slack events and stores them in the vault.

## Requirements
- POST /webhook/slack receives Slack event payloads
- Validate the request signature using SLACK_SIGNING_SECRET
- Store each event as a markdown file in vault/_webhooks/YYYY-MM-DD/
- Log all received events to logs/webhook.log

## Constraints
- Use only the standard library (no Express, no frameworks)
- Must handle Slack's URL verification challenge
- Files must be Obsidian-compatible markdown

## Out of Scope
- Responding to Slack events (read-only capture)
- Authentication beyond Slack signature verification
- Database storage
