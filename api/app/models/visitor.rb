class Visitor < ApplicationRecord
  belongs_to :host, optional: true

  validates :full_name, presence: true
  validates :company_name, presence: true
  validates :purpose, presence: true
  validates :host, presence: true
  validate :host_exists

  private

  def host_exists
    return if host_id.blank? || Host.exists?(id: host_id)

    errors.add(:host_id, "must reference an existing host")
  end
end
