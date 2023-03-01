require 'thor'

module Proxy
  class CLI < Thor
    class << self
      alias task define_method
    end

    desc "deploy ENV", "Deploy current master branch to ENV on AWS"
    task "deploy" do |env="production"|
      Proxy::Deploy.deploy(env)
    end

    desc "list ENV", "List current instances in ENV"
    task "list" do |env="production"|
      Proxy::List.list_instances(env)
    end
  end
end
