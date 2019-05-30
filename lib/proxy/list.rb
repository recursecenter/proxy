require 'aws-sdk'

module Proxy
  class List
    CONFIG_FILE = "config.production.yml"

    def initialize
      aws_config = YAML.load(File.read(CONFIG_FILE))['aws']

      region = aws_config['region']

      # Assumes credentials in ENV or ~/.aws/credentials
      @ec2 = Aws::EC2::Client.new(region: region)
    end

    def list_instances
      resp = @ec2.describe_instances(
        filters: [
          {
            name: "tag:Name",
            values: ["proxy-web"]
          },
          {
            name: "instance-state-name",
            values: ["pending", "running", "shutting-down"]
          }
        ]
      )

      instances = resp.to_h[:reservations].map { |r| r[:instances] }.flatten

      instances.each do |i|
        puts "#{i[:public_dns_name]} - #{i[:state][:name]}"
      end
    end
  end
end
