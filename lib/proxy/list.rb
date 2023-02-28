require 'aws-sdk'

module Proxy
  class List
    def initialize(env)
      @env = env
      aws_config = YAML.load(File.read(config_file))['aws']

      region = aws_config['region']
      @tag = aws_config['tag']

      # Assumes credentials in ENV or ~/.aws/credentials
      @ec2 = Aws::EC2::Client.new(region: region)
    end

    def list_instances
      resp = @ec2.describe_instances(
        filters: [
          {
            name: "tag:Name",
            values: [@tag]
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

    def config_file
      "config.#{@env}.yml"
    end
  end
end
