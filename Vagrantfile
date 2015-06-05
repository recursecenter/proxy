# -*- mode: ruby -*-
# vi: set ft=ruby :

# All Vagrant configuration is done below. The "2" in Vagrant.configure
# configures the configuration version (we support older styles for
# backwards compatibility). Please don't change it unless you know what
# you're doing.
Vagrant.configure(2) do |config|
  # The most common configuration options are documented and commented below.
  # For a complete reference, please see the online documentation at
  # https://docs.vagrantup.com.

  # Every Vagrant development environment requires a box. You can search for
  # boxes at https://atlas.hashicorp.com/search.
  config.vm.box = "ubuntu/trusty64"

  # Create a forwarded port mapping which allows access to a specific port
  # within the machine from a port on the host machine. In the example below,
  # accessing "localhost:8080" will access port 80 on the guest machine.
  config.vm.network "forwarded_port", guest: 80, host: 8080
  config.vm.network "forwarded_port", guest: 443, host: 8443

  common_provision = <<-SHELL
    sudo adduser vagrant adm

    sudo apt-get update
    sudo apt-get install -y nginx ruby2.0

    sudo ln -sv /vagrant/backend/root/etc/nginx/ssl.conf /etc/nginx/ssl.conf

    echo "Generating strong dhparam..."
    cd /etc/nginx && sudo openssl dhparam -out dhparam.pem 2048 2>/dev/null && cd -
  SHELL

  config.vm.provider :virtualbox do |virtualbox, override|
    override.vm.provision "shell", privileged: false, inline: <<-SHELL
      #{common_provision}

      sudo /vagrant/bin/proxy-install development
    SHELL
  end

  config.vm.provider :aws do |aws, override|
    # Set ENV["AWS_ACCESS_KEY"] and ENV["AWS_SECRET_KEY"]
    #
    # aws.access_key_id = "YOUR KEY"
    # aws.secret_access_key = "YOUR SECRET KEY"
    aws.keypair_name = ""

    aws.ami = "ami-d05e75b8"
    aws.security_groups = ["proxy"]

    override.ssh.username = "ubuntu"
    override.ssh.private_key_path = "~/.ssh/id_rsa"
    override.vm.box = "dummy"

    override.vm.provision "shell", privileged: false, inline: <<-SHELL
      #{common_provision}

      sudo /vagrant/backend/bin/proxy-install production
    SHELL
  end
end
