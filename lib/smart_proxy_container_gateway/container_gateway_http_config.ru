require 'smart_proxy_container_gateway/container_gateway_api'
require 'smart_proxy_container_gateway/profiling'

use Proxy::ContainerGateway::Profiling::Middleware

map '/container_gateway' do
  run Proxy::ContainerGateway::Api
end
