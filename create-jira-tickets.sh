#!/bin/bash
today=$(date -u +'%Y-%m-%d')

JIRA_API_URL="https://patriotsoftware.atlassian.net/rest/api/2/issue"

highest_sla=15
high_sla=30
medium_sla=60
low_sla=90

echo "Today: $today"

jq '.' alerts.json >> todays_alerts.json

todays_alert_count=$(jq '. | length' todays_alerts.json)
echo "Found $todays_alert_count vulnerabilities from today."


if [ "$todays_alert_count" -eq "0" ]; then
          jq -c 'group_by(.security_advisory.severity) | map({severity: .[0].security_advisory.severity, alerts: .})' todays_alerts.json > grouped_alerts.json
          
          grouped_alert_count=$(jq '. | length' grouped_alerts.json)
          echo "Found $grouped_alert_count severity grouping(s) from today."
          
          severities=$(jq -r 'map(.severity) | join(", ")' grouped_alerts.json)
          echo "Today's severities: $severities."
fi


# Iterate through each group and create a Jira ticket
jq -c '.[]' grouped_alerts.json | while read -r group; do
severity=$(echo "$group" | jq -r '.severity' | tr '[:lower:]' '[:upper:]')
severity_alerts=$(echo "$group" | jq -c '.alerts')
priority="None"
sla_days=0

case "$severity" in
    "CRITICAL")
    priority="Highest"
    sla_days=$highest_sla
    ;;
    "HIGH")
    priority="High"
    sla_days=$high_sla
    ;;
    "MEDIUM")
    priority="Medium"
    sla_days=$medium_sla
    ;;
    "LOW")
    priority="Low"
    sla_days=$low_sla
    ;;
    *)
    echo "UNKNOWN STATUS"
    ;;
esac

sla_due_date=$(date -d "$today +$sla_days days" "+%Y-%m-%d")
repo_name=$(echo "${{ github.repository }}" | cut -d'/' -f2)

# Prepare a summary and description for the Jira ticket
summary="Dependabot $today for $repo_name: $severity Vulnerabilities"
description="\n*Repository*: [$repo_name|https://github.com/${{ github.repository}}/security/dependabot?q=is:open+severity:$severity+sort:newest]\n *Created Date*: $today\n *Severity*: $severity\n *SLA Days*: $sla_days \n *Due Date*: $sla_due_date\n\n----\n"

echo "Processing Dependabot vulnerability grouping..."
echo "Repository: $repo_name"
echo "Severity: $severity"
echo "Priority: $priority"
echo "SLA Days: $sla_days"
echo "SLA Due Date: $sla_due_date"

# Read all alerts into an array
mapfile -t alerts < <(echo "$severity_alerts" | jq -c '.[]')

# Process the array
for i in "${!alerts[@]}"; do
    alert="${alerts[$i]}"
    title=$(echo "$alert" | jq -r '.security_advisory.summary')
    package=$(echo "$alert" | jq -r '.dependency.package.name')
    url=$(echo "$alert" | jq -r '.html_url')

    description+="*Package*: $package\n    *Title*: $title\n    *Details*: $url\n\n "
done

# Use jq to build the JSON object
issue_payload=$(jq -n --arg summary "$summary" --arg description "$description" --arg priority "$priority" --arg duedate "$sla_due_date" '{
    "fields": {
    "project": { "key": "${{ env.JIRA_PROJECT_KEY }}" },
    "summary": $summary, 
    "description": $description,
    "priority": { "name": $priority },
    "duedate": $duedate,
    "issuetype": { "name": "Story" }
    }
}' | jq -r '.')

echo "Creating Jira ticket for $severity vulnerabilities..."

# Fix issues with double escaping the details
issue_payload=$(echo "$issue_payload" | sed 's/\\\\n/\\n/g') 

echo "$issue_payload"

# Create the Jira issue using the Jira REST API
curl -X POST "$JIRA_API_URL" \
    -u "${{ env.JIRA_USER_EMAIL }}:${{ env.JIRA_API_TOKEN }}" \
    -H "Content-Type: application/json" \
    -d "$issue_payload"
done
