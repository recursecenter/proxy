require 'aws-sdk'
require 'securerandom'
require 'pathname'
require 'fileutils'
require 'yaml'

module Proxy
  class Deploy
    DEPLOY_ID_FILE = Pathname.new("./.deploy")
    DEPLOY_TAG = "proxy_deploy_id"
    CONFIG_FILE = "config.production.yml"
    REQUIRED_FILES = [
      CONFIG_FILE,
      "certs/cert.pem",
      "certs/key.pem"
    ]

    def initialize
      @id = SecureRandom.uuid

      aws_config = YAML.load(File.read(CONFIG_FILE))['aws']

      region = aws_config['region']

      # Assumes credentials in ENV or ~/.aws/credentials
      @elb = Aws::ElasticLoadBalancing::Client.new(region: region)
      @elb_name = aws_config['elb_name']

      @ec2 = Aws::EC2::Client.new(region: region)
      @security_group = aws_config['security_group']
      @ami = aws_config['ami']
      @instance_count = aws_config['instance_count']
      @instance_type = aws_config['instance_type']
      @key_name = aws_config['key_name']
    end

    def deploy
      ensure_necessary_files
      clean_up_if_necessary

      instance_ids_to_kill = current_instance_ids

      DEPLOY_ID_FILE.write(@id)
      instance_ids = boot_new_instances

      configure_all(instance_ids)

      register_with_elb(instance_ids)

      terminate_instances(instance_ids_to_kill)

      DEPLOY_ID_FILE.unlink
      puts "Deploy finished"
    end

    def terminate_instances(ids)
      puts "Removing old instances from load balancer and terminating..."

      @elb.deregister_instances_from_load_balancer(
        load_balancer_name: @elb_name,
        instances: ids.map { |id| {instance_id: id} }
      )

      @ec2.terminate_instances(instance_ids: ids)
    end

    def register_with_elb(ids)
      print "Registering new instances with the load balancer... "

      @elb.register_instances_with_load_balancer(
        load_balancer_name: @elb_name,
        instances: ids.map { |id| {instance_id: id} }
      )

      @elb.wait_until(
        :instance_in_service,
        load_balancer_name: @elb_name,
        instances: ids.map { |id| {instance_id: id} }
      )

      puts "registered"
    end

    def configure_all(ids)
      puts "Configuring new instances..."

      unless create_tar
        exit(1)
      end

      pages = @ec2.describe_instances(instance_ids: ids).to_a
      hosts = pages.map do |page|
        page.reservations.map do |reservation|
          reservation.instances.map(&:public_dns_name)
        end
      end.flatten

      ssh_opts = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

      hosts.each do |host|
        puts "Waiting for SSH to become available at #{host}..."
        while !system("ssh #{ssh_opts} ubuntu@#{host} echo hi >/dev/null 2>&1"); end

        system("scp #{ssh_opts} #{tar_name} ubuntu@#{host}:~") or exit(1)
        system("ssh #{ssh_opts} ubuntu@#{host} '#{ssh_script}'") or exit(1)
      end

      puts "Instances configured"
    ensure
      FileUtils.rm(tar_name)
    end

    def ssh_script
      <<-SHELL.split("\n").map(&:strip).join(" && ")
        mkdir proxy
        tar xjf #{tar_name} -C proxy
        $HOME/proxy/backend/bin/setup
        sudo $HOME/proxy/backend/bin/proxy-install production
      SHELL
    end

    def create_tar
      files = `git ls-files`.split("\n") + REQUIRED_FILES
      system("tar cjf #{tar_name} #{files.join(' ')}")
    end

    def tar_name
      "proxy-#{@id}.tar.bz2"
    end

    def boot_new_instances
      print "Booting new instances... "

      pages = @ec2.run_instances(
        client_token: @id,
        image_id: @ami,
        min_count: @instance_count,
        max_count: @instance_count,
        key_name: @key_name,
        security_groups: [@security_group],
        instance_type: @instance_type
      ).to_a

      ids = pages.map do |page|
        page.instances.map(&:instance_id)
      end.flatten

      puts "booted: #{ids.join(", ")}"

      @ec2.create_tags(
        resources: ids,
        tags: [{key: DEPLOY_TAG, value: @id}]
      )

      print "Waiting for instances to be ready... "

      @ec2.wait_until(:instance_running, instance_ids: ids)

      puts "ready"

      ids
    end

    def current_instance_ids
      print "Finding currently running instances... "

      pages = @elb.describe_load_balancers({ load_balancer_names: [@elb_name] }).to_a

      ids = pages.map do |page|
        page.load_balancer_descriptions.map do |lb|
          lb.instances.map(&:instance_id)
        end
      end.flatten

      puts "found: #{ids.empty? ? "None" : ids.join(", ")}"

      ids
    end

    def ensure_necessary_files
      missing = REQUIRED_FILES.reject { |f| File.exist?(f) }

      unless missing.empty?
        puts "Cannot deploy. Missing: #{missing.join(", ")}"
        exit(1)
      end
    end

    def clean_up_if_necessary
      if DEPLOY_ID_FILE.exist?
        puts "Last deploy failed to complete. Cleaning up..."
        ids = kill_all_with_uuid(DEPLOY_ID_FILE.read)
        if ids.empty?
          puts "No clean up required."
        else
          puts "Terminated the following instances: #{ids.join(", ")}"
        end
      end
    end

    def kill_all_with_uuid(uuid)
      pages = @ec2.describe_instances(filters: [{name: "tag:#{DEPLOY_TAG}", values: [uuid]}]).to_a

      ids = pages.map do |page|
        page.reservations.map do |reservation|
          reservation.instances.map(&:instance_id)
        end
      end.flatten

      terminate_instances(ids)
      ids
    end
  end
end
