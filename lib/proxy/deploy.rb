require 'aws-sdk'
require 'securerandom'
require 'pathname'
require 'fileutils'
require 'yaml'

module Proxy
  class Deploy
    DEPLOY_ID_FILE = Pathname.new("./.deploy")
    DEPLOY_TAG = "proxy_deploy_id"
    INSTANCE_NAME_TAG = "Name"
    DHPARAM_FILE = "certs/dhparam.pem"
    CERT_FILE = "certs/cert.pem"
    KEY_FILE = "certs/key.pem"

    AUTH_POLICY_TYPE = "BackendServerAuthenticationPolicyType"
    PUBKEY_POLICY_TYPE = "PublicKeyPolicyType"

    def initialize(env)
      @env = env

      @id = SecureRandom.uuid

      aws_config = YAML.load(File.read(config_file))['aws']

      region = aws_config['region']

      # Assumes credentials in ENV or ~/.aws/credentials
      @elb = Aws::ElasticLoadBalancing::Client.new(region: region)
      @elb_name = aws_config['elb_name']
      @tag = aws_config['tag']

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

      # may be nil if this is our first deploy
      last_successful_deploy_id = get_deploy_id(instance_ids_to_kill.first)

      new_pubkey_policy = add_new_public_key(last_successful_deploy_id)

      DEPLOY_ID_FILE.write(@id)
      instance_ids = boot_new_instances

      configure_all(instance_ids)

      register_with_elb(instance_ids)

      terminate_instances(instance_ids_to_kill)

      DEPLOY_ID_FILE.unlink

      # if this fails because of internet connectivity
      # the next deploy will remove the old policies
      remove_old_public_key(new_pubkey_policy)

      puts "Deploy finished"
    end

    def terminate_instances(ids)
      puts "Removing old instances from load balancer and terminating..."

      return if ids.empty?

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
        fail
      end

      resp = @ec2.describe_instances(instance_ids: ids)

      hosts = resp.reservations.map do |reservation|
        reservation.instances.map(&:public_dns_name)
      end.flatten

      ssh_opts = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

      hosts.map do |host|
        Thread.new do
          puts "Waiting for SSH to become available at #{host}..."
          while !system("ssh #{ssh_opts} ubuntu@#{host} echo hi >/dev/null 2>&1"); end

          system("scp #{ssh_opts} #{tar_name} ubuntu@#{host}:~") or fail
          system("ssh #{ssh_opts} ubuntu@#{host} '#{ssh_script}'") or fail
        end
      end.map(&:join)

      puts "Instances configured"
    ensure
      FileUtils.rm(tar_name)
    end

    def ssh_script
      <<-SHELL.split("\n").map(&:strip).join(" && ")
        mkdir proxy
        tar xjf #{tar_name} -C proxy
        $HOME/proxy/backend/bin/setup
        sudo $HOME/proxy/backend/bin/proxy-install #{@env}
      SHELL
    end

    def create_tar
      files = `git ls-files`.split("\n") + required_files
      system("tar cjf #{tar_name} #{files.join(' ')}")
    end

    def tar_name
      "proxy-#{@id}.tar.bz2"
    end

    def boot_new_instances
      print "Booting new instances... "

      responses = availability_zones.cycle.take(@instance_count).map do |zone|
        @ec2.run_instances(
          client_token: @id,
          image_id: @ami,
          min_count: 1,
          max_count: 1,
          key_name: @key_name,
          security_groups: [@security_group],
          instance_type: @instance_type,
          placement: {
            availability_zone: zone
          }
        )
      end

      ids = responses.map do |resp|
        resp.instances.map(&:instance_id)
      end.flatten

      @ec2.wait_until(:instance_exists, instance_ids: ids)

      puts "booted: #{ids.join(", ")}"

      @ec2.create_tags(
        resources: ids,
        tags: [
          {key: DEPLOY_TAG, value: @id},
          {key: INSTANCE_NAME_TAG, value: @tag}
        ]
      )

      print "Waiting for instances to be ready... "

      @ec2.wait_until(:instance_running, instance_ids: ids)

      puts "ready"

      ids
    end

    def current_instance_ids
      print "Finding currently running instances... "

      resp = @elb.describe_load_balancers({ load_balancer_names: [@elb_name] })

      ids = resp.load_balancer_descriptions.map do |lb|
        lb.instances.map(&:instance_id)
      end.flatten

      puts "found: #{ids.empty? ? "None" : ids.join(", ")}"

      ids
    end

    def ensure_necessary_files
      unless File.exist? config_file
        puts "Cannot deploy. Missing: #{config_file}"
        fail
      end

      # Only generate dhparam.pem if it doesn't exist (it takes time to generate).
      # Generate a new certificate every time we deploy because it's cheap and
      # good practice to rotate certificates.
      system("rm", KEY_FILE, CERT_FILE)
      system("bin/rake", DHPARAM_FILE, KEY_FILE, CERT_FILE)
    end

    def clean_up_if_necessary
      return unless DEPLOY_ID_FILE.exist?

      deploy_id = DEPLOY_ID_FILE.read
      puts "Last deploy failed to complete. Cleaning up..."

      clean_up_old_instances(deploy_id)
    end

    def kill_all_with_uuid(uuid)
      resp = @ec2.describe_instances(filters: [{name: "tag:#{DEPLOY_TAG}", values: [uuid]}])

      ids = resp.reservations.map do |reservation|
        reservation.instances.map(&:instance_id)
      end.flatten

      unless ids.empty?
        terminate_instances(ids)
      end

      ids
    end

    def get_deploy_id(instance_id)
      return nil if instance_id.nil?

      resp = @ec2.describe_instances(instance_ids: [instance_id])

      instance = resp.reservations.map { |res| res.instances }.flatten.first

      return nil if instance.nil?

      instance.tags.find { |t| t.key == DEPLOY_TAG }&.value
    end

    def add_new_public_key(last_successful_deploy_id)
      # can be nil
      old_pubkey_policy = get_old_pubkey_policy(last_successful_deploy_id)

      new_key = extract_pubkey(CERT_FILE)
      new_pubkey_policy = create_pubkey_policy(new_key)

      temp_auth_policy = create_auth_policy("temp-auth", keys: [old_pubkey_policy, new_pubkey_policy].compact)
      set_backend_policy(temp_auth_policy)

      new_pubkey_policy
    end

    def get_old_pubkey_policy(last_successful_deploy_id)
      return nil if last_successful_deploy_id.nil?

      get_policy_names(types: [PUBKEY_POLICY_TYPE]).find do |name|
        name == policy_name("pubkey", last_successful_deploy_id)
      end
    end

    def remove_old_public_key(new_pubkey_policy)
      new_auth_policy = create_auth_policy("auth", keys: [new_pubkey_policy])

      set_backend_policy(new_auth_policy)

      clean_up_old_policies
    end

    # We want to destroy all policies except for the currently used
    # public key policy and the backend auth policy that uses it.
    #
    # The policies we want to get rid of include the current temp-auth
    # policy because at this point it is no longer used.
    def clean_up_old_policies
      auth_names = get_policy_names(types: [AUTH_POLICY_TYPE])
      pubkey_names = get_policy_names(types: [PUBKEY_POLICY_TYPE])

      names = auth_names + pubkey_names

      old_names = names.reject { |name| name.include? @id }

      to_destroy = [policy_name("temp-auth")] + old_names
      to_destroy.each { |name| destroy_policy(name) }
    end

    def create_auth_policy(name, keys:)
      full_name = policy_name(name)

      puts "Creating policy #{full_name}"

      @elb.create_load_balancer_policy(
        load_balancer_name: @elb_name,
        policy_name: full_name,
        policy_type_name: AUTH_POLICY_TYPE,
        policy_attributes: keys.map do |k|
          {
            attribute_name: "PublicKeyPolicyName",
            attribute_value: k,
          }
        end
      )

      full_name
    end

    def create_pubkey_policy(key)
      name = policy_name("pubkey")

      puts "Creating policy #{name}"

      @elb.create_load_balancer_policy(
        load_balancer_name: @elb_name,
        policy_name: name,
        policy_type_name: PUBKEY_POLICY_TYPE,
        policy_attributes: [
          {
            attribute_name: "PublicKey",
            attribute_value: key,
          }
        ]
      )

      name
    end

    def extract_pubkey(cert_file)
      pubkey = `openssl x509 -in #{cert_file} -pubkey -noout`

      pubkey.sub!("-----BEGIN PUBLIC KEY-----\n", "")
      pubkey.sub!("-----END PUBLIC KEY-----\n", "")

      pubkey
    end

    def get_policy_names(types:)
      resp = @elb.describe_load_balancer_policies(
        load_balancer_name: @elb_name,
      )

      resp.
        policy_descriptions.
        select { |desc| types.include?(desc.policy_type_name) }.
        map(&:policy_name)
    end

    def set_backend_policy(auth_policy)
      puts "Setting backend auth policy #{auth_policy}"
      @elb.set_load_balancer_policies_for_backend_server(
        load_balancer_name: @elb_name,
        instance_port: 443,
        policy_names: [
          auth_policy
        ]
      )
    end

    def destroy_policy(policy_name)
      puts "Destroying policy #{policy_name}"

      @elb.delete_load_balancer_policy(
        load_balancer_name: @elb_name,
        policy_name: policy_name,
      )
    end

    def clean_up_old_instances(id)
      ids = kill_all_with_uuid(id)

      if ids.empty?
        puts "No instances to terminate."
      else
        puts "Terminated the following instances: #{ids.join(", ")}"
      end
    end

    def policy_name(type, id = @id)
      "proxy-#{type}-policy-#{id}"
    end

    def availability_zones
      @availability_zones ||= @ec2.describe_availability_zones.to_h[:availability_zones].map do |h|
        h[:zone_name]
      end
    end

    def fail
      puts "Deploy failed!"
      Process.kill(:TERM, 0)
      exit 1
    end

    def config_file
      "config.#{@env}.yml"
    end

    def required_files
      [
        config_file,
        DHPARAM_FILE,
        CERT_FILE,
        KEY_FILE
      ]
    end
  end
end
