module OverSIP::SIP

  module Modules
    module Core

      # Create a server transaction for the incoming request.
      def create_transaction
        case @sip_method
        when :INVITE
          ::OverSIP::SIP::InviteServerTransaction.new self
        when :ACK
        when :CANCEL
        else
          ::OverSIP::SIP::NonInviteServerTransaction.new self
        end
      end


      def check_max_forwards max_forwards
        if @max_forwards
          unless @max_forwards.zero?
            @new_max_forwards = ( @max_forwards > max_forwards ? max_forwards : @max_forwards - 1 )
            return true
          else
            log_system_notice "Max-Forwards is 0 => 483"
            reply 483
            return false
          end
        else
          @new_max_forwards = max_forwards
          return true
        end
      end


      def loose_route
        num_removes = 0
        has_preloaded_route_with_ob_param = false

        # Remove all the Route's pointing to the proxy until a Route not pointing to us is found.
        if @routes
          @routes.each do |route|
            if ::OverSIP::SIP::Tags.check_value_for_route_ovid(route.ovid_param)
              num_removes += 1
            else
              if local_uri? route
                log_system_debug "removing pre-loaded Route pointing to this server"  if $oversip_debug
                has_preloaded_route_with_ob_param = true  if route.ob_param?
                num_removes += 1
              else
                break
              end
            end
          end
        end

        ### Outbound stuf. RFC 5626 section 5.3.

        # Outgoing initial request asking for Outbound. Just valid when:
        # - It's an initial request.
        # - Single Via (so there is no a proxy in front of us).
        # - It's an INVITE, REGISTER, SUBSCRIBE or REFER request.
        # - Has a preloaded top Route with ;ob param pointing to us, or has Contact with ;ob, or
        #   it's a REGISTER with ;+sip.instance.
        #
        # TODO: and (has_preloaded_route_with_ob_param or @request.contact.ob_param?).
        # TODO: For REGISTER check also ;+sip.instance Contact param.
        if (
              @force_outgoing_outbound or (
                initial? and
                @num_vias == 1 and
                outbound_aware? and
                has_preloaded_route_with_ob_param
              )
            )
          @outgoing_outbound_requested = true
          log_system_debug "applying outgoing Outbound support"  if $oversip_debug
        end

        # Incoming initial request or in-dialog incoming/outgoing request. Must only perform
        # Outbound for the incoming case and just when:
        # - There are 2 Route headers.
        # - All the Route headers point to us.
        # - The latest Route has a flow token and a valid ;ovid param (so has been generated
        #   previously by us).
        #     NOTE: But don't check its value so it still would work in case of server reboot.
        # - It's an incoming Outbound request (so flow token in the Route does not match the
        #   flow token of the incoming connection).
        if (
              num_removes == 2 and
              @routes.size == 2 and
              (outbound_route = @routes.last) and
              outbound_route.ovid_param and
              (@route_outbound_flow_token = outbound_route.user) != @connection_outbound_flow_token
            )
          @incoming_outbound_requested = true
          log_system_debug "destination is an incoming Outbound connection"  if $oversip_debug
        end

        # If there are not Route headers return false.
        return false  unless @routes

        # Remove the Route values pointintg to us.
        unless num_removes == 0
          @headers["Route"].shift num_removes
          @routes.shift num_removes
        end
        @routes.empty? and @routes = nil

        # Return true if it is an in-dialog request and at least one top Route pointed to us.
        # False otherwise as we shouldn't receive an in-dialog request with a top Route non
        # pointing to us.
        if in_dialog?
          return ( num_removes > 0 ? true : false )
        # Return true if it was an initial request and more Route headers remain after inspection.
        elsif @routes
          return true
        # Return false if it was an initial request and all its Route headers pointed to the proxy.
        else
          return false
        end
      end


      # Mira si el RURI es local. Se supone que antes se ha validado el Route y que el script
      # no permite pre-loaded Route a otro destino..
      def destination_myself?
        return true if @destination_myself
        return false if @destination_myself == false

        if local_uri? @ruri
          log_system_debug "RURI destination is myself"  if $oversip_debug
          return @destination_myself = true
        else
          log_system_debug "RURI destination is not myself"  if $oversip_debug
          return @destination_myself = false
        end
      end


      def fix_nat
        # Force rport usage for UDP clients.
        @via_rport = @source_port

        # Force outgoing Outbound.
        if initial? and @num_vias == 1 and outbound_aware?
          @force_outgoing_outbound = true
        end
      end


      # TODO: It must be true if top Route or Contact has ;ob param, or also if the Contact
      # has +sip.instance.
      def outgoing_outbound_requested?       ; @outgoing_outbound_requested  end

      def incoming_outbound_requested?       ; @incoming_outbound_requested  end


      def connection_outbound_flow_token
        @connection_outbound_flow_token ||= if @transport == :udp
          # NOTE: Add "_" so later we can figure that this is for UDP.
          # NOTE: Replace "=" with "-" so it can be added as a SIP URI param (when Contact mangling is used
          # if the registrar does not support Path).
          "_" << ::Base64.strict_encode64("#{@source_ip}_#{@source_port}").gsub(/=/,"-")
        else
          @connection.outbound_flow_token
        end
      end


      private


      def local_uri? uri
        # NOTE: uri.host has been normalized during parsing in case it's an IPv6 and it's
        # an :ipv6_reference.
        ( uri.port and ::OverSIP::SIP.local_aliases["#{uri.host}:#{uri.port}"] ) or
        ( not uri.port and ::OverSIP::SIP.local_aliases[uri.host] )
      end

    end  # module Core
  end  # module Modules


  class Request
    include ::OverSIP::SIP::Modules::Core
  end

end
