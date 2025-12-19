# hl-component-ses

A CfHighlander component for AWS Simple Email Service (SES) that configures outbound email sending with domain identity verification, configuration sets, and event tracking.

## Features

- Domain identity verification with DKIM signing
- Mail-from domain configuration for SPF alignment
- Configuration set with reputation metrics and TLS enforcement
- Event destinations for tracking (SNS, CloudWatch, Kinesis Firehose, EventBridge)
- Optional Route53 DNS record automation (DKIM, SPF, DMARC)

## Parameters

| Name | Use | Default | Global | Type |
| ---- | --- | ------- | ------ | ---- |
| EnvironmentName | Tagging | dev | true | String |
| EnvironmentType | Tagging | development | true | String |
| DnsDomain | Domain to verify for email sending | None | true | String |
| HostedZoneId | Route53 Zone ID (required if manage_dns_records: true) | None | false | String |

## Outputs/Exports

| Name | Value | Exported |
| ---- | ----- | -------- |
| EmailIdentityArn | ARN of the verified email identity | true |
| ConfigurationSetName | Name of the configuration set | true |
| DkimDNSTokenName1-3 | DKIM token names for manual DNS setup | false |
| DkimDNSTokenValue1-3 | DKIM token values for manual DNS setup | false |

## Configuration

### Default Configuration

```yaml
# Domain identity settings
domain: ${DnsDomain}
dkim_signing_key_length: 2048
mail_from_subdomain: mail

# Route53 DNS management (optional)
manage_dns_records: false

# Configuration set defaults
configuration_set:
  enabled: true
  reputation_metrics: true
  sending_enabled: true
  tls_policy: REQUIRE
  suppression:
    reasons:
      - BOUNCE
      - COMPLAINT

# Event destinations (empty by default)
event_destinations: []
```

### Configuration Options

#### Domain Identity

| Key | Description | Default |
| --- | ----------- | ------- |
| domain | Domain to verify (supports CloudFormation substitution) | ${DnsDomain} |
| dkim_signing_key_length | DKIM key length (1024 or 2048) | 2048 |
| mail_from_subdomain | Subdomain for mail-from address | mail |

#### Route53 DNS Management

| Key | Description | Default |
| --- | ----------- | ------- |
| manage_dns_records | Enable automatic DNS record creation | false |
| dmarc.policy | DMARC policy (none, quarantine, reject) | none |
| dmarc.rua | Aggregate report email address | "" |
| dmarc.ruf | Forensic report email address | "" |
| dmarc.pct | Percentage of messages to apply policy | 100 |

When `manage_dns_records` is enabled, the component creates:
- 3 DKIM CNAME records
- Mail-from MX record
- Mail-from SPF TXT record
- DMARC TXT record

#### Configuration Set

| Key | Description | Default |
| --- | ----------- | ------- |
| configuration_set.enabled | Enable configuration set | true |
| configuration_set.name | Custom name (auto-generated if not set) | ${EnvironmentName}-ses-config |
| configuration_set.reputation_metrics | Enable reputation metrics | true |
| configuration_set.sending_enabled | Enable sending | true |
| configuration_set.tls_policy | TLS policy (REQUIRE or OPTIONAL) | REQUIRE |
| configuration_set.suppression.reasons | Suppression list reasons | [BOUNCE, COMPLAINT] |

#### Event Destinations

Event destinations allow you to track email metrics. Supported types:

**SNS Destination**
```yaml
event_destinations:
  - name: bounces-to-sns
    enabled: true
    type: sns
    topic_arn: arn:aws:sns:us-east-1:123456789012:ses-bounces
    events:
      - BOUNCE
      - COMPLAINT
```

**CloudWatch Destination**
```yaml
event_destinations:
  - name: metrics-to-cloudwatch
    enabled: true
    type: cloudwatch
    events:
      - SEND
      - DELIVERY
      - BOUNCE
      - COMPLAINT
    dimensions:
      - name: ses:configuration-set
        source: messageTag
        default_value: default
```

**Kinesis Firehose Destination**
```yaml
event_destinations:
  - name: events-to-firehose
    enabled: true
    type: kinesis_firehose
    delivery_stream_arn: arn:aws:firehose:us-east-1:123456789012:deliverystream/ses-events
    iam_role_arn: arn:aws:iam::123456789012:role/ses-firehose-role
    events:
      - SEND
      - DELIVERY
      - BOUNCE
      - COMPLAINT
      - REJECT
      - OPEN
      - CLICK
```

**EventBridge Destination**
```yaml
event_destinations:
  - name: events-to-eventbridge
    enabled: true
    type: eventbridge
    event_bus_arn: arn:aws:events:us-east-1:123456789012:event-bus/default
    events:
      - BOUNCE
      - COMPLAINT
```

**Available Event Types:**
- SEND
- DELIVERY
- BOUNCE
- COMPLAINT
- REJECT
- OPEN
- CLICK
- RENDERING_FAILURE
- DELIVERY_DELAY
- SUBSCRIPTION

## Example Usage

### Highlander Template

#### Basic Usage
```ruby
CfhighlanderTemplate do
  Component name: 'ses', template: 'ses' do
    parameter name: 'DnsDomain', value: 'example.com'
  end
end
```

#### With Route53 DNS Automation
```ruby
CfhighlanderTemplate do
  Component name: 'ses', template: 'ses' do
    parameter name: 'DnsDomain', value: 'example.com'
    parameter name: 'HostedZoneId', value: 'Z1234567890ABC'
  end
end
```

### Configuration File

#### ses.config.yaml (with Route53 and SNS notifications)
```yaml
domain: ${DnsDomain}
dkim_signing_key_length: 2048
mail_from_subdomain: mail

manage_dns_records: true

dmarc:
  policy: quarantine
  rua: dmarc-reports@example.com
  pct: 100

configuration_set:
  enabled: true
  name: ${EnvironmentName}-email-config
  reputation_metrics: true
  sending_enabled: true
  tls_policy: REQUIRE

event_destinations:
  - name: bounce-notifications
    enabled: true
    type: sns
    topic_arn:
      Fn::Sub: arn:aws:sns:${AWS::Region}:${AWS::AccountId}:ses-bounces
    events:
      - BOUNCE
      - COMPLAINT
```

## Manual DNS Configuration

If `manage_dns_records` is set to `false`, you will need to configure DNS manually. After deploying the stack, retrieve the DKIM tokens from the CloudFormation outputs:

1. **DKIM Records**: Create 3 CNAME records using the output values:
   - `DkimDNSTokenName1` → `DkimDNSTokenValue1`
   - `DkimDNSTokenName2` → `DkimDNSTokenValue2`
   - `DkimDNSTokenName3` → `DkimDNSTokenValue3`

2. **Mail-From MX Record**:
   ```
   mail.yourdomain.com. MX 10 feedback-smtp.<region>.amazonses.com
   ```

3. **Mail-From SPF Record**:
   ```
   mail.yourdomain.com. TXT "v=spf1 include:amazonses.com ~all"
   ```

4. **DMARC Record** (recommended):
   ```
   _dmarc.yourdomain.com. TXT "v=DMARC1; p=none; pct=100"
   ```

## Testing

Run the component tests:

```bash
cfhighlander cftest ses
```

Run a specific test:

```bash
cfhighlander cftest ses -t tests/route53.test.yaml
```

## CfHighlander Setup

Install cfhighlander gem:

```bash
gem install cfhighlander
```

Or via Docker:

```bash
docker pull theonestack/cfhighlander
```

## License

MIT
