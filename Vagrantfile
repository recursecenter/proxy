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
  config.vm.box = "ubuntu/bionic64"

  # Create a forwarded port mapping which allows access to a specific port
  # within the machine from a port on the host machine. In the example below,
  # accessing "localhost:8443" will access port 443 on the guest machine.
  config.vm.network "forwarded_port", guest: 443, host: 8443

  config.vm.provision "shell", privileged: false, inline: <<-SHELL
    ln -sfn /vagrant $HOME/proxy

    $HOME/proxy/backend/bin/setup
    sudo $HOME/proxy/backend/bin/proxy-install development
  SHELL
end
