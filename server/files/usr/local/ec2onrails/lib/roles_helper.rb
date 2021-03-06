#    This file is part of EC2 on Rails.
#    http://rubyforge.org/projects/ec2onrails/
#
#    Copyright 2007 Paul Dowman, http://pauldowman.com/
#
#    EC2 on Rails is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    EC2 on Rails is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.

require 'erb'
require 'fileutils'
require 'net/http'
require 'pp'
require 'resolv'
require 'socket'
require 'yaml'

module Ec2onrails
  module RolesHelper
    ROLES_FILE = "/etc/ec2onrails/roles.yml"
    MONGREL_CONF_FILE = "/etc/mongrel_cluster/app.yml"

    def local_address
      @local_address ||= get_metadata "local-ipv4"
    end

    def public_address
      @public_address ||= get_metadata "public-ipv4"
    end

    def roles
      @roles ||= resolve_all_addresses(YAML::load_file(ROLES_FILE))
    end

    def start(role, service, prog_name = service)
      puts "STARTING #{role} role (service: #{service}, program_name: #{prog_name})"
      sudo "god start #{role}"
      # sudo "god monitor #{role}"
    end

    def stop(role, service, prog_name = service)
      puts "STOPING #{role} role (service: #{service}, program_name: #{prog_name})"
      # sudo "god monitor #{role}"
      sudo "god stop #{role}"
    end

    def run(cmd)
      result = system(cmd)
      puts("*****ERROR: #{cmd} returned #{$?}") unless result
    end
    
    def sudo(cmd)
      run("sudo #{cmd}")
    end

    def get_metadata(type)
      data  = Net::HTTP.get('169.254.169.254', "/latest/meta-data/#{type}").strip
      
      raise "couldn't get instance data: #{type}" if data.nil? || data.strip.length == 0
      # puts "#{type}: #{address}"
      return data
    end

    def resolve(hostname)
      # hostname might be an alias, so get the .amazonaws.com hostname
      canonical_name = Resolv.getname(IPSocket.getaddress(hostname))      

      # EC2's internal DNS resolves the external hostnames (*.amazonaws.com) into internal IP addresses
      address = IPSocket.getaddress(canonical_name).strip

      if address == local_address || address == public_address
        "127.0.0.1"
      else
        address
      end
    rescue Exception => e
      puts "couldn't resolve hostname '#{hostname}'"
      raise e
    end

    def resolve_all_addresses(original)
      resolved = {}
      original.each do |rolename, hostnames|
        resolved[rolename] = hostnames.map{|hostname| resolve(hostname)} if hostnames
      end
      resolved
    end

    def in_role?(role)
      return false unless roles[role]
      return roles[role].include?("127.0.0.1") 
    end
    #to provide deprecated usage
    alias :in_role :in_role?
    
    def web_starting_port
      mongrel_config['port'].to_i rescue 8000
    end

    def web_num_instances
      mongrel_config['servers'].to_i rescue 6
    end

    def web_port_range
      (web_starting_port..(web_starting_port + web_num_instances-1))
    end
    
    def server_environment
      mongrel_config["environment"]
    end
    
    def user
      mongrel_config['user']
    end

    def group
      mongrel_config['group']
    end
    
    def application_root
      mongrel_config['cwd']
    end    
    
    def pid_file
      "#{application_root}/#{mongrel_config['pid_file']}"
    end

    # write a hostname alias for each host. The hostnames will be "rolename-n" where n
    # is an integer
    def set_hostnames
      hosts_file  = "/etc/hosts"
      FileUtils.cp "#{hosts_file}.original", hosts_file
      File.open(hosts_file, 'a') do |f| 
        roles.each do |rolename, addresses|
          addresses.each_with_index do |address, i|
            f << "#{rolename.to_s.gsub(/_/, "-")}-#{i+1} #{address}\n"
          end
        end
      end
      
      # Eventually we'll remove this:
      if roles[:db_primary]
        db_primary_addr = roles[:db_primary][0]
        File.open(hosts_file, 'a') do |f|
          f << "# DEPRECATED: this is here for backwards compatibility, eventually it will be removed:\n"
          f << "#{db_primary_addr} db_primary\n"
        end
      end
    end
   
    # Process any ERB template under /etc
    # The output from "filename.erb" will be saved as "filename"
    def process_config_file_templates
      # Set any variables that will be needed inside the templates
      # We're processing ALL templates, even ones that won't be used in the current role, but I think that's OK.
      web_port_range = self.web_port_range
      web_starting_port = self.web_starting_port
      roles = self.roles

      Dir["/etc/**/*.erb"].each do |filename|
        puts "Processing config file template: #{filename}..."
        contents = ERB.new(IO.read(filename)).result(binding)
        file_name = filename.sub(/\.erb$/, '')
        File.open(file_name, 'w'){|f| f << contents}
      end
    end
    
    private

    def mongrel_config
      @mongrel_config ||= YAML::load_file(MONGREL_CONF_FILE)
    end

  end
end