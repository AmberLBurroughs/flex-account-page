require 'business_time'
require 'faraday'
require 'json'
require 'pry'
require 'sinatra'
require 'sinatra/base'
require 'sinatra/cross_origin'


SHOPIFY_API_KEY   = ''
SHOPIFY_PASSWORD  = ''
SHOPIFY_SHOP_NAME = 'the-flex-company'
# SharedSecret
SHOPIFY_BASE_URL  = "https://#{SHOPIFY_API_KEY}:#{SHOPIFY_PASSWORD}@#{SHOPIFY_SHOP_NAME}.myshopify.com"

RECHARGE_API_KEY  = ''
RECHARGE_BASE_URL = 'https://api.rechargeapps.com'

register Sinatra::CrossOrigin

get '/' do
  redirect 'https://flexfits.com/'
end

get '/customer_subscription' do
  cross_origin :allow_origin => 'https://flexfits.com'
  content_type :json

  # grab get parameters
  customer_email = request['customer_email']
  customer_id = request['customer_id']

  customer_data = get_shopify_user(customer_id, customer_email)
  if params.length === 0 || !customer_data['match']
    redirect 'https://flexfits.com/'
  end

  # use parameters to query shopify api for customer
  customer = customer_data['customer']

  if customer['tags'].include?('Active Subscriber')
    last_order = last_shopify_subscription(customer)
    return { show_header: false, show_calendar: false}.to_json if last_order.nil?

    is_first_sub = last_order['tags'].include?('Subscription First Order')

    order_titles = last_order['line_items'].map{ |li| li['title']}
    is_8pack = order_titles.any? { |ot| ot.include?('8 Pack')}

    # query recharge api for next charge date
    recharge_data = get_recharge_data(customer['id'])
    return { show_header: false, show_calendar: false}.to_json if recharge_data.length > 1

    # if 8 pck first order get order creation date. get shipping line titles add 7 or 4 calendar days.
    if(is_first_sub)
      header_date = calculate_delivery(last_order, first_order=is_first_sub)
    else
      header_date = calculate_delivery(recharge_data, first_order=is_first_sub)
    end

    next_scheduled_date = Date.strptime(recharge_data[0]['next_charge_scheduled_at'])
    calendar_date = 5.business_days.after(next_scheduled_date).to_time.to_i * 1000
    subscription_id = recharge_data[0]['id']
    return { subscription_id: subscription_id, header_date: header_date, show_header: true, calendar_date: calendar_date, show_calendar: is_8pack && is_first_sub }.to_json
  end

  # tell shopify calendar modal to not show anything
  return { show_header: false, show_calendar: false}.to_json
  # return customer tags, last order from shopify, order tags, next charge date for most current order from recharge, subscription type
end

post '/update_subscription' do
  cross_origin :allow_origin => 'https://flexfits.com'
  content_type :json

  # grab get parameters
  customer_email = request['customer_email']
  customer_id = request['customer_id']
  next_subscription_time = request['subscription_time'].to_i
  subscription_id = request['subscription_id']

  customer_data = get_shopify_user(customer_id, customer_email)
  if params.length === 0 || !customer_data['match']
    redirect 'https://flexfits.com/'
  end

  customer_id = customer_data['customer']['id']
  updated_sub = update_recharge_subscription(customer_id, subscription_id, next_subscription_time)
  return {success: true}.to_json if updated_sub

  return {success: false}.to_json
end

# create new faraday connection
def shopify_connection
  Faraday.new(url: SHOPIFY_BASE_URL, ssl: { verify: false }) do |faraday|
    faraday.request  :url_encoded             # form-encode POST params
    faraday.adapter  Faraday.default_adapter  # make requests with Net::https
  end
end

def recharge_connection
  Faraday.new(url: RECHARGE_BASE_URL, ssl: { verify: false }) do |faraday|
    faraday.request  :url_encoded             # form-encode POST params
    faraday.adapter  Faraday.default_adapter  # make requests with Net::https
  end
end

# check if the customers tags include Active Subscriber
def is_active_subscriber(customer_id)
  conn = http_connection()
  is_active = false
  response = conn.get do |req|
    req.url "/admin/customers/#{customer_id}.json"
  end
  customer = JSON.parse(response.body)['customer']
  if customer['tags'].include?('Active Subscriber')
   is_active = true
  end
  return is_active
end

# hacky security goes here: for a given customer ID
# and user email, check that the email is actually associated
# with this customer ID.
# (only the user should know this!)
def get_shopify_user(customer_id, email)
  conn = shopify_connection()

  response = conn.get do |req|
    req.url "/admin/customers/#{customer_id}.json"
  end
  customer = JSON.parse(response.body)['customer']
  customer_match = customer.nil? ? false : customer['email'] == email
  { 'customer' => customer, 'match' => customer_match }
end

def last_shopify_subscription(customer_json)
  conn = shopify_connection()

  response = conn.get do |req|
    req.url "/admin/orders.json"
    req.params = {'customer_id': customer_json['id'], 'status': 'any'}
  end

  orders_json = JSON.parse(response.body)['orders']
  orders_json.each do |order|
    return order if order['tags'].include?('Subscription') && order['status'] != 'cancelled'
  end

  return nil
end

def get_recharge_data(shopify_customer_id)
  conn = recharge_connection()

  subscription_response = conn.get do |req|
    req.url "/subscriptions"
    req.headers['X-Recharge-Access-Token'] = RECHARGE_API_KEY
    req.params = { 'shopify_customer_id': shopify_customer_id }
  end

  subscriptions = JSON.parse(subscription_response.body)['subscriptions']
end


def calculate_delivery(order, first_order=true)
  if first_order
    order_date = Date.strptime(order['created_at'])
    shipping_title = order['shipping_lines'][0]['title']

    if shipping_title.include?('1-2') || shipping_title.downcase.include?('rush')
      return 2.business_days.after(order_date).to_time.to_i * 1000
    else
      return 5.business_days.after(order_date).to_time.to_i * 1000
    end
  else
    order_date = Date.strptime(order['next_charge_scheduled_at'])
    return 5.business_days.after(order_date).to_time.to_i * 1000
  end
end

def update_recharge_subscription(customer_id, subscription_id, next_subscription_time)
  # time from flex page will be in milliseconds, so convert to seconds before converting to Time obj
  next_sub_delivery = Time.at(next_subscription_time/1000).to_datetime
  next_subscription = 3.business_days.before(next_sub_delivery)
  conn = recharge_connection()

  response = conn.post do |req|
    req.url "/subscriptions/#{subscription_id}/set_next_charge_date"
    req.headers['X-Recharge-Access-Token'] = RECHARGE_API_KEY
    req.headers['Accept'] = 'application/json'
    req.headers['Content-Type'] = 'application/json'
    req.body = { 'date': next_subscription.strftime[0..10] + "00:00:00" }.to_json
  end

  response.success?
end
