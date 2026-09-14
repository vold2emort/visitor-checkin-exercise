module Api
  class VisitorsController < ApplicationController
    PER_PAGE = 20

    def index
      page = (params[:page] || 1).to_i
      visitors = Visitor.where(active: true, checked_out_at: nil)
                        .order(:id)
                        .offset((page - 1) * PER_PAGE)
                        .limit(PER_PAGE)

      render json: visitors.map { |v| serialize(v) }
    end

    def create
      visitor = Visitor.new(visitor_params)
      visitor.checked_in_at = Time.current
      if visitor.save
        render json: serialize(visitor), status: :created
      else
        render json: { errors: visitor.errors }, status: :unprocessable_entity
      end
    end

    def check_out
      visitor = Visitor.find(params[:id])
      visitor.update!(checked_out_at: Time.current)
      render json: serialize(visitor)
    end

    def deactivate
      visitor = Visitor.find(params[:id])
      visitor.update!(active: false)
      render json: serialize(visitor)
    end

    def search
      q = params[:q].to_s.strip
      visitors = Visitor.where(active: true)
                        .where("full_name LIKE ?", "%#{q}%")
                        .order(:full_name)
                        .limit(10)
      render json: visitors.map { |v| { id: v.id, full_name: v.full_name, company_name: v.company_name, host_id: v.host_id } }
    end

    private

    def visitor_params
      params.permit(:full_name, :company_name, :purpose, :host_id)
    end

    def serialize(visitor)
      {
        id: visitor.id,
        full_name: visitor.full_name,
        company_name: visitor.company_name,
        purpose: visitor.purpose,
        checked_in_at: visitor.checked_in_at&.iso8601,
        checked_out_at: visitor.checked_out_at&.iso8601,
        active: visitor.active,
        host_id: visitor.host_id,
        host_name: visitor.host&.name
      }
    end
  end
end
