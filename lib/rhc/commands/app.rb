require 'rhc/commands/base'
require 'resolv'
require 'rhc/git_helpers'
require 'rhc/cartridge_helpers'
require 'rhc/deployment_helpers'
require 'optparse'
require 'tmpdir'

module RHC::Commands
  class App < Base
    summary "Commands for creating and managing applications"
    description <<-DESC
      Creates and controls an OpenShift application.  To see the list of all
      applications use the rhc domain show command.  Note that delete is not
      reversible and will stop your application and then remove the application
      and repo from the remote server. No local changes are made.
      DESC
    syntax "<action>"
    default_action :help
    suppress_wizard

    summary "Create an application"
    description <<-DESC
      Create an application. Every OpenShift application must have one
      web cartridge which serves web requests, and can have a number of
      other cartridges which provide capabilities like databases,
      scheduled jobs, or continuous integration.

      You can see a list of all valid cartridge types by running
      'rhc cartridge list'. OpenShift also supports downloading cartridges -
      pass a URL in place of the cartridge name and we'll download
      and install that cartridge into your app.  Keep in mind that
      these cartridges receive no security updates.  Note that not
      all OpenShift servers allow downloaded cartridges.

      When your application is created, a URL combining the name of
      your app and the name of your domain will be registered in DNS.
      A copy of the code for your application will be checked out locally
      into a folder with the same name as your application.  Note that
      different types of applications may require different folder
      structures - check the README provided with the cartridge if
      you have questions.

      OpenShift runs the components of your application on small virtual
      servers called "gears".  Each account or plan is limited to a number
      of gears which you can use across multiple applications.  Some
      accounts or plans provide access to gears with more memory or more
      CPU.  Run 'rhc account' to see the number and sizes of gears available
      to you.  When creating an application the --gear-size parameter
      may be specified to change the gears used.

      DESC
    syntax "<name> <cartridge> [... <cartridge>] [... VARIABLE=VALUE] [-n namespace]"
    option ["-n", "--namespace NAME"], "Namespace for the application"
    option ["-g", "--gear-size SIZE"], "Gear size controls how much memory and CPU your cartridges can use."
    option ["-s", "--[no-]scaling"], "Enable scaling for the web cartridge."
    option ["-r", "--repo DIR"], "Path to the Git repository (defaults to ./$app_name)"
    option ["-e", "--env VARIABLE=VALUE"], "Environment variable(s) to be set on this app, or path to a file containing environment variables", :type => :list
    option ["--from-app NAME"], "Create based on another application. All content and configurations will be copied from the original app."
    option ["--from-code URL"], "URL to a Git repository that will become the initial contents of the application"
    option ["--region REGION"], "The region where the application gears will be located"
    option ["--[no-]git"], "Skip creating the local Git repository."
    option ["--[no-]dns"], "Skip waiting for the application DNS name to resolve. Must be used in combination with --no-git"
    option ['--no-keys'], "Skip checking SSH keys during app creation", :hide => true
    option ["--enable-jenkins [NAME]"], "Enable Jenkins builds for this application (will create a Jenkins application if not already available). The default name will be 'jenkins' if not specified."
    argument :name, "Name for your application", ["-a", "--app NAME"], :optional => true
    argument :cartridges, "The web framework this application should use", ["-t", "--type CARTRIDGE"], :optional => true, :type => :list
    def create(name, cartridges)
      check_config!

      check_name!(name)

      arg_envs, cartridges = cartridges.partition{|item| item.match(env_var_regex_pattern)}

      rest_domain = check_domain!
      rest_app = nil
      repo_dir = nil

      if options.from_app
        raise RHC::AppCloneNotSupportedException, "The server does not support creating apps based on others (rhc create-app --from-app)." if (!rest_domain.has_param?('ADD_APPLICATION', 'cartridges[][name]') || !rest_domain.has_param?('ADD_APPLICATION', 'cartridges[][url]'))
        raise ArgumentError, "Option --from-code is incompatible with --from-app. When creating an app based on another resource you can either specify a Git repository URL with --from-code or an existing app name with --from-app." if options.from_code     
        raise ArgumentError, "Option --no-dns is incompatible with --from-app. We need to propagate the new app DNS to be able to configure it." if options.dns == false
        raise ArgumentError, "Do not specify cartridges when creating an app based on another one. All cartridges will be copied from the original app." if !(cartridges || []).empty?

        from_app = find_app(:app => options.from_app)

        arg_envs = from_app.environment_variables.collect {|env| "#{env.name}=#{env.value}"} + arg_envs
        cartridges = from_app.cartridges.reject{|c| c.tags.include?('web_proxy')}.collect{|c| c.custom? ? c.url : c.name}
      end

      cartridges = check_cartridges(cartridges, &require_one_web_cart)

      options.default \
        :dns => true,
        :git => true

      raise ArgumentError, "You have named both your main application and your Jenkins application '#{name}'. In order to continue you'll need to specify a different name with --enable-jenkins or choose a different application name." if jenkins_app_name == name && enable_jenkins?

      cart_names = cartridges.collect do |c|
        c.usage_rate? ? "#{c.short_name} (addtl. costs may apply)" : c.short_name
      end.join(', ')

      env = collect_env_vars(arg_envs.concat(Array(options.env)))
      if env.present? && !rest_domain.supports_add_application_with_env_vars?
        env = []
        warn "Server does not support environment variables."
      end

      scaling = options.scaling
      region = options.region
      gear_profile = options.gear_size

      raise RHC::RegionsAndZonesNotSupportedException if region.present? && !rest_client.supports_regions_and_zones?

      if from_app
        scaling = from_app.scalable if scaling.nil?
        region = from_app.region if region.nil?
        gear_profile = from_app.gear_profile if gear_profile.nil?

        if region.present? && !rest_client.allows_region_selection?
          region = nil
          warn 'Server does not allow selecting regions.  Region is being ignored.'
        end

        cartridges = from_app.cartridges.reject{|c| c.tags.include?('web_proxy')}.collect do |cartridge|
          {
            :name => (cartridge.name if !cartridge.custom?), 
            :url => (cartridge.url if cartridge.custom?),
            :gear_size => options.gear_size || cartridge.gear_profile,
            :additional_gear_storage => (cartridge.additional_gear_storage if cartridge.additional_gear_storage > 0),
            :scales_from => (cartridge.scales_from if scaling && cartridge.scalable?),
            :scales_to => (cartridge.scales_to if scaling && cartridge.scalable?)
          }.reject{|k,v| v.nil? }
        end
      end

      paragraph do
        header "Application Options"
        say table([["Domain:", options.namespace],
               ["Cartridges:", cart_names],
              (["Source Code:", options.from_code] if options.from_code),
              (["From app:", from_app.name] if from_app),
               ["Gear Size:", options.gear_size || (from_app ? "Copied from '#{from_app.name}'" : "default")],
               ["Scaling:", (scaling ? "yes" : "no") + (from_app && options.scaling.nil? ? " (copied from '#{from_app.name}')" : '')],
              (["Environment Variables:", env.map{|item| "#{item.name}=#{item.value}"}.join(', ')] if env.present?),
              (["Region:", region + (from_app && options.region.nil? ? " (copied from '#{from_app.name}')" : '')] if region),
              ].compact
             )
      end

      paragraph do
        say "Creating application '#{name}' ... "

        # create the main app
        rest_app = create_app(name, cartridges, rest_domain, gear_profile, scaling, options.from_code, env, options.auto_deploy, options.keep_deployments, options.deployment_branch, options.deployment_type, region)
        success "done"

        paragraph{ indent{ success rest_app.messages.map(&:strip) } }
      end

      build_app_exists = rest_app.building_app

      if enable_jenkins?

        unless build_app_exists
          paragraph do
            say "Setting up a Jenkins application ... "

            begin
              build_app_exists = add_jenkins_app(rest_domain)

              success "done"
              paragraph{ indent{ success build_app_exists.messages.map(&:strip) } }

            rescue Exception => e
              warn "not complete"
              add_issue("Jenkins failed to install - #{e}",
                        "Installing jenkins and jenkins-client",
                        "rhc create-app jenkins",
                        "rhc add-cartridge jenkins-client -a #{rest_app.name}")
            end
          end
        end

        paragraph do
          messages = []
          add_jenkins_client_to(rest_app, messages)
          paragraph{ indent{ success messages.map(&:strip) } }
        end if build_app_exists
      end

      debug "Checking SSH keys through the wizard"
      check_sshkeys! unless options.no_keys

      if options.dns
        paragraph do
          say "Waiting for your DNS name to be available ... "
          if dns_propagated? rest_app.host
            success "done"
          else
            warn "failure"
            add_issue("We were unable to lookup your hostname (#{rest_app.host}) in a reasonable amount of time and can not clone your application.",
                      "Clone your git repo",
                      "rhc git-clone #{rest_app.name}")

            output_issues(rest_app)
            return 0
          end
        end
      end

      if from_app
        say "Setting deployment configuration ... "
        rest_app.configure({:auto_deploy => from_app.auto_deploy, :keep_deployments => from_app.keep_deployments , :deployment_branch => from_app.deployment_branch, :deployment_type => from_app.deployment_type})
        success 'done'

        snapshot_filename = temporary_snapshot_filename(from_app.name)
        save_snapshot(from_app, snapshot_filename)
        restore_snapshot(rest_app, snapshot_filename)
        File.delete(snapshot_filename) if File.exist?(snapshot_filename)

        paragraph { warn "The application '#{from_app.name}' has aliases set which were not copied. Please configure the aliases of your new application manually." } unless from_app.aliases.empty?
      end

      if options.git
        section(:now => true, :top => 1, :bottom => 1) do
          begin
            if has_git?
              repo_dir = git_clone_application(rest_app)
            else
              warn "You do not have git installed, so your application's git repo will not be cloned"
            end
          rescue RHC::GitException => e
            warn "#{e}"
            unless RHC::Helpers.windows? and windows_nslookup_bug?(rest_app)
              add_issue("We were unable to clone your application's git repo - #{e}",
                        "Clone your git repo",
                        "rhc git-clone #{rest_app.name}")
            end
          end
        end
      end

      output_issues(rest_app) if issues?

      paragraph do
        say "Your application '#{rest_app.name}' is now available."
        paragraph do
          indent do
            say table [
                ['URL:', rest_app.app_url],
                ['SSH to:', rest_app.ssh_string],
                ['Git remote:', rest_app.git_url],
                (['Cloned to:', repo_dir] if repo_dir)
              ].compact
          end
        end
      end
      paragraph{ say "Run 'rhc show-app #{name}' for more details about your app." }

      0
    end


    summary "Delete an application from the server"
    description "Deletes your application and all of its data from the server.",
                "Use with caution as this operation is permanent."
    syntax "<app> [--namespace NAME]"
    takes_application :argument => true
    option ["--confirm"], "Pass to confirm deleting the application"
    alias_action :destroy, :deprecated => true
    def delete(app)
      rest_app = find_app

      confirm_action "#{color("This is a non-reversible action! Your application code and data will be permanently deleted if you continue!", :yellow)}\n\nAre you sure you want to delete the application '#{app}'?"

      say "Deleting application '#{rest_app.name}' ... "
      rest_app.destroy
      success "deleted"

      paragraph{ rest_app.messages.each{ |s| success s } }

      0
    end

    summary "Start the application"
    syntax "<app> [--namespace NAME]"
    takes_application :argument => true
    def start(app)
      app_action :start

      results { say "#{app} started" }
      0
    end

    summary "Stop the application"
    syntax "<app> [--namespace NAME]"
    takes_application :argument => true
    def stop(app)
      app_action :stop

      results { say "#{app} stopped" }
      0
    end

    summary "Scale up the application's web cartridge"
    syntax "<app> [--namespace NAME]"
    takes_application :argument => true
    def scale_up(app)
      app_action :scale_up

      results { say "#{app} scaled up" }
      0
    end

    summary "Scale down the application's web cartridge"
    syntax "<app> [--namespace NAME]"
    takes_application :argument => true
    def scale_down(app)
      app_action :scale_down

      results { say "#{app} scaled down" }
      0
    end

    summary "Stops all application processes"
    syntax "<app> [--namespace NAME]"
    takes_application :argument => true
    def force_stop(app)
      app_action :stop, true

      results { say "#{app} force stopped" }
      0
    end

    summary "Restart the application"
    syntax "<app> [--namespace NAME]"
    takes_application :argument => true
    def restart(app)
      app_action :restart

      results { say "#{app} restarted" }
      0
    end

    summary "Reload the application's configuration"
    syntax "<app> [--namespace NAME]"
    takes_application :argument => true
    def reload(app)
      app_action :reload

      results { say "#{app} config reloaded" }
      0
    end

    summary "Clean out the application's logs and tmp directories and tidy up the git repo on the server"
    syntax "<app> [--namespace NAME]"
    takes_application :argument => true
    def tidy(app)
      app_action :tidy

      results { say "#{app} cleaned up" }
      0
    end

    summary "Make the application highly available"
    syntax "<app> [--namespace NAME]"
    takes_application :argument => true
    def enable_ha(app)
      app_action :enable_ha

      results { say "#{app} is now highly available" }
      0
    end

    summary "Show information about an application"
    description <<-DESC
      Display the properties of an application, including its URL, the SSH
      connection string, and the Git remote URL.  Will also display any
      cartridges, their scale, and any values they expose.

      The '--state' option will retrieve information from each cartridge in
      the application, which may include cartridge specific text.

      The '--configuration' option will display configuration values set in
      the application. Use 'rhc configure-app' to configure.

      To see information about the individual gears within an application,
      use '--gears', including whether they are started or stopped and their
      SSH host strings.  Passing '--gears quota' will show the free and maximum
      storage on each gear.

      If you want to run commands against individual gears, use:

        rhc ssh <app> --gears '<command>'

      to run and display the output from each gear.

      DESC
    syntax "<app> [--namespace NAME]"
    takes_application :argument => true
    option ["--state"], "Get the current state of the cartridges in this application"
    option ["--configuration"], "Get the current configuration values set in this application"
    option ["--gears [quota|ssh]"], "Show information about the cartridges on each gear in this application. Pass 'quota' to see per gear disk usage and limits. Pass 'ssh' to print only the SSH connection strings of each gear."
    option ["-v", "--verbose"], "Display more details about the application's cartridges"
    def show(app_name)

      if options.state
        find_app(:with_gear_groups => true).each do |gg|
          say "Cartridge #{gg.cartridges.collect { |c| c['name'] }.join(', ')} is #{gear_group_state(gg.gears.map{ |g| g['state'] })}"
        end

      elsif options.gears && options.gears != true
        groups = find_app(:with_gear_groups => true)

        case options.gears
        when 'quota'
          opts = {:as => :gear, :split_cells_on => /\s*\t/, :header => ['Gear', 'Cartridges', 'Used', 'Limit'], :align => [nil, nil, :right, :right]}
          table_from_gears('echo "$(du --block-size=1 -s 2>/dev/null | cut -f 1)"', groups, opts) do |gear, data, group|
            [gear['id'], group.cartridges.collect{ |c| c['name'] }.join(' '), (human_size(data.chomp) rescue 'error'), human_size(group.quota)]
          end
        when 'ssh'
          groups.each{ |group| group.gears.each{ |g| say (ssh_string(g['ssh_url']) or raise NoPerGearOperations) } }
        else
          run_on_gears(ssh_command_for_op(options.gears), groups)
        end

      elsif options.gears
        domain, app = discover_domain_and_app
        gear_info = rest_client.find_application_gear_groups_endpoints(domain, app).map do |group|
          group.gears.map do |gear|
            [
              gear['id'],
              gear['state'] == 'started' ? color(gear['state'], :green) : color(gear['state'], :yellow),
              (gear['endpoints'].blank? ? group.cartridges : gear['endpoints']).collect{ |c| c['cartridge_name'] || c['name'] }.join(' '),
              group.gear_profile,              
              gear['region'],
              gear['zone'],
              ssh_string(gear['ssh_url'])
            ]
          end
        end.flatten(1)

        explicit_regions = gear_info.select{|i| !i[4].nil?}.present?
        explicit_zones = gear_info.select{|i| !i[5].nil?}.present?

        say table(gear_info.map(&:compact), :header => ['ID', 'State', 'Cartridges', 'Size', explicit_regions ? 'Region' : nil, explicit_zones ? 'Zone' : nil, 'SSH URL'].compact)

      elsif options.configuration
        display_app_configurations(find_app)
        paragraph { say "Use 'rhc configure-app' to change the configuration values of this application." }

      else
        app = find_app(:include => :cartridges)
        display_app(app, app.cartridges, nil, options.verbose)
      end

      0
    end

    summary "Deploy a git reference or binary file of an application"
    syntax "<ref> --app NAME [--namespace NAME]"
    description <<-DESC
      By default OpenShift applications prepare, distribute, and activate deployments
      on every git push. Alternatively, a user may choose to disable automatic
      deployments and use 'rhc deploy' and 'rhc deployment' commands to fully control the
      deployment lifecycle.

      Use this command to prepare, distribute and deploy manually from a git reference
      (commit id, tag or branch) or from a binary file. Check also 'rhc configure-app'
      to configure your application to deploy manually and set the number of deployments
      to keep in history.

      DESC
    takes_application
    argument :ref, "Git tag, branch or commit id or path to binary file to be deployed", ["--ref REF"], :optional => false
    option "--[no-]hot-deploy", "Perform hot deployment according to the specified argument rather than checking for the presence of the hot_deploy marker in the application git repo"
    option "--[no-]force-clean-build", "Perform a clean build according to the specified argument rather than checking for the presence of the force_clean_build marker in the application git repo"
    alias_action :"deploy", :root_command => true
    def deploy(ref)
      rest_app = find_app

      raise RHC::DeploymentsNotSupportedException.new if !rest_app.supports? "DEPLOY"

      deploy_artifact(rest_app, ref, options.hot_deploy, options.force_clean_build)

      0
    end

    summary "Configure several properties that apply to an application"
    syntax "<app> [--[no-]auto-deploy] [--keep-deployments INTEGER] [--deployment-branch BRANCH] [--deployment-type TYPE] [--namespace NAME]"
    takes_application :argument => true
    option ["--[no-]auto-deploy"], "Build and deploy automatically when pushing to the git repo. Defaults to true."
    option ["--keep-deployments INTEGER", Integer], "Number of deployments to preserve. Defaults to 1."
    option ["--deployment-branch BRANCH"], "Which branch should trigger an automatic deployment, if automatic deployment is enabled with --auto-deploy. Defaults to master."
    option ["--deployment-type git|binary"], "Type of deployment the application accepts ('git' or 'binary'). Defaults to git."
    def configure(app_name)
      rest_app = find_app

      app_options = {}
      app_options[:auto_deploy] = options.auto_deploy if !options.auto_deploy.nil?
      app_options[:keep_deployments] = options.keep_deployments if options.keep_deployments
      app_options[:deployment_branch] = options.deployment_branch if options.deployment_branch
      app_options[:deployment_type] = options.deployment_type if options.deployment_type

      if app_options.present?
        paragraph do
          say "Configuring application '#{app_name}' ... "
          rest_app.configure(app_options)
          success "done"
        end
      end

      paragraph { display_app(find_app, nil, [:auto_deploy, :keep_deployments, :deployment_type, :deployment_branch]) }

      paragraph { say "Your application '#{rest_app.name}' is #{app_options.empty? ? '' : 'now '}configured as listed above." }
      paragraph { say "Use 'rhc show-app #{rest_app.name} --configuration' to check your configuration values any time." } if app_options.present?

      0
    end

    private
      include RHC::GitHelpers
      include RHC::CartridgeHelpers
      include RHC::SSHHelpers
      include RHC::DeploymentHelpers

      MAX_RETRIES = 7
      DEFAULT_DELAY_THROTTLE = 2.0

      def require_one_web_cart
        lambda{ |carts|
          match, ambiguous = carts.partition{ |c| not c.is_a?(Array) }
          selected_web = match.any?{ |c| not c.only_in_existing? }
          possible_web = ambiguous.flatten.any?{ |c| not c.only_in_existing? }
          if not (selected_web or possible_web)
            section(:bottom => 1){ list_cartridges(standalone_cartridges) }
            raise RHC::CartridgeNotFoundException, "Every application needs a web cartridge to handle incoming web requests. Please provide the short name of one of the carts listed above."
          end
          if selected_web
            carts.map! &other_carts_only
          elsif possible_web && ambiguous.length == 1
            carts.map! &web_carts_only
          end
        }
      end

      def check_sshkeys!
        return unless interactive?
        RHC::SSHWizard.new(rest_client, config, options).run
      end

      def check_name!(name)
        return unless name.blank?

        paragraph{ say "When creating an application, you must provide a name and a cartridge from the list below:" }
        paragraph{ list_cartridges(standalone_cartridges) }

        raise ArgumentError, "Please specify the name of the application and the web cartridge to install"
      end

      def check_config!
        return if not interactive? or (!options.clean && config.has_local_config?) or (options.server && (options.rhlogin || options.token))
        RHC::EmbeddedWizard.new(config, options).run
      end

      def check_domain!
        if options.namespace
          rest_client.find_domain(options.namespace)
        else
          if rest_client.domains.empty?
            raise RHC::Rest::DomainNotFoundException, "No domains found. Please create a domain with 'rhc create-domain <namespace>' before creating applications." unless interactive?
            RHC::DomainWizard.new(config, options, rest_client).run
          end
          domain = rest_client.domains.first
          raise RHC::Rest::DomainNotFoundException, "No domains found. Please create a domain with 'rhc create-domain <namespace>' before creating applications." unless domain
          options.namespace = domain.name
          domain
        end
      end

      def gear_group_state(states)
        return states[0] if states.length == 1 || states.uniq.length == 1
        "#{states.select{ |s| s == 'started' }.count}/#{states.length} started"
      end

      def app_action(action, *args)
        rest_app = find_app
        result = rest_app.send action, *args
        result
      end

      def create_app(name, cartridges, rest_domain, gear_profile=nil, scale=nil, from_code=nil, environment_variables=nil, auto_deploy=nil, keep_deployments=nil, deployment_branch=nil, deployment_type=nil, region=nil)
        app_options = {:cartridges => Array(cartridges)}
        app_options[:gear_profile] = gear_profile if gear_profile
        app_options[:scale] = scale if scale
        app_options[:initial_git_url] = from_code if from_code
        app_options[:debug] = true if @debug
        app_options[:environment_variables] = environment_variables.map{|i| i.to_hash}.group_by{|i| i[:name]}.values.map(&:last) if environment_variables.present?
        app_options[:auto_deploy] = auto_deploy if !auto_deploy.nil?
        app_options[:keep_deployments] = keep_deployments if keep_deployments
        app_options[:deployment_branch] = deployment_branch if deployment_branch
        app_options[:deployment_type] = deployment_type if deployment_type
        app_options[:region] = region if region
        debug "Creating application '#{name}' with these options - #{app_options.inspect}"
        rest_domain.add_application(name, app_options)
      rescue RHC::Rest::Exception => e
        if e.code == 109
          paragraph{ say "Valid cartridge types:" }
          paragraph{ list_cartridges(standalone_cartridges) }
        end
        raise
      end

      def add_jenkins_app(rest_domain)
        create_app(jenkins_app_name, jenkins_cartridge_name, rest_domain)
      end

      def add_jenkins_cartridge(rest_app)
        rest_app.add_cartridge(jenkins_client_cartridge_name)
      end

      def add_jenkins_client_to(rest_app, messages)
        say "Setting up Jenkins build ... "
        successful, attempts, exit_code, exit_message = false, 1, 157, nil
        while (!successful && exit_code == 157 && attempts < MAX_RETRIES)
          begin
            cartridge = add_jenkins_cartridge(rest_app)
            successful = true

            success "done"
            messages.concat(cartridge.messages)

          rescue RHC::Rest::ServerErrorException => e
            if (e.code == 157)
              # error downloading Jenkins /jnlpJars/jenkins-cli.jar
              attempts += 1
              debug "Jenkins server could not be contacted, sleep and then retry: attempt #{attempts}\n    #{e.message}"
              Kernel.sleep(10)
            end
            exit_code = e.code
            exit_message = e.message
          rescue Exception => e
            # timeout and other exceptions
            exit_code = 1
            exit_message = e.message
          end
        end
        unless successful
          warn "not complete"
          add_issue("Jenkins client failed to install - #{exit_message}",
                    "Install the jenkins client",
                    "rhc add-cartridge jenkins-client -a #{rest_app.name}")
        end
      end

      def dns_propagated?(host, sleep_time=2)
        #
        # Confirm that the host exists in DNS
        #
        debug "Start checking for application dns @ '#{host}'"

        found = false

        # Allow DNS to propagate
        Kernel.sleep 5

        # Now start checking for DNS
        host_found = hosts_file_contains?(host) or
        1.upto(MAX_RETRIES) { |i|
          host_found = host_exists?(host)
          break found if host_found

          say "    retry # #{i} - Waiting for DNS: #{host}"
          Kernel.sleep sleep_time.to_i
          sleep_time *= DEFAULT_DELAY_THROTTLE
        }

        debug "End checking for application dns @ '#{host} - found=#{host_found}'"

        host_found
      end

      def enable_jenkins?
        # legacy issue, commander 4.0.x will place the option in the hash with nil value (BZ878407)
        options.__hash__.has_key?(:enable_jenkins)
      end

      def jenkins_app_name
        if options.enable_jenkins.is_a? String
          options.enable_jenkins
        end || "jenkins"
      end

      def jenkins_cartridge_name
        jenkins_cartridges.last.name
      end

      def jenkins_client_cartridge_name
        jenkins_client_cartridges.last.name
      end

      def run_nslookup(host)
        # :nocov:
        `nslookup #{host}`
        $?.exitstatus == 0
        # :nocov:
      end

      def run_ping(host)
        # :nocov:
        `ping #{host} -n 2`
        $?.exitstatus == 0
        # :nocov:
      end

      def windows_nslookup_bug?(rest_app)
        windows_nslookup = run_nslookup(rest_app.host)
        windows_ping = run_ping(rest_app.host)

        if windows_nslookup and !windows_ping # this is related to BZ #826769
          issue = <<WINSOCKISSUE
We were unable to lookup your hostname (#{rest_app.host})
in a reasonable amount of time.  This can happen periodically and may
take up to 10 extra minutes to propagate depending on where you are in the
world. This may also be related to an issue with Winsock on Windows [1][2].
We recommend you wait a few minutes then clone your git repository manually.

[1] http://support.microsoft.com/kb/299357
[2] http://support.microsoft.com/kb/811259
WINSOCKISSUE
          add_issue(issue,
                    "Clone your git repo",
                    "rhc git-clone #{rest_app.name}")

          return true
        end

        false
      end

      def output_issues(rest_app)
        reasons, steps = format_issues(4)
        warn <<WARNING_OUTPUT
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
WARNING:  Your application was created successfully but had problems during
          configuration. Below is a list of the issues and steps you can
          take to complete the configuration of your application.

  Application URL: #{rest_app.app_url}

  Issues:
#{reasons}
  Steps to complete your configuration:
#{steps}
  If you continue to experience problems after completing these steps,
  you can try destroying and recreating the application:

    $ rhc app delete #{rest_app.name} --confirm

  Please contact us if you are unable to successfully create your
  application:

    Support - https://www.openshift.com/support

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

WARNING_OUTPUT
      end

    # Issues collector collects a set of recoverable issues and steps to fix them
    # for output at the end of a complex command
    def add_issue(reason, commands_header, *commands)
      @issues ||= []
      issue = {:reason => reason,
               :commands_header => commands_header,
               :commands => commands}
      @issues << issue
    end

    def format_issues(indent)
      return nil unless issues?

      indentation = " " * indent
      reasons = ""
      steps = ""

      @issues.each_with_index do |issue, i|
        reasons << "#{indentation}#{i+1}. #{issue[:reason].strip}\n"
        steps << "#{indentation}#{i+1}. #{issue[:commands_header].strip}\n"
        issue[:commands].each { |cmd| steps << "#{indentation}  $ #{cmd}\n" }
      end

      [reasons, steps]
    end

    def issues?
      not @issues.nil?
    end

    def temporary_snapshot_filename(app_name)
      "#{Dir.tmpdir}/#{app_name}_temp_clone.tar.gz"
    end
  end
end
