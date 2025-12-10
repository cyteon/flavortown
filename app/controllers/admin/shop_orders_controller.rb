class Admin::ShopOrdersController < Admin::ApplicationController
  before_action :set_paper_trail_whodunnit
  def index
    # Determine view mode
    @view = params[:view] || "shop_orders"

    # Fulfillment team can only access fulfillment view
    if current_user.fulfillment_person? && !current_user.admin?
      if @view != "fulfillment"
        authorize :admin, :access_fulfillment_view?  # Will raise NotAuthorized
      end
      authorize :admin, :access_fulfillment_view?
    else
      authorize :admin, :access_shop_orders?
    end

    # Base query
    orders = ShopOrder.includes(:shop_item, :user, :accessory_orders)

    # Apply view-specific scopes
    case @view
    when "shop_orders"
      # Show pending, rejected, on_hold
      orders = orders.where(aasm_state: %w[pending rejected on_hold])
    when "fulfillment"
      # Show awaiting_periodical_fulfillment and fulfilled
      orders = orders.where(aasm_state: %w[awaiting_periodical_fulfillment fulfilled])
    end

    # Apply filters
    orders = orders.where(shop_item_id: params[:shop_item_id]) if params[:shop_item_id].present?

    # Set default status for fraud dept
    @default_status = "pending" if current_user.fraud_dept? && !current_user.admin?
    status_filter = params[:status].presence || @default_status
    orders = orders.where(aasm_state: status_filter) if status_filter.present?
    orders = orders.where("created_at >= ?", params[:date_from]) if params[:date_from].present?
    orders = orders.where("created_at <= ?", params[:date_to]) if params[:date_to].present?

    if params[:user_search].present?
      search = "%#{params[:user_search]}%"
      orders = orders.joins(:user).where("users.display_name ILIKE ? OR users.email ILIKE ?", search, search)
    end

    # Calculate stats before region filter (for database queries)
    stats_orders = orders
    @c = {
      pending: stats_orders.where(aasm_state: "pending").count,
      awaiting_fulfillment: stats_orders.where(aasm_state: "awaiting_periodical_fulfillment").count,
      fulfilled: stats_orders.where(aasm_state: "fulfilled").count,
      rejected: stats_orders.where(aasm_state: "rejected").count,
      on_hold: stats_orders.where(aasm_state: "on_hold").count
    }

    # Calculate average times
    fulfilled_orders = stats_orders.where(aasm_state: "fulfilled").where.not(fulfilled_at: nil)
    if fulfilled_orders.any?
      @f = fulfilled_orders.average("EXTRACT(EPOCH FROM (shop_orders.fulfilled_at - shop_orders.created_at))").to_f
    end

    # Leaderboard data
    @fulfilled_leaderboard = build_fulfilled_leaderboard
    @approved_leaderboard = build_approved_leaderboard

    # Apply region filter after stats calculation (converts to array)
    if current_user.fulfillment_person? && !current_user.admin? && current_user.region.present?
      orders = orders.to_a.select do |order|
        if order.frozen_address.present?
          order_region = Shop::Regionalizable.country_to_region(order.frozen_address["country"])
          order_region == current_user.region
        else
          false
        end
      end
    elsif params[:region].present?
      orders = orders.to_a.select do |order|
        if order.frozen_address.present?
          order_region = Shop::Regionalizable.country_to_region(order.frozen_address["country"])
          order_region == params[:region].upcase
        else
          false
        end
      end
    end

    # Sorting
    case params[:sort]
    when "id_asc"
      orders = orders.order(id: :asc)
    when "id_desc"
      orders = orders.order(id: :desc)
    when "created_at_asc"
      orders = orders.order(created_at: :asc)
    when "shells_asc"
      orders = orders.order(frozen_item_price: :asc)
    when "shells_desc"
      orders = orders.order(frozen_item_price: :desc)
    else
      orders = orders.order(created_at: :desc)
    end

    # Grouping
    if params[:goob] == "true"
      @grouped_orders = orders.group_by(&:user).map do |user, user_orders|
        {
          user: user,
          orders: user_orders,
          total_items: user_orders.sum(&:quantity),
          total_shells: user_orders.sum { |o| o.total_cost || 0 },
          address: user_orders.first&.decrypted_address_for(current_user)
        }
      end
    else
      @shop_orders = orders
    end
  end

  def show
    if current_user.fulfillment_person? && !current_user.admin?
      authorize :admin, :access_fulfillment_view?
    else
      authorize :admin, :access_shop_orders?
    end
    @order = ShopOrder.find(params[:id])
    @can_view_address = @order.can_view_address?(current_user)

    # Load user's order history for fraud dept or order review
    @user_orders = @order.user.shop_orders.where.not(id: @order.id).order(created_at: :desc).limit(10)

    # User's shop orders summary stats
    user_orders = @order.user.shop_orders
    @user_order_stats = {
      total: user_orders.count,
      fulfilled: user_orders.where(aasm_state: "fulfilled").count,
      pending: user_orders.where(aasm_state: "pending").count,
      rejected: user_orders.where(aasm_state: "rejected").count,
      total_quantity: user_orders.sum(:quantity),
      on_hold: user_orders.where(aasm_state: "on_hold").count,
      awaiting_fulfillment: user_orders.where(aasm_state: "awaiting_periodical_fulfillment").count
    }
  end

  def reveal_address
    if current_user.fulfillment_person? && !current_user.admin?
      authorize :admin, :access_fulfillment_view?
    else
      authorize :admin, :access_shop_orders?
    end
    @order = ShopOrder.find(params[:id])

    if @order.can_view_address?(current_user)
      @decrypted_address = @order.decrypted_address_for(current_user)
      render turbo_stream: turbo_stream.replace(
        "address-content",
        partial: "address_details",
        locals: { address: @decrypted_address }
      )
    else
      render plain: "Unauthorized", status: :forbidden
    end
  end

  def approve
    authorize :admin, :access_shop_orders?
    @order = ShopOrder.find(params[:id])
    old_state = @order.aasm_state

    if @order.shop_item.respond_to?(:fulfill!)
      @order.approve!
      redirect_to admin_shop_orders_path, notice: "Order approved and fulfilled" and return
    end

    if @order.queue_for_fulfillment && @order.save
      PaperTrail::Version.create!(
        item_type: "ShopOrder",
        item_id: @order.id,
        event: "update",
        whodunnit: current_user.id,
        object_changes: {
          aasm_state: [ old_state, @order.aasm_state ]
        }.to_yaml
      )
      redirect_to admin_shop_orders_path, notice: "Order approved for fulfillment"
    else
      redirect_to admin_shop_order_path(@order), alert: "Failed to approve order: #{@order.errors.full_messages.join(', ')}"
    end
  end

  def reject
    authorize :admin, :access_shop_orders?
    @order = ShopOrder.find(params[:id])
    reason = params[:reason].presence || "No reason provided"
    old_state = @order.aasm_state

    if @order.mark_rejected(reason) && @order.save
      PaperTrail::Version.create!(
        item_type: "ShopOrder",
        item_id: @order.id,
        event: "update",
        whodunnit: current_user.id,
        object_changes: {
          aasm_state: [ old_state, @order.aasm_state ],
          rejection_reason: [ nil, reason ]
        }.to_yaml
      )
      redirect_to admin_shop_orders_path, notice: "Order rejected"
    else
      redirect_to admin_shop_order_path(@order), alert: "Failed to reject order: #{@order.errors.full_messages.join(', ')}"
    end
  end

  def place_on_hold
    authorize :admin, :access_shop_orders?
    @order = ShopOrder.find(params[:id])
    old_state = @order.aasm_state

    if @order.place_on_hold && @order.save
      PaperTrail::Version.create!(
        item_type: "ShopOrder",
        item_id: @order.id,
        event: "update",
        whodunnit: current_user.id,
        object_changes: {
          aasm_state: [ old_state, @order.aasm_state ]
        }.to_yaml
      )
      redirect_to admin_shop_orders_path, notice: "Order placed on hold"
    else
      redirect_to admin_shop_order_path(@order), alert: "Failed to place order on hold: #{@order.errors.full_messages.join(', ')}"
    end
  end

  def release_from_hold
    authorize :admin, :access_shop_orders?
    @order = ShopOrder.find(params[:id])
    old_state = @order.aasm_state

    if @order.take_off_hold && @order.save
      PaperTrail::Version.create!(
        item_type: "ShopOrder",
        item_id: @order.id,
        event: "update",
        whodunnit: current_user.id,
        object_changes: {
          aasm_state: [ old_state, @order.aasm_state ]
        }.to_yaml
      )
      redirect_to admin_shop_orders_path, notice: "Order released from hold"
    else
      redirect_to admin_shop_order_path(@order), alert: "Failed to release order from hold: #{@order.errors.full_messages.join(', ')}"
    end
  end

  def mark_fulfilled
    if current_user.fulfillment_person? && !current_user.admin?
      authorize :admin, :access_fulfillment_view?
    else
      authorize :admin, :access_shop_orders?
    end
    @order = ShopOrder.find(params[:id])
    old_state = @order.aasm_state

    if @order.mark_fulfilled && @order.save
      PaperTrail::Version.create!(
        item_type: "ShopOrder",
        item_id: @order.id,
        event: "update",
        whodunnit: current_user.id,
        object_changes: {
          aasm_state: [ old_state, @order.aasm_state ]
        }.to_yaml
      )
      redirect_to admin_shop_order_path(@order), notice: "Order marked as fulfilled"
    else
      redirect_to admin_shop_order_path(@order), alert: "Failed to mark order as fulfilled: #{@order.errors.full_messages.join(', ')}"
    end
  end

  def update_internal_notes
    if current_user.fulfillment_person? && !current_user.admin?
      authorize :admin, :access_fulfillment_view?
    else
      authorize :admin, :access_shop_orders?
    end
    @order = ShopOrder.find(params[:id])
    old_notes = @order.internal_notes

    if @order.update(internal_notes: params[:internal_notes])
      PaperTrail::Version.create!(
        item_type: "ShopOrder",
        item_id: @order.id,
        event: "update",
        whodunnit: current_user.id,
        object_changes: {
          internal_notes: [ old_notes, @order.internal_notes ]
        }.to_yaml
      )
      redirect_to admin_shop_order_path(@order), notice: "Internal notes updated"
    else
      redirect_to admin_shop_order_path(@order), alert: "Failed to update notes"
    end
  end

  private

  def build_fulfilled_leaderboard
    fulfilled_counts = ShopOrder
      .where(aasm_state: "fulfilled")
      .where.not(fulfilled_by: [ nil, "" ])
      .group(:fulfilled_by)
      .count

    build_leaderboard_with_position(fulfilled_counts, current_user.id.to_s)
  end

  def build_approved_leaderboard
    approved_counts = PaperTrail::Version
      .where(item_type: "ShopOrder", event: "update")
      .where("object_changes LIKE ?", "%awaiting_periodical_fulfillment%")
      .where.not(whodunnit: [ nil, "" ])
      .group(:whodunnit)
      .count

    build_leaderboard_with_position(approved_counts, current_user.id.to_s)
  end

  def build_leaderboard_with_position(counts, current_user_id)
    sorted = counts.sort_by { |_, count| -count }
    top_10 = sorted.first(10)

    current_user_position = sorted.find_index { |user_id, _| user_id.to_s == current_user_id }
    current_user_count = counts[current_user_id] || counts[current_user_id.to_i] || 0

    user_ids = top_10.map { |id, _| id.to_i }
    user_ids << current_user_id.to_i if current_user_position && current_user_position >= 10
    users_by_id = User.where(id: user_ids).index_by { |u| u.id.to_s }

    leaderboard = top_10.each_with_index.map do |(user_id, count), index|
      user = users_by_id[user_id.to_s]
      {
        rank: index + 1,
        user_id: user_id,
        display_name: user&.display_name || "User ##{user_id}",
        count: count,
        is_current_user: user_id.to_s == current_user_id
      }
    end

    {
      top_10: leaderboard,
      current_user: {
        rank: current_user_position ? current_user_position + 1 : nil,
        count: current_user_count,
        in_top_10: current_user_position.present? && current_user_position < 10
      }
    }
  end
end
