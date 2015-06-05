require 'aws-sdk'

module Proxy
  class Deploy
    def initialize
      # Assumes credentials in ENV or ~/.aws/credentials
      @client = Aws::ElasticLoadBalancing::Client.new(
        region: "us-east-1"
      )
      @elb_name = "proxy-elb"
    end

    def deploy
      instance_ids_to_kill = current_instance_ids

      instance_ids = boot_new_instances

      wait_for_healthy(instance_ids)

      kill_instances(instance_ids_to_kill)
    end

    def boot_new_instances
      boot the things

      tar up the backend

      for each thing
        log in, send the tar, untar, run a script
      end

      return new instance ids
    end

    def current_instance_ids
      page = @client.describe_load_balancers({ load_balancer_names: [@elb_name] })
      page.data.load_balancer_descriptions[0].instances.map(&:instance_id)
    end
  end
end
