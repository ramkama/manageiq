require "rbvmomi"
require 'VMwareWebService/VimTypes'

class VimService
  attr_reader :sic, :about, :apiVersion, :isVirtualCenter, :v20, :v2, :v4, :serviceInstanceMor, :session_cookie

  def initialize(server)
    vim_opts = {
      :host     => server,
      :insecure => true,
      :ns       => 'urn:vim25',
      :path     => '/sdk',
      :port     => 443,
      :rev      => '4.0',
      :ssl      => true
    }

    @vim = RbVmomi::VIM.new vim_opts

    @serviceInstanceMor = @vim.serviceInstance
    @sic                = @vim.serviceContent

    @about           = @sic.about
    @apiVersion      = @about.apiVersion
    @v20             = @apiVersion =~ /2\.0\..*/
    @v2              = @apiVersion =~ /2\..*/
    @v4              = @apiVersion =~ /4\..*/
    @isVirtualCenter = @about.apiType == "VirtualCenter"
  end
end
