class Visitor < ApplicationRecord
  belongs_to :host, optional: true

  validates :full_name, presence: true
  validates :company_name, presence: true
  validates :purpose, presence: true
  validates :host, presence: true
end
