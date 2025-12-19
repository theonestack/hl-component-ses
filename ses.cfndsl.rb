CloudFormation do

  # Default tags for all resources
  default_tags = []
  default_tags << { Key: 'Environment', Value: Ref(:EnvironmentName) }
  default_tags << { Key: 'EnvironmentType', Value: Ref(:EnvironmentType) }

  tags = external_parameters.fetch(:tags, {})
  tags.each do |key, value|
    default_tags << { Key: FnSub(key), Value: FnSub(value) }
  end

  # Configuration values
  domain = external_parameters[:domain]
  dkim_signing_key_length = external_parameters.fetch(:dkim_signing_key_length, 2048)
  mail_from_subdomain = external_parameters.fetch(:mail_from_subdomain, 'mail')
  manage_dns_records = external_parameters.fetch(:manage_dns_records, false)
  configuration_set_config = external_parameters.fetch(:configuration_set, {})
  event_destinations = external_parameters.fetch(:event_destinations, [])

  # ============================================
  # Email Identity (Domain)
  # ============================================
  
  SES_EmailIdentity(:EmailIdentity) do
    EmailIdentity FnSub(domain)
    
    # DKIM configuration - convert numeric key length to CloudFormation enum format
    DkimSigningAttributes({
      NextSigningKeyLength: "RSA_#{dkim_signing_key_length}_BIT"
    })
    
    # DKIM enabled by default
    DkimAttributes({
      SigningEnabled: true
    })
    
    # Mail-from domain configuration for SPF alignment
    MailFromAttributes({
      MailFromDomain: FnSub("#{mail_from_subdomain}.#{domain}"),
      BehaviorOnMxFailure: 'USE_DEFAULT_VALUE'
    })
  end

  # ============================================
  # Configuration Set
  # ============================================
  
  if configuration_set_config.fetch('enabled', true)
    config_set_name = configuration_set_config.fetch('name', nil)
    reputation_metrics = configuration_set_config.fetch('reputation_metrics', true)
    sending_enabled = configuration_set_config.fetch('sending_enabled', true)
    tls_policy = configuration_set_config.fetch('tls_policy', 'REQUIRE')
    suppression_config = configuration_set_config.fetch('suppression', {})
    suppression_reasons = suppression_config.fetch('reasons', ['BOUNCE', 'COMPLAINT'])

    SES_ConfigurationSet(:ConfigurationSet) do
      if config_set_name
        Name FnSub(config_set_name)
      else
        Name FnSub("${EnvironmentName}-ses-config")
      end
      
      ReputationOptions({
        ReputationMetricsEnabled: reputation_metrics
      })
      
      SendingOptions({
        SendingEnabled: sending_enabled
      })
      
      DeliveryOptions({
        TlsPolicy: tls_policy
      })
      
      SuppressionOptions({
        SuppressedReasons: suppression_reasons
      })
    end

    # ============================================
    # Event Destinations
    # ============================================
    
    event_destinations.each_with_index do |destination, index|
      next unless destination.fetch('enabled', true)
      
      dest_name = destination['name'] || "destination#{index}"
      dest_type = destination['type']
      events = destination.fetch('events', ['SEND', 'DELIVERY', 'BOUNCE', 'COMPLAINT'])
      
      resource_name = dest_name.gsub(/[^a-zA-Z0-9]/, '').capitalize
      
      SES_ConfigurationSetEventDestination("#{resource_name}EventDestination") do
        ConfigurationSetName Ref(:ConfigurationSet)
        
        event_destination = {
          Name: dest_name,
          Enabled: true,
          MatchingEventTypes: events
        }
        
        case dest_type
        when 'sns'
          event_destination[:SnsDestination] = {
            TopicARN: destination['topic_arn']
          }
        
        when 'cloudwatch'
          dimensions = destination.fetch('dimensions', [])
          dimension_configs = dimensions.map do |dim|
            {
              DimensionName: dim['name'],
              DimensionValueSource: dim.fetch('source', 'messageTag'),
              DefaultDimensionValue: dim.fetch('default_value', 'none')
            }
          end
          
          # Default dimension if none specified
          if dimension_configs.empty?
            dimension_configs = [{
              DimensionName: 'ses:configuration-set',
              DimensionValueSource: 'messageTag',
              DefaultDimensionValue: 'default'
            }]
          end
          
          event_destination[:CloudWatchDestination] = {
            DimensionConfigurations: dimension_configs
          }
        
        when 'kinesis_firehose'
          event_destination[:KinesisFirehoseDestination] = {
            DeliveryStreamARN: destination['delivery_stream_arn'],
            IAMRoleARN: destination['iam_role_arn']
          }
        
        when 'eventbridge'
          event_destination[:EventBridgeDestination] = {
            EventBusArn: destination['event_bus_arn']
          }
        end
        
        EventDestination event_destination
      end
    end

    # Configuration Set Output
    Output(:ConfigurationSetName) do
      Description 'Name of the SES Configuration Set'
      Value Ref(:ConfigurationSet)
      Export FnSub("${EnvironmentName}-ses-ConfigurationSetName")
    end
  end

  # ============================================
  # Route53 DNS Records (Optional)
  # ============================================
  
  if manage_dns_records
    dmarc_config = external_parameters.fetch(:dmarc, {})
    dmarc_policy = dmarc_config.fetch('policy', 'none')
    dmarc_rua = dmarc_config.fetch('rua', '')
    dmarc_ruf = dmarc_config.fetch('ruf', '')
    dmarc_pct = dmarc_config.fetch('pct', 100)
    
    # DKIM Record 1
    Route53_RecordSet(:DkimRecord1) do
      HostedZoneId Ref(:HostedZoneId)
      Name FnGetAtt(:EmailIdentity, :DkimDNSTokenName1)
      Type 'CNAME'
      TTL 300
      ResourceRecords [FnGetAtt(:EmailIdentity, :DkimDNSTokenValue1)]
    end
    
    # DKIM Record 2
    Route53_RecordSet(:DkimRecord2) do
      HostedZoneId Ref(:HostedZoneId)
      Name FnGetAtt(:EmailIdentity, :DkimDNSTokenName2)
      Type 'CNAME'
      TTL 300
      ResourceRecords [FnGetAtt(:EmailIdentity, :DkimDNSTokenValue2)]
    end
    
    # DKIM Record 3
    Route53_RecordSet(:DkimRecord3) do
      HostedZoneId Ref(:HostedZoneId)
      Name FnGetAtt(:EmailIdentity, :DkimDNSTokenName3)
      Type 'CNAME'
      TTL 300
      ResourceRecords [FnGetAtt(:EmailIdentity, :DkimDNSTokenValue3)]
    end
    
    # Mail-From MX Record for SPF
    Route53_RecordSet(:MailFromMxRecord) do
      HostedZoneId Ref(:HostedZoneId)
      Name FnSub("#{mail_from_subdomain}.#{domain}.")
      Type 'MX'
      TTL 300
      ResourceRecords [
        FnSub("10 feedback-smtp.${AWS::Region}.amazonses.com")
      ]
    end
    
    # Mail-From SPF TXT Record
    Route53_RecordSet(:MailFromSpfRecord) do
      HostedZoneId Ref(:HostedZoneId)
      Name FnSub("#{mail_from_subdomain}.#{domain}.")
      Type 'TXT'
      TTL 300
      ResourceRecords [
        '"v=spf1 include:amazonses.com ~all"'
      ]
    end
    
    # DMARC Record
    dmarc_value = "v=DMARC1; p=#{dmarc_policy}; pct=#{dmarc_pct}"
    dmarc_value += "; rua=mailto:#{dmarc_rua}" unless dmarc_rua.empty?
    dmarc_value += "; ruf=mailto:#{dmarc_ruf}" unless dmarc_ruf.empty?
    
    Route53_RecordSet(:DmarcRecord) do
      HostedZoneId Ref(:HostedZoneId)
      Name FnSub("_dmarc.#{domain}.")
      Type 'TXT'
      TTL 300
      ResourceRecords [
        "\"#{dmarc_value}\""
      ]
    end
  end

  # ============================================
  # Outputs
  # ============================================
  
  Output(:EmailIdentityArn) do
    Description 'ARN of the SES Email Identity'
    # EmailIdentity doesn't have an ARN attribute, so we construct it
    Value FnSub("arn:aws:ses:${AWS::Region}:${AWS::AccountId}:identity/#{domain}")
    Export FnSub("${EnvironmentName}-ses-EmailIdentityArn")
  end
  
  Output(:DkimDNSTokenName1) do
    Description 'DKIM DNS Token Name 1 (for manual DNS configuration)'
    Value FnGetAtt(:EmailIdentity, :DkimDNSTokenName1)
  end
  
  Output(:DkimDNSTokenName2) do
    Description 'DKIM DNS Token Name 2 (for manual DNS configuration)'
    Value FnGetAtt(:EmailIdentity, :DkimDNSTokenName2)
  end
  
  Output(:DkimDNSTokenName3) do
    Description 'DKIM DNS Token Name 3 (for manual DNS configuration)'
    Value FnGetAtt(:EmailIdentity, :DkimDNSTokenName3)
  end
  
  Output(:DkimDNSTokenValue1) do
    Description 'DKIM DNS Token Value 1 (for manual DNS configuration)'
    Value FnGetAtt(:EmailIdentity, :DkimDNSTokenValue1)
  end
  
  Output(:DkimDNSTokenValue2) do
    Description 'DKIM DNS Token Value 2 (for manual DNS configuration)'
    Value FnGetAtt(:EmailIdentity, :DkimDNSTokenValue2)
  end
  
  Output(:DkimDNSTokenValue3) do
    Description 'DKIM DNS Token Value 3 (for manual DNS configuration)'
    Value FnGetAtt(:EmailIdentity, :DkimDNSTokenValue3)
  end

end

