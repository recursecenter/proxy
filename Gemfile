source "https://rubygems.org"

# Ubuntu 18.04 packages Ruby 2.5.1. This is a problem for two reasons:
#
# 1. That version of Ruby is no longer supported.
# 2. Ruby 2.5.1 doesn't run on M1 Macs.
#
# And we mandate the same version of Ruby on both the backend (which runs on EC2)
# and the CLI, which runs on your computer.
#
# When we upgrade to Ubuntu 22.04, which will be released in April of 2022, we should
# not use the Ubuntu packaged Ruby, and instead build our own. Kevin suggests using Vagrant
# to package up an AMI of our own, so that we don't have to wait for Ruby to compile on each
# EC2 instance on each deploy.
#
# Options for doing this are:
#
# 1. Build our own AMI with a modern Ruby version compiled in. On an ARM Mac, there are two
#    problems with this. The first is that as of Feb 2022, there is no official Ubuntu ARM64
#    Vagrant box. The second is that, our EC2 instances are x86_64, so even if there was an
#    ARM64 Ubuntu Vagrant box, we couldn't make an Intel AMI from that box. Two possible solutions:
#    see if vagrant-libvirt supports running a qemu x86_64 guest on a Arm host, and build an x86_64
#    AMI. Or if there is an official ARM64 Ubuntu Vagrant box, we can build an AMI from that and
#    deploy on ARM64 EC2 instances.
# 2. Write a script that launches an Intel EC2 instance, build and install Ruby there, and turn that
#    into an AMI, and use that as our base AMI for Proxy.
# 3. Use Packer to do the same thing as 2.
#
# Kevin thinks option 3 is the best solution, and I'm inclined to agree.
#
# We should do this before April 2023 when Ubuntu 18.04 LTS is no longer supported.

# ruby "2.5.1"

gem "rake"
gem "minitest"
gem "thor"
gem "aws-sdk"
gem "pry"
