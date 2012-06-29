require 'spree/core/validators/email'

module Spree
  class Order < ActiveRecord::Base
    require_dependency 'spree/order/state_machine'
    token_resource

    attr_accessible :line_items, :bill_address_attributes, :ship_address_attributes, :payments_attributes,
                    :ship_address, :bill_address, :line_items_attributes, :number,
                    :shipping_method_id, :email, :use_billing, :special_instructions

    if Spree.user_class
      belongs_to :user, :class_name => Spree.user_class.to_s
    else
      belongs_to :user, :class_name => "Spree::User"
    end

    belongs_to :bill_address, :foreign_key => :bill_address_id, :class_name => "Spree::Address"
    alias_attribute :billing_address, :bill_address

    belongs_to :ship_address, :foreign_key => :ship_address_id, :class_name => "Spree::Address"
    alias_attribute :shipping_address, :ship_address

    belongs_to :shipping_method, :class_name => "Spree::ShippingMethod"

    has_many :state_changes, :as => :stateful
    has_many :line_items, :dependent => :destroy
    has_many :inventory_units
    has_many :payments, :dependent => :destroy
    has_many :shipments, :dependent => :destroy
    has_many :return_authorizations, :dependent => :destroy
    has_many :adjustments, :as => :adjustable, :dependent => :destroy, :order => "created_at ASC"

    accepts_nested_attributes_for :line_items
    accepts_nested_attributes_for :bill_address
    accepts_nested_attributes_for :ship_address
    accepts_nested_attributes_for :payments
    accepts_nested_attributes_for :shipments

    # Needs to happen before save_permalink is called
    before_validation :generate_order_number, :on => :create
    before_validation :clone_billing_address, :if => :use_billing?
    attr_accessor :use_billing

    before_create :link_by_email
    after_create :create_tax_charge!

    # TODO: validate the format of the email as well (but we can't rely on authlogic anymore to help with validation)
    validates :email, :presence => true, :email => true, :if => :require_email
    validate :has_available_shipment, :unless => :delivery_required?
    validate :has_available_payment, :unless => :payment_required?

    make_permalink :field => :number

    class_attribute :update_hooks
    self.update_hooks = Set.new

    def self.by_number(number)
      where(:number => number)
    end

    def self.between(start_date, end_date)
      where(:created_at => start_date..end_date)
    end

    def self.by_customer(customer)
      joins(:user).where("#{Spree::User.table_name}.email" => customer)
    end

    def self.by_state(state)
      where(:state => state)
    end

    def self.complete
      where('completed_at IS NOT NULL')
    end

    def self.incomplete
      where(:completed_at => nil)
    end

    # Use this method in other gems that wish to register their own custom logic that should be called after Order#updat
    def self.register_update_hook(hook)
      self.update_hooks.add(hook)
    end

    # For compatiblity with Calculator::PriceSack
    def amount
      line_items.sum(&:amount)
    end

    def to_param
      number.to_s.to_url.upcase
    end

    def completed?
      !! completed_at
    end

    # Indicates whether or not the user is allowed to proceed to checkout.  Currently this is implemented as a
    # check for whether or not there is at least one LineItem in the Order.  Feel free to override this logic
    # in your own application if you require additional steps before allowing a checkout.
    def checkout_allowed?
      line_items.count > 0
    end

    # Indicates the number of items in the order
    def item_count
      line_items.sum(:quantity)
    end

    # Indicates whether there are any backordered InventoryUnits associated with the Order.
    def backordered?
      return false unless Spree::Config[:track_inventory_levels]
      inventory_units.backorder.present?
    end

    # Returns the relevant zone (if any) to be used for taxation purposes.  Uses default tax zone
    # unless there is a specific match
    def tax_zone
      zone_address = Spree::Config[:tax_using_ship_address] ? ship_address : bill_address
      Zone.match(zone_address) || Zone.default_tax
    end

    # Indicates whether tax should be backed out of the price calcualtions in cases where prices
    # include tax but the customer is not required to pay taxes in that case.
    def exclude_tax?
      return false unless Spree::Config[:prices_inc_tax]
      return tax_zone != Zone.default_tax
    end

    # Array of adjustments that are inclusive in the variant price.  Useful for when prices
    # include tax (ex. VAT) and you need to record the tax amount separately.
    def price_adjustments
      adjustments = []

      line_items.each do |line_item|
        adjustments.concat line_item.adjustments
      end

      adjustments
    end

    # Array of totals grouped by Adjustment#label.  Useful for displaying price adjustments on an
    # invoice.  For example, you can display tax breakout for cases where tax is included in price.
    def price_adjustment_totals
      totals = {}

      price_adjustments.each do |adjustment|
        label = adjustment.label
        totals[label] ||= 0
        totals[label] = totals[label] + adjustment.amount
      end

      totals
    end

    # This is a multi-purpose method for processing logic related to changes in the Order.  It is meant to be called from
    # various observers so that the Order is aware of changes that affect totals and other values stored in the Order.
    # This method should never do anything to the Order that results in a save call on the object (otherwise you will end
    # up in an infinite recursion as the associations try to save and then in turn try to call +update!+ again.)
    def update!
      update_totals
      update_payment_state

      # give each of the shipments a chance to update themselves
      if delivery_required?
        shipments.each { |shipment| shipment.update!(self) }#(&:update!)
        update_shipment_state
      end
      update_adjustments
      # update totals a second time in case updated adjustments have an effect on the total
      update_totals

      new_attributes = {
        :payment_state => payment_state,
        :item_total => item_total,
        :adjustment_total => adjustment_total,
        :payment_total => payment_total,
        :total => total
      }

      if delivery_required?
        new_attributes.merge!(:shipment_state => shipment_state)
      end

      update_attributes_without_callbacks(attributes)

      #ensure checkout payment always matches order total
      if payment and payment.checkout? and payment.amount != total
        payment.update_attributes_without_callbacks(:amount => total)
      end

      update_hooks.each { |hook| self.send hook }
    end

    def restore_state
      # pop the resume event so we can see what the event before that was
      state_changes.pop if state_changes.last.name == 'resume'
      update_attribute('state', state_changes.last.previous_state)

      if paid?
        raise 'do something with inventory'
        #Spree::InventoryUnit.assign_opening_inventory(self) if inventory_units.empty?
        #shipment.inventory_units = inventory_units
        #shipment.ready!
      end
    end

    def clone_billing_address
      if bill_address and self.ship_address.nil?
        self.ship_address = bill_address.clone
      else
        self.ship_address.attributes = bill_address.attributes.except('id', 'updated_at', 'created_at')
      end
      true
    end

    def allow_cancel?
      return false unless completed? and state != 'canceled'
      %w{ready backorder pending}.include? shipment_state
    end

    def allow_resume?
      # we shouldn't allow resume for legacy orders b/c we lack the information necessary to restore to a previous state
      return false if state_changes.empty? || state_changes.last.previous_state.nil?
      true
    end

    def add_variant(variant, quantity = 1)
      current_item = find_line_item_by_variant(variant)
      if current_item
        current_item.quantity += quantity
        current_item.save
      else
        current_item = LineItem.new(:quantity => quantity)
        current_item.variant = variant
        current_item.price   = variant.price
        self.line_items << current_item
      end

      self.reload
      current_item
    end

    # Associates the specified user with the order.
    def associate_user!(user)
      self.user = user
      self.email = user.email
      # disable validations since they can cause issues when associating
      # an incomplete address during the address step
      save(:validate => false)
    end

    # FIXME refactor this method and implement validation using validates_* utilities
    def generate_order_number
      record = true
      while record
        random = "R#{Array.new(9){rand(9)}.join}"
        record = self.class.where(:number => random).first
      end
      self.number = random if self.number.blank?
      self.number
    end

    # convenience method since many stores will not allow user to create multiple shipments
    def shipment
      @shipment ||= shipments.last
    end

    def contains?(variant)
      find_line_item_by_variant(variant).present?
    end

    def quantity_of(variant)
      line_item = find_line_item_by_variant(variant)
      line_item ? line_item.quantity : 0
    end

    def find_line_item_by_variant(variant)
      line_items.detect { |line_item| line_item.variant_id == variant.id }
    end

    def ship_total
      adjustments.shipping.map(&:amount).sum
    end

    def tax_total
      adjustments.tax.map(&:amount).sum
    end

    # Clear shipment when transitioning to delivery step of checkout if the
    # current shipping address is not eligible for the existing shipping method
    def remove_invalid_shipments!
      shipments.each { |s| s.destroy unless s.shipping_method.available_to_order?(self) }
    end

    # Creates new tax charges if there are any applicable rates. If prices already
    # include taxes then price adjustments are created instead.
    def create_tax_charge!
      # destroy any previous adjustments (eveything is recalculated from scratch)
      adjustments.tax.each(&:destroy)
      price_adjustments.each(&:destroy)

      TaxRate.match(self).each { |rate| rate.adjust(self) }
    end

    # Creates a new shipment (adjustment is created by shipment model)
    def create_shipment!
      if delivery_required?
        shipping_method(true)
        if shipment.present?
          shipment.update_attributes!(:shipping_method => shipping_method)
        else
          self.shipments << Shipment.create!({ :order => self,
                                            :shipping_method => shipping_method,
                                            :address => self.ship_address,
                                            :inventory_units => self.inventory_units}, :without_protection => true)
        end
      end
    end

    def outstanding_balance
      total - payment_total
    end

    def outstanding_balance?
     self.outstanding_balance != 0
    end

    def name
      if (address = bill_address || ship_address)
        "#{address.firstname} #{address.lastname}"
      end
    end

    def credit_cards
      credit_card_ids = payments.from_credit_card.map(&:source_id).uniq
      CreditCard.scoped(:conditions => { :id => credit_card_ids })
    end

    def process_payments!
      begin
        ret = payments.each(&:process!)
      rescue Core::GatewayError
        !!Spree::Config[:allow_checkout_on_gateway_error]
      end
    end

    # Finalizes an in progress order after checkout is complete.
    # Called after transition to complete state when payments will have been processed
    def finalize!
      update_attribute(:completed_at, Time.now)
      InventoryUnit.assign_opening_inventory(self)
      # lock any optional adjustments (coupon promotions, etc.)
      adjustments.optional.each { |adjustment| adjustment.update_attribute('locked', true) }
      deliver_order_confirmation_email

      self.state_changes.create({
        :previous_state => 'cart',
        :next_state     => 'complete',
        :name           => 'order' ,
        :user_id        => (User.respond_to?(:current) && User.current.try(:id)) || self.user_id
      }, :without_protection => true)
    end

    def deliver_order_confirmation_email
      begin
        OrderMailer.confirm_email(self).deliver
      rescue Exception => e
        logger.error("#{e.class.name}: #{e.message}")
        logger.error(e.backtrace * "\n")
      end
    end

    # Helper methods for checkout steps

    def available_shipping_methods(display_on = nil)
      return [] unless ship_address
      ShippingMethod.all_available(self, display_on)
    end

    def rate_hash
      @rate_hash ||= available_shipping_methods(:front_end).collect do |ship_method|
        next unless cost = ship_method.calculator.compute(self)
        ShippingRate.new( :id => ship_method.id,
                          :shipping_method => ship_method,
                          :name => ship_method.name,
                          :cost => cost)
      end.compact.sort_by { |r| r.cost }
    end

    def paid?
      payment_state == 'paid'
    end

    def payment
      payments.first
    end

    def available_payment_methods
      @available_payment_methods ||= PaymentMethod.available(:front_end)
    end

    def payment_method
      if payment and payment.payment_method
        payment.payment_method
      else
        available_payment_methods.first
      end
    end

    def billing_firstname
      bill_address.try(:firstname)
    end

    def billing_lastname
      bill_address.try(:lastname)
    end

    def products
      line_items.map { |li| li.variant.product }
    end

    def insufficient_stock_lines
      line_items.select &:insufficient_stock?
    end

    def merge!(order)
      order.line_items.each do |line_item|
        self.add_variant(line_item.variant, line_item.quantity)
      end
      order.destroy
    end

    private
      def link_by_email
        self.email = user.email if self.user and not user.anonymous?
      end

      # Updates the +shipment_state+ attribute according to the following logic:
      #
      # shipped   when all Shipments are in the "shipped" state
      # partial   when at least one Shipment has a state of "shipped" and there is another Shipment with a state other than "shipped"
      #           or there are InventoryUnits associated with the order that have a state of "sold" but are not associated with a Shipment.
      # ready     when all Shipments are in the "ready" state
      # backorder when there is backordered inventory associated with an order
      # pending   when all Shipments are in the "pending" state
      #
      # The +shipment_state+ value helps with reporting, etc. since it provides a quick and easy way to locate Orders needing attention.
      def update_shipment_state
        self.shipment_state =
        case shipments.count
        when 0
          nil
        when shipments.shipped.count
          'shipped'
        when shipments.ready.count
          'ready'
        when shipments.pending.count
          'pending'
        else
          'partial'
        end
        self.shipment_state = 'backorder' if backordered?

        if old_shipment_state = self.changed_attributes['shipment_state']
          self.state_changes.create({
            :previous_state => old_shipment_state,
            :next_state     => self.shipment_state,
            :name           => 'shipment',
            :user_id        => (User.respond_to?(:current) && User.current && User.current.id) || self.user_id
          }, :without_protection => true)
        end
      end

      # Updates the +payment_state+ attribute according to the following logic:
      #
      # paid          when +payment_total+ is equal to +total+
      # balance_due   when +payment_total+ is less than +total+
      # credit_owed   when +payment_total+ is greater than +total+
      # failed        when most recent payment is in the failed state
      #
      # The +payment_state+ value helps with reporting, etc. since it provides a quick and easy way to locate Orders needing attention.
      def update_payment_state
        
        #line_item are empty when user empties cart
        if self.line_items.empty? || round_money(payment_total) < round_money(total)
          self.payment_state = 'balance_due'
          self.payment_state = 'failed' if payments.present? and payments.last.state == 'failed'
        elsif round_money(payment_total) > round_money(total)
          self.payment_state = 'credit_owed'
        else
          self.payment_state = 'paid'
        end

        if old_payment_state = self.changed_attributes['payment_state']
          self.state_changes.create({
            :previous_state => old_payment_state,
            :next_state     => self.payment_state,
            :name           => 'payment',
            :user_id        => (User.respond_to?(:current) && User.current && User.current.id) || self.user_id
          }, :without_protection => true)
        end
      end

      def round_money(n)
        (n*100).round / 100.0
      end

      # Updates the following Order total values:
      #
      # +payment_total+      The total value of all finalized Payments (NOTE: non-finalized Payments are excluded)
      # +item_total+         The total value of all LineItems
      # +adjustment_total+   The total value of all adjustments (promotions, credits, etc.)
      # +total+              The so-called "order total."  This is equivalent to +item_total+ plus +adjustment_total+.
      def update_totals
        # update_adjustments
        self.payment_total = payments.completed.map(&:amount).sum
        self.item_total = line_items.map(&:amount).sum
        self.adjustment_total = adjustments.eligible.map(&:amount).sum
        self.total = item_total + adjustment_total
      end

      # Updates each of the Order adjustments.  This is intended to be called from an Observer so that the Order can
      # respond to external changes to LineItem, Shipment, other Adjustments, etc.
      # Adjustments will check if they are still eligible. Ineligible adjustments are preserved but not counted
      # towards adjustment_total.
      def update_adjustments
        self.adjustments.reload.each { |adjustment| adjustment.update!(self) }
      end

      # Determine if email is required (we don't want validation errors before we hit the checkout)
      def require_email
        return true unless new_record? or state == 'cart'
      end

      def has_available_shipment
        return unless :address == state_name.to_sym
        return unless ship_address && ship_address.valid?
        errors.add(:base, :no_shipping_methods_available) if available_shipping_methods.empty?
      end

      def has_available_payment
        return unless :delivery == state_name.to_sym
        errors.add(:base, :no_payment_methods_available) if available_payment_methods.empty?
      end

      def after_cancel
        restock_items!

        #TODO: make_shipments_pending
        OrderMailer.cancel_email(self).deliver
      end

      def restock_items!
        line_items.each do |line_item|
          InventoryUnit.decrease(self, line_item.variant, line_item.quantity)
        end
      end

      def after_resume
        unstock_items!
      end

      def unstock_items!
        line_items.each do |line_item|
          InventoryUnit.increase(self, line_item.variant, line_item.quantity)
        end
      end

      def use_billing?
        @use_billing == true || @use_billing == "true" || @use_billing == "1"
      end
  end
end
