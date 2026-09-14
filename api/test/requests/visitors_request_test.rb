require "test_helper"

class Api::VisitorsRequestTest < ActionDispatch::IntegrationTest
  test "deactivated visitors are not returned by the active list or repeat-visit search" do
    deactivated = visitors(:inactive_visitor)
    assert_nil deactivated.checked_out_at, "fixture must represent a deactivated but still checked-in visitor"

    get "/api/visitors?page=1"
    assert_response :success
    ids = JSON.parse(response.body).map { |v| v["id"] }
    refute_includes ids, deactivated.id,
      "deactivated visitor #{deactivated.full_name} must not appear in the active list"

    get "/api/visitors/search?q=Sam"
    assert_response :success
    suggestions = JSON.parse(response.body)
    refute suggestions.any? { |v| v["id"] == deactivated.id },
      "deactivated visitor must not be selectable for a repeat visit"
  end

  test "POST /api/visitors validates required fields and records check-in in Kathmandu time" do
    assert_no_difference "Visitor.count" do
      post "/api/visitors", params: {}, as: :json
    end
    assert_response :unprocessable_entity

    assert_no_difference "Visitor.count" do
      post "/api/visitors",
        params: { full_name: "Jane Doe", company_name: "Acme Corp", purpose: "", host_id: hosts(:alice).id },
        as: :json
    end
    assert_response :unprocessable_entity

    post "/api/visitors",
      params: { full_name: "Jane Doe", company_name: "Acme Corp", purpose: "Demo", host_id: hosts(:alice).id },
      as: :json
    assert_response :created

    created = JSON.parse(response.body)
    check_in_offset = Time.iso8601(created["checked_in_at"]).utc_offset
    assert_equal 5 * 3600 + 45 * 60, check_in_offset,
      "checked_in_at must be serialized in Asia/Kathmandu (+05:45), got #{created["checked_in_at"].inspect}"
  end

  test "GET /api/visitors eager loads hosts instead of issuing an N+1" do
    host = hosts(:alice)
    20.times do |i|
      Visitor.create!(
        full_name: "Query Visitor #{i}",
        company_name: "Acme Corp",
        purpose: "Demo",
        checked_in_at: Time.current,
        checked_out_at: nil,
        active: true,
        host: host
      )
    end

    query_count = 0
    events = ActiveSupport::Notifications.subscribe("sql.active_record") { query_count += 1 }
    get "/api/visitors?page=1"
    ActiveSupport::Notifications.unsubscribe(events)

    assert_response :success
    assert_operator query_count, :<=, 3,
      "expected eager-loaded index (<= 3 SQL statements), but 1 visitor query + 20 host lookups fired #{query_count}"
  end
end
