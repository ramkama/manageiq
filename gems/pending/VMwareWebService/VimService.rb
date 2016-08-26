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
      :rev      => '6.0',
      :ssl      => true
    }

    @vim     = RbVmomi::VIM.new vim_opts
    @vim.rev = @vim.serviceContent.about.apiVersion

    @serviceInstanceMor = @vim.serviceInstance
    @sic                = @vim.serviceContent

    @about           = @sic.about
    @apiVersion      = @about.apiVersion
    @v20             = @apiVersion =~ /2\.0\..*/
    @v2              = @apiVersion =~ /2\..*/
    @v4              = @apiVersion =~ /4\..*/
    @isVirtualCenter = @about.apiType == "VirtualCenter"
  end

  def retrievePropertiesIter(specSet, opts = {})
    options = RbVmomi::VIM::RetrieveOptions(:maxObjects => opts[:max_objects])

    result = @vim.propertyCollector.RetrievePropertiesEx(:specSet => specSet, :options => options)
    return if result.nil?

    while result
      begin
        result.objects.to_a.each { |oc| yield oc }
      rescue
        if result.token
          @vim.propertyCollector.CancelRetrievePropertiesEx(:token => result.token)
        end
      end

      break if result.token.nil?

      result = @vim.propertyCollector.ContinueRetrievePropertiesEx(:token => result.token)
    end
  end

  def retrieveProperties(specSet, options = {})
    objects = []

    retrievePropertiesIter(specSet, options) do |object|
      objects << object
    end

    objects
  end
end
