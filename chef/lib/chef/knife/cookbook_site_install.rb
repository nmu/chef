#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2010 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/knife'
require 'chef/mixin/shell_out'

class Chef
  class Knife
    class CookbookRepo

      DIRTY_REPO = /^[\s]+M/

      include Chef::Mixin::ShellOut

      attr_reader :repo_path
      attr_reader :default_branch
      attr_reader :ui

      def initialize(repo_path, ui, opts={})
        @repo_path = repo_path
        @ui = ui
        @default_branch = 'master'
      end

      def sanity_check
        unless ::File.directory?(repo_path)
          ui.error("The cookbook repo path #{repo_path} does not exist or is not a directory")
          exit 1
        end
        unless git_repo?(repo_path)
          ui.error "The cookbook repo #{repo_path} is not a git repository."
          ui.info("Use `git init` to initialize a git repo")
          exit 1
        end
        unless branch_exists?(default_branch)
          ui.error "You default branch '#{default_branch}' does not exist"
          ui.info "If this is a new git repo, make sure you have at least one commit before installing cookbooks"
          exit 1
        end
        cmd = git('status --porcelain')
        if cmd.stdout =~ DIRTY_REPO
          ui.error "You have uncommitted changes to your cookbook repo (#{repo_path}):"
          ui.msg cmd.stdout
          ui.info "Commit or stash your changes before importing cookbooks"
          exit 1
        end
        # TODO: any untracked files in the cookbook directory will get nuked later
        # make this an error condition also.
        true
      end

      def reset_to_default_state
        ui.info("Checking out the #{default_branch} branch.")
        git("checkout #{default_branch}")
      end

      def prepare_to_import(cookbook_name)
        branch = "chef-vendor-#{cookbook_name}"
        if branch_exists?(branch)
          ui.info("Pristine copy branch (#{branch}) exists, switching to it.")
          git("checkout #{branch}")
        else
          ui.info("Creating pristine copy branch #{branch}")
          git("checkout -b #{branch}")
        end
      end

      def finalize_updates_to(cookbook_name, version)
        if update_count = updated?(cookbook_name)
          ui.info "#{update_count} files updated, committing changes"
          git("add #{cookbook_name}")
          git("commit -m 'Import #{cookbook_name} version #{version}' -- #{cookbook_name}")
          ui.info("Creating tag cookbook-site-imported-#{cookbook_name}-#{version}")
          git("tag -f cookbook-site-imported-#{cookbook_name}-#{version}")
          true
        else
          ui.info("No changes made to #{cookbook_name}")
          false
        end
      end

      def merge_updates_from(cookbook_name, version)
        branch = "chef-vendor-#{cookbook_name}"
        Dir.chdir(repo_path) do
          if system("git merge #{branch}")
            ui.info("Cookbook #{cookbook_name} version #{version} successfully installed")
          else
            ui.error("You have merge conflicts - please resolve manually")
            ui.info("Merge status (cd #{repo_path}; git status):")
            system("git status")
            exit 3
          end
        end
      end

      def updated?(cookbook_name)
        update_count = git("status --porcelain -- #{cookbook_name}").stdout.strip.lines.count
        update_count == 0 ? nil : update_count
      end

      def branch_exists?(branch_name)
        git("branch --no-color").stdout.lines.any? {|l| l.include?(branch_name) }
      end

      private

      def git_repo?(directory)
        if File.directory?(File.join(directory, '.git'))
          return true
        elsif File.dirname(directory) == directory
          return false
        else
          git_repo?(File.dirname(directory))
        end
      end

      def apply_opts(opts)
        opts.each do |option, value|
          case option.to_s
          when 'default_branch'
            @default_branch = value
          else
            raise ArgumentError, "invalid option `#{option}' passed to CookbookRepo.new()"
          end
        end
      end

      def git(command)
        shell_out!("git #{command}", :cwd => repo_path)
      end

    end

    class CookbookSiteInstall < Knife

      deps do
        require 'chef/mixin/shell_out'
        require 'chef/cookbook/metadata'
      end

      banner "knife cookbook site vendor COOKBOOK [VERSION] (options)"
      category "cookbook site"

      option :deps,
       :short => "-d",
       :long => "--dependencies",
       :boolean => true,
       :description => "Grab dependencies automatically"

      option :cookbook_path,
        :short => "-o PATH:PATH",
        :long => "--cookbook-path PATH:PATH",
        :description => "A colon-separated path to look for cookbooks in",
        :proc => lambda { |o| o.split(":") }

      option :branch_default,
        :short => "-B BRANCH",
        :long => "--branch BRANCH",
        :description => "Default branch to work with",
        :default => "master"

      attr_reader :cookbook_name
      attr_reader :vendor_path

      def run
        extend Chef::Mixin::ShellOut

        if config[:cookbook_path]
          Chef::Config[:cookbook_path] = config[:cookbook_path]
        else
          config[:cookbook_path] = Chef::Config[:cookbook_path]
        end

        @cookbook_name = parse_name_args!
        # Check to ensure we have a valid source of cookbooks before continuing
        #
        @install_path = config[:cookbook_path].first
        ui.info "Installing #@cookbook_name to #{@install_path}"

        @repo = CookbookRepo.new(@install_path, ui, config)
        #cookbook_path = File.join(vendor_path, name_args[0])
        upstream_file = File.join(@install_path, "#{@cookbook_name}.tar.gz")

        @repo.sanity_check
        @repo.reset_to_default_state
        @repo.prepare_to_import(@cookbook_name)

        downloader = download_cookbook_to(upstream_file)
        clear_existing_files(File.join(@install_path, @cookbook_name))
        extract_cookbook(upstream_file, @install_path)

        # TODO: it'd be better to store these outside the cookbook repo and
        # keep them around, e.g., in ~/Library/Caches on OS X.
        ui.info("removing downloaded tarball")
        shell_out!("rm #{upstream_file}", :cwd => vendor_path)

        if @repo.finalize_updates_to(@cookbook_name, downloader.version)
          @repo.reset_to_default_state
          @repo.merge_updates_from(@cookbook_name, downloader.version)
        else
          @repo.reset_to_default_state
        end


        if config[:deps]
          md = Chef::Cookbook::Metadata.new
          md.from_file(File.join(cookbook_path, "metadata.rb"))
          md.dependencies.each do |cookbook, version_list|
            # Doesn't do versions.. yet
            nv = Chef::Knife::CookbookSiteVendor.new
            nv.config = config
            nv.name_args = [ cookbook ]
            nv.run
          end
        end
      end

      def parse_name_args!
        if name_args.empty?
          ui.error("please specify a cookbook to download and install")
          exit 1
        elsif name_args.size > 1
          ui.error("Installing multiple cookbooks at once is not supported")
          exit 1
        else
          name_args.first
        end
      end

      def download_cookbook_to(download_path)
        downloader = Chef::Knife::CookbookSiteDownload.new
        downloader.config[:file] = download_path
        downloader.name_args = name_args
        downloader.run
        downloader
      end

      def extract_cookbook(upstream_file, version)
        ui.info("Uncompressing #{@cookbook_name} version #{version}.")
        shell_out!("tar zxvf #{upstream_file}", :cwd => @install_path)
      end

      def clear_existing_files(cookbook_path)
        ui.info("Removing pre-existing version.")
        shell_out!("rm -r #{cookbook_path}", :cwd => @install_path) if File.directory?(cookbook_path)
      end


    end
  end
end





