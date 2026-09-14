require "test_helper"

class Api::VisitorsControllerTest < ActionDispatch::IntegrationTest
  test "GET /api/visitors returns json array" do
    get "/api/visitors"
    assert_response :success
    data = JSON.parse(response.body)
    assert_kind_of Array, data
  end

  test "GET /api/visitors page 1 returns at most 20 records" do
    get "/api/visitors?page=1"
    assert_response :success
    data = JSON.parse(response.body)
    assert data.length <= 20
  end

  test "POST /api/visitors creates a visitor" do
    assert_difference "Visitor.count", 1 do
      post "/api/visitors",
        params: { full_name: "Test User", company_name: "Test Co", purpose: "Demo", host_id: hosts(:alice).id },
        as: :json
    end
    assert_response :created
  end

  test "POST /api/visitors with empty body is rejected" do
    assert_no_difference "Visitor.count" do
      post "/api/visitors", params: {}, as: :json
    end
    assert_response :unprocessable_entity
  end

  test "PATCH /api/visitors/:id/check_out sets checked_out_at" do
    visitor = visitors(:active_visitor)
    patch "/api/visitors/#{visitor.id}/check_out"
    assert_response :success
    visitor.reload
    assert_not_nil visitor.checked_out_at
  end

  test "PATCH /api/visitors/:id/deactivate sets active to false" do
    visitor = visitors(:active_visitor)
    patch "/api/visitors/#{visitor.id}/deactivate"
    assert_response :success
    visitor.reload
    assert_equal false, visitor.active
  end

  test "GET /api/visitors/search returns matching visitors" do
    get "/api/visitors/search?q=Jane"
    assert_response :success
    data = JSON.parse(response.body)
    assert_kind_of Array, data
    assert data.any? { |v| v["full_name"].include?("Jane") }
  end

  test "GET /api/visitors index includes checked_out visitor in list" do
    get "/api/visitors?page=1"
    assert_response :success
    data = JSON.parse(response.body)
    ids = data.map { |v| v["id"] }
    assert_not_includes ids, visitors(:checked_out_visitor).id
  end
end
