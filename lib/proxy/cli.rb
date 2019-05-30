require 'thor'

module Proxy
  class CLI < Thor
    class << self
      alias task define_method
    end

    desc "deploy", "Deploy current master branch to Amazon AWS"
    task "deploy" do
      Proxy::Deploy.new.deploy
    end

    desc "list", "List current instances"
    task "list" do
      Proxy::List.new.list_instances
    end
  end
end
