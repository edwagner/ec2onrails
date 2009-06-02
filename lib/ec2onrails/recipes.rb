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

require 'fileutils'
include FileUtils
require 'tmpdir'
require 'pp'
require 'zlib'
require 'archive/tar/minitar'
include Archive::Tar

require 'ec2onrails/version'
require 'ec2onrails/capistrano_utils'
include Ec2onrails::CapistranoUtils



Dir[File.join(File.dirname(__FILE__), "recipes/*")].find_all{|x| File.file? x}.each do |recipe|
  require recipe 
end


Capistrano::Configuration.instance.load do

  unless ec2onrails_config
    raise "ec2onrails_config variable not set. (It should be a hash.)"
  end
  
  cfg = ec2onrails_config
  
  set :ec2onrails_version, Ec2onrails::VERSION::STRING
  set :deploy_to, "/mnt/app"
  set :use_sudo, false
  set :user, "app"

  # Since :setup does a deploy:update_code, remove that directory before deploy:cold gets run
  before "deploy:cold", "ec2onrails:setup", "ec2onrails:remove_release_directory"  

  after "deploy:symlink", "ec2onrails:server:set_roles", "ec2onrails:server:init_services"
  after "deploy:cold", "ec2onrails:db:init_backup", "ec2onrails:db:optimize", "ec2onrails:server:restrict_sudo_access"
  # TODO I don't think we can do gem source -a every time because I think it adds the same repo multiple times
  after "ec2onrails:server:install_gems", "ec2onrails:server:add_gem_sources"

  # There's an ordering problem here. For convenience, we want to run 'rake gems:install' automatically
  # on every deploy, but in the ec2onrails:setup task I want to do update_code before any other 
  # setup tasks, and at that point I don't want run_rails_rake_gems_install to run. So run_rails_rake_gems_install
  # can't be triggered by an "after" hook on update_code.
  # But users might want to have their own tasks triggered after update_code, and those tasks will
  # fail if they require gems to be installed (or anything else to be set up).
  # 
  # The best solution is to use an after hook on "deploy:symlink" or "deploy:update" instead of on
  # "deploy:update_code"
  on :load do
    before "deploy:symlink", "ec2onrails:server:run_rails_rake_gems_install"
    before "deploy:symlink", "ec2onrails:server:install_system_files"
  end  

  
  namespace :ec2onrails do
    desc <<-DESC
      Show the AMI id's of the current images for this version of \
      EC2 on Rails.
    DESC
    task :ami_ids do
      puts "32-bit server image (US location) for EC2 on Rails #{ec2onrails_version}: #{Ec2onrails::VERSION::AMI_ID_32_BIT_US}"
      puts "64-bit server image (US location) for EC2 on Rails #{ec2onrails_version}: #{Ec2onrails::VERSION::AMI_ID_64_BIT_US}"
      puts "32-bit server image (EU location) for EC2 on Rails #{ec2onrails_version}: #{Ec2onrails::VERSION::AMI_ID_32_BIT_EU}"
      puts "64-bit server image (EU location) for EC2 on Rails #{ec2onrails_version}: #{Ec2onrails::VERSION::AMI_ID_64_BIT_EU}"
    end
    
    desc <<-DESC
      Copies the public key from the server using the external "ssh"
      command because Net::SSH, which is used by Capistrano, needs it.
      This will only work if you have an ssh command in the path.
      If Capistrano can successfully connect to your EC2 instance you
      don't need to do this. It will copy from the first server in the
      :app role, this can be overridden by specifying the HOST 
      environment variable
    DESC
    task :get_public_key_from_server do
      host = find_servers_for_task(current_task).first.host
      privkey = ssh_options[:keys][0]
      pubkey = "#{privkey}.pub"
      msg = <<-MSG
      Your first key in ssh_options[:keys] is #{privkey}, presumably that's 
      your EC2 private key. The public key will be copied from the server 
      named '#{host}' and saved locally as #{pubkey}. Continue? [y/n]
      MSG
      choice = nil
      while choice != "y" && choice != "n"
        choice = Capistrano::CLI.ui.ask(msg).downcase
        msg = "Please enter 'y' or 'n'."
      end
      if choice == "y"
        run_local "scp -i '#{privkey}' app@#{host}:.ssh/authorized_keys #{pubkey}"
      end
    end
    
    desc <<-DESC
      Remove the latest release directory.
      Since deploy:cold ends up runing deploy:update_code twice in the
      same release directory (once in :setup, and once in deploy:cold),
      problems may occur if we don't delete the release directory
      before the second deploy:update_code.
      This task should be called at the end of :setup.
    DESC
    task :remove_release_directory do
      run "rm -rf #{release_path}; true"
    end

    desc <<-DESC
      Prepare a newly-started instance for a cold deploy.
    DESC
    task :setup do
      # we now have some things being included inside the app so we deploy
      # the app's code to the server before we do any other setup
      server.upload_deploy_keys
      deploy.setup
      deploy.update_code
      
      ec2onrails.server.allow_sudo do
        server.set_timezone
        server.set_mail_forward_address
        server.install_packages
        server.install_gems
        server.run_rails_rake_gems_install
        server.deploy_files # DEPRECATED, see install_system_files
        server.install_system_files
        server.set_roles
        server.enable_ssl if cfg[:enable_ssl]
        server.set_rails_env
        server.restart_services
        db.create
        server.harden_server
        db.enable_ebs
        db.set_root_password
      end
    end

  end
end


