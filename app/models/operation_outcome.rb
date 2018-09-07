# frozen_string_literal: true

class OperationOutcome < ApplicationRecord
  include CuratedModel
  belongs_to :profile
  after_find do |oo| # rubocop:disable Style/SymbolProc # rubocop's suggestion here breaks it
    oo.find_diagnostics
  end

  def target
    @target ||= @target_class.find_by(resource_id: @target_id)
  end

  def conflict
    @conflict ||= @conflict_class.find_by(id: @conflict_id)
  end

  def compare
    comparison = {}
    location = fhir_model.issue[0].location

    left = target.resource
    right = conflict.resource

    if location.is_a? String
      comparison[location] = { left: get_value(left, location), right: get_value(right, location) }
    else
      location.each { |l| comparison[l] = { left: get_value(left, l), right: get_value(right, l) } }
    end

    comparison
  end

  def get_value(hash, path)
    # path defines a place in the object tree, fields or indices separated by .
    value = hash

    path.split('.').each do |key|
      key = key.to_i if value.is_a? Array
      value = value[key]
      return nil if value.nil?
    end

    value
  end

  def find_diagnostics
    description = fhir_model.issue[0].diagnostics
    # format is target_type:id;conflict_type:id
    fields = description.split(/[;:]/)

    # only cache these in vars for now, don't make the DB call until actually needed
    @target_class = fields[0].constantize
    @target_id = fields[1]

    @conflict_class = fields[2].constantize
    @conflict_id = fields[3]
  end
end
