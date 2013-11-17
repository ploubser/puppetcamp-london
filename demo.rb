# Orchestration with MCollective Demo
# Puppet Camp London - November 2013

# The scenario is as follows
# 5 webservers are behind a load balancer
# The webservers are grouped into three groups using
# classes.

require 'rubygems'
require 'mcollective'
require 'colorize'
include MCollective::RPC

# Exception classes. We're going to use them to determine what went
# wrong during deployment
class PuppetEnabledException<Exception;end;
class LoadBalancerRemoveException<Exception;end;
class FailedUpgradeException<Exception;end;
class FailedDowngradeException<Exception;end;
class LoadBalancerAddException<Exception;end;

# Load balancer hostname
@load_balancer = 'lb1.puppetcamp.com'

def deploy(action = 'upgrade')
  ARGV.each_with_index do |group, i|
    begin
      errors = false
      puts
      puts "Starting deployment of #{group}".green

      puts "Disabling group in load balancer...".green
      remove_from_lb(group)
      puts "Nodes successfully brought down for maintainence".green

      puts "Checking if Puppet is disabled...".green
      check_puppet_status(group)
      puts "Puppet is disabled.".green

      if action == 'upgrade'
        puts "Upgrading demo application...".green
        update_application(group)
        puts "Successfully upgraded demo application".green
      elsif action == 'downgrade'
        puts "Downgrading demo application...".green
        downgrade_application(group)
        puts "Successfully downgraded demo application".green
      end

      puts "Enabling group in load balancer...".green
      add_to_lb(group)
      puts "Nodes successfully brought back up".green
    rescue PuppetEnabledException => e
      puts "Deployment of #{group} failed.".red
      puts "Puppet was enabled on node #{e}. Not removing node from load balancer".red
      errors = true
    rescue LoadBalancerRemoveException => e
      puts "Deployment of #{group} failed.".red
      puts "#{e} could not be removed from the load balancer".red
      errors = true
    rescue FailedUpgradeException => e
      puts "Deployment of #{group} failed.".red
      puts "Application upgrade failed on node #{e}".red
      errors = true
    rescue FailedDowngradeException => e
      puts "Deployment of #{group} failed.".red
      puts "Application downgrade failed on node #{e}".red
      errors = true
    rescue LoadBalancerAddException => e
      puts "Deployment of #{group} failed.".red
      puts "#{e} could not be enabled on the load balancer".red
      errors = true
    end

    if errors
      puts "An error occurred while upgrading #{group}".red
    else
      puts "Finished deploying #{group}".green
    end

    if i < ARGV.size - 1
      puts
      puts "Press Enter to start next group or ctrl+c to exit."
      begin
        $stdin.gets
      rescue Interrupt, SystemExit
        exit 1
      end
    end
  end

  load_balancer_status
end

# First check in our deployment. Is the puppet agent disabled?
def check_puppet_status(group)
  @service.class_filter group
  begin
    @service.status(:service => 'puppet').each do |rpcresult|
      # Check if puppet is disabled
      hostname = rpcresult.results[:sender]
      if rpcresult.results[:data][:status] != "stopped"
        raise PuppetEnabledException, hostname
      end
    end
  ensure
    # Make sure we reset the filter after a run
    @service.reset_filter
  end
end

# Mark the group as disabled in the load balancer
def remove_from_lb(group)
  @haproxy.identity_filter(@load_balancer)
  # We don't have to identify the nodes in the group
  # for every action. I'm doing it here to make each
  # method easier to read
  @rpcutil.class_filter(group)
  begin
    @rpcutil.ping.each do |node|
      hostname = node.results[:sender]
      # Disable the nodes
      @haproxy.disable(:backend => 'puppetcamp', :server => hostname).each do |rpcresult|
        if rpcresult.results[:statuscode] != 0
          raise LoadBalancerRemoveException, hostname
        end
      end
    end
  ensure
    @haproxy.reset_filter
    @rpcutil.reset_filter
  end
end

# Update the application on each node in the group
def update_application(group)
  @site.class_filter(group)
  begin
    @site.upgrade.each do |rpcresult|
      if rpcresult.results[:statuscode] != 0
        hostname = rpcresult.results[:sender]
        raise FailedUpgradeException, hostname
      end
    end
  ensure
    @site.reset_filter
  end
end

# Downgrade the application on each node in the group
def downgrade_application(group)
  @site.class_filter(group)
  begin
    @site.downgrade.each do |rpcresult|
      if rpcresult.results[:statuscode] != 0
        hostname = rpcresult.results[:sender]
        raise FailedDowngradeException, hostname
      end
    end
  ensure
    @site.reset_filter
  end
end

# Return nodes to load balancer
def add_to_lb(group)
  @haproxy.identity_filter(@load_balancer)
  # We don't have to identify the nodes in the group
  # for every action. I'm doing it here to make each
  # method easier to read
  @rpcutil.class_filter(group)
  begin
    @rpcutil.ping.each do |node|
      hostname = node.results[:sender]
      # Disable the nodes
      @haproxy.enable(:backend => 'puppetcamp', :server => hostname).each do |rpcresult|
        if rpcresult.results[:statuscode] != 0
          raise LoadBalancerAddException, hostname
        end
      end
    end
  ensure
    @haproxy.reset_filter
    @rpcutil.reset_filter
  end
end

# Set up the MCollective clients
def create_clients
  @haproxy = rpcclient('haproxy')
  @site = rpcclient('site')
  @service = rpcclient('service')
  @rpcutil = rpcclient('rpcutil')
  # Disable to progress bar to clean up output a little
  [@haproxy, @site, @service, @rpcutil].each do |client|
    client.progress = false
  end
end

# Display current load balancer status
def load_balancer_status
  puts
  @haproxy.identity_filter(@load_balancer)
  rpcresult = @haproxy.backend_status(:backend => 'puppetcamp')
  puts "Enabled Nodes :".green
  rpcresult.each do |enabled| 
    enabled[:data][:enabled].each do |host|
      puts "  #{host}".green
    end
  end
  puts
  puts "Disabled Nodes :".red
  rpcresult.each do |disabled|
    disabled[:data][:disabled].each do |host|
      puts "  #{host}".red
    end
  end
  puts
end

def main
  create_clients
  deploy
end

if $0 == __FILE__
  create_clients
  action = ARGV.shift
  if action == "upgrade"
    deploy('upgrade')
  elsif action == "downgrade"
    deploy('downgrade')
  end
end
