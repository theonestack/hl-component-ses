CfhighlanderTemplate do

  Name 'ses'
  Description 'AWS SES component for outbound email sending with domain identity and configuration set'

  Parameters do
    ComponentParam 'EnvironmentName', 'dev', isGlobal: true
    ComponentParam 'EnvironmentType', 'development', isGlobal: true
    ComponentParam 'DnsDomain', isGlobal: true

    if manage_dns_records == true
      ComponentParam 'HostedZoneId', ''
    end
  end

end

