# frozen_string_literal: true

module Api
  module V1
    class BaseController < ApiController
      def process_message
        # identify provider based on the token
        allowed_user = nil
        # I believe this needs to be declared here to set its scope to the top function level
        provider = nil
        if doorkeeper_token.application_id.nil?
          # Assume a user token
          if doorkeeper_token.resource_owner_id.nil?
            return render json: { 'error': 'Invalid token.' }, status: :forbidden
          end
          allowed_user = User.find_by(id: doorkeeper_token.resource_owner_id)
          if allowed_user.nil?
            return render json: { 'error': 'Invalid token.' }, status: :forbidden
          end
          provider = find_self_provider
        else
          provider = ProviderApplication.find_by(application_id: doorkeeper_token.application_id).provider
        end

        bundle_json = request.body.read
        bundle = FHIR::Json.from_json(bundle_json)

        profile_id = find_profile_id(bundle)
        profile = Profile.find(profile_id)
        if profile.user_id != allowed_user.id
          return render json: { 'error': 'User account cannot write to the given profile.' }, status: :forbidden
        end

        dr = DataReceipt.new(profile: profile,
                             provider: provider,
                             data: bundle_json,
                             data_type: 'fhir_bundle_edr')
        dr.save!

        # run the sync job asynchronously, so the request returns quickly
        # set fetch = false, so that it doesn't fetch, it only processes the things we added
        SyncProfileJob.perform_later(profile, false)

        response = build_response(bundle)

        render json: response.to_json, status: :ok
      end

      private

      def find_profile_id(bundle)
        params = bundle.entry.find { |e| e.resource.resourceType == 'Parameters' }.resource
        params.parameter.find { |p| p.name == 'health_data_manager_profile_id' }.value
      end

      # This looks up the self provider. There should only be one, but if there are multiple, it
      # returns the one with the lowest ID. If none exist in the database, this raises an error.
      def find_self_provider
        self_provider = Provider.where(provider_type: 'self').order(:id).first
        if self_provider.nil?
          raise ActiveRecord::RecordNotFound.new('Unable to locate the "self" provider - a provider of type "self" should exist', 'Provider')
        end
        self_provider
      end

      def build_response(bundle)
        original_message = bundle.entry[0].resource

        message_header = { 'resourceType' => 'MessageHeader',
                           'timestamp' => Time.now.iso8601,
                           'event' => { 'system' => 'urn:health_data_manager', 'code' => 'EDR', 'display' => 'Encounter Data Receipt' },
                           'source' => { 'name' => 'Rosie', 'endpoint' => 'urn:health_data_manager' },
                           'response' => { 'identifier' => original_message.id, 'code' => 'ok' } }

        FHIR::Bundle.new('type' => 'message',
                         'entry' => [{ 'resource' => message_header }])
      end
    end
  end
end
