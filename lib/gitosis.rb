require 'lockfile'
require 'inifile'
require 'net/ssh'

module Gitosis
  
  def self.renderUrls(baseUrlList, projectId, isReadOnly)
    rendered = ""
    if(not defined?(baseUrlList.length))
      return rendered
    end

    if(baseUrlList.length == 0)
      return rendered
    end
    rendered = rendered + "<strong>" + (isReadOnly ? "Read Only" : "Developer") + " " + (baseUrlList.length == 1 ? "URL" : "URLs") + ": </strong><br/>"
    rendered = rendered + "<ul>";
    for baseUrl in baseUrlList do
      rendered = rendered + "<li>" + "<input style=\"width: 95%;\" class=\"url-field\" type=\"text\" readonly=\"true\" value=\"" + baseUrl + projectId + ".git\" /></li>"
    end
    rendered = rendered + "</ul>\n"
    return rendered
  end
  

  def self.update_repositories(projects)
    projects = (projects.is_a?(Array) ? projects : [projects])
    
    lockfile=File.new(File.join(Dir.tmpdir,'redmine-gitosis_lock'),File::CREAT|File::RDONLY)
    retries=2
    loop do
      break if lockfile.flock(File::LOCK_EX|File::LOCK_NB)
      retries-=1
      sleep 10
      raise Lockfile::MaxTriesLockError if retries<=0
    end

    #Lockfile(File.join(Dir.tmpdir,'redmine-gitosis_lock'), :retries => 2, :sleep_inc=> 10) do

      # HANDLE GIT

      # create tmp dir
      local_dir = File.join(Dir.tmpdir,"redmine-gitosis-#{Time.now.to_i}")

      Dir.mkdir local_dir

      ssh_with_identity_file = File.join(local_dir, 'ssh_with_identity_file.sh')
      
      File.open(ssh_with_identity_file, "w") do |f|
        f.puts "#!/bin/bash"
        f.puts "exec ssh -o stricthostkeychecking=no -i #{Setting.plugin_redmine_gitosis['gitosisIdentityFile']} \"$@\""
      end
      File.chmod(0755, ssh_with_identity_file)
      ENV['GIT_SSH'] = ssh_with_identity_file
      
      # clone repo
      `env GIT_SSH=#{ssh_with_identity_file} git clone #{Setting.plugin_redmine_gitosis['gitosisUrl']} #{local_dir}/gitosis`

      changed = false
    
      projects.select{|p| p.repository.is_a?(Repository::Git)}.each do |project|
        # fetch users
        users = project.member_principals.map(&:user).compact.uniq
        write_users = users.select{ |user| user.allowed_to?( :commit_access, project ) }
        read_users = users.select{ |user| user.allowed_to?( :view_changesets, project ) && !user.allowed_to?( :commit_access, project ) }
    
        # write key files
        users.map{|u| u.gitosis_public_keys.active}.flatten.compact.uniq.each do |key|
          File.open(File.join(local_dir, 'gitosis/keydir',"#{key.identifier}.pub"), 'w') {|f| f.write(key.key.gsub(/\n/,'')) }
        end

        # delete inactives
        users.map{|u| u.gitosis_public_keys.inactive}.flatten.compact.uniq.each do |key|
          File.unlink(File.join(local_dir, 'gitosis/keydir',"#{key.identifier}.pub")) rescue nil
        end
    
        # write config file
        conf = IniFile.new(File.join(local_dir,'gitosis','gitosis.conf'))
        original = conf.clone
        name = "#{project.identifier}"
        
        conf["group #{name}_readonly"]['readonly'] = name
        conf["group #{name}_readonly"]['members'] = read_users.map{|u| u.gitosis_public_keys.active}.flatten.map{ |key| "#{key.identifier}" }.join(' ')
    
        conf["group #{name}"]['writable'] = name
        conf["group #{name}"]['members'] = write_users.map{|u| u.gitosis_public_keys.active}.flatten.map{ |key| "#{key.identifier}" }.join(' ')
        unless conf.eql?(original)
          conf.write 
          changed = true
        end

      end
      if changed
        # add, commit, push, and remove local tmp dir
        `cd #{File.join(local_dir,'gitosis')} ; git add keydir/* gitosis.conf`
        `cd #{File.join(local_dir,'gitosis')} ; git config user.email '#{Setting.mail_from}'`
        `cd #{File.join(local_dir,'gitosis')} ; git config user.name 'Redmine'`
        `cd #{File.join(local_dir,'gitosis')} ; git commit -a -m 'updated by Redmine Gitosis'`
        `cd #{File.join(local_dir,'gitosis')} ; git push`
      end
    
      # remove local copy
      `rm -Rf #{local_dir}`

          
    #end
    lockfile.flock(File::LOCK_UN)
    
    
  end
  
end
