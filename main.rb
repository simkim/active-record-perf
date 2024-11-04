# frozen_string_literal: true
require 'bundler/inline'

gemfile(true) do
  source 'https://rubygems.org'

  gem 'activerecord', '~> 7'
  gem 'pg'
  gem 'pry'
end

require "active_record"


$compute_timing = false
$eager_loading = false

ActiveRecord::Base.establish_connection(
  adapter: 'postgresql',
  host: 'localhost',
  database: 'test'
)

class SimpleFormatter < ::Logger::Formatter
  def call(severity, timestamp, progname, msg)
    msg.to_s+"\n"
  end
end
formatter = SimpleFormatter.new

if !$compute_timing
  ActiveRecord::Base.logger = Logger.new(STDOUT)
  ActiveRecord::Base.logger.formatter = formatter
end

$logger = Logger.new(STDOUT)
$logger.formatter = formatter

# drop tables
ActiveRecord::Base.connection.tables.each do |table|
  ActiveRecord::Base.connection.drop_table(table)
end

ActiveRecord::Schema.define do

  create_table :users, force: true do |t|
    t.string :name
  end

  create_table :posts, force: true do |t|
    t.integer :view_count
    t.references :user
  end

  create_table :images, force: true do |t|
    t.references :illustrable, polymorphic: true
  end

  create_table :post_views, force: true do |t|
    t.references :post
    t.references :user
    t.integer :view_count, default: 0, null: false
    t.index [:post_id, :user_id], unique: true
  end

  create_table :comments, force: true do |t|
    t.string  :type
    t.references :post
    t.references :video
  end

  create_table :videos, force: true do |t|
  end
end

class User < ActiveRecord::Base
  has_many :posts
  has_many :post_views
end

class Post < ActiveRecord::Base
  belongs_to :user
  has_many :post_views

  has_many :comments
  has_many :images, as: :illustrable
end

class PostView < ActiveRecord::Base
  belongs_to :post
  belongs_to :user
end

class Comment < ActiveRecord::Base
  belongs_to :post
  has_many :images, as: :illustrable
end

class Video < ActiveRecord::Base
  has_many :comments
end

class VideoComment < Comment
  belongs_to :video
end

class TextComment < Comment
end

class Image < ActiveRecord::Base
  belongs_to :illustrable, polymorphic: true
end

def test(title)
  start = Time.now
  $logger.info "--- #{title} ---"
  yield
rescue => e
  $logger.error "#{e.class}: #{e}"
ensure
  $logger.info "--- end --- (#{
    ((Time.now - start) * 1000).to_i
  }ms)\n"
end

user = User.create!(name: 'John Doe')
if $compute_timing
  1000.times do 
    post = user.posts.create!
    Image.create!(illustrable: post)
  end
end
post1 = user.posts.create!
post2 = user.posts.create!
post3 = user.posts.create!

test 'direct - naive' do
  post1.view_count += 1
  post1.save!
end

test 'indirect - naive' do
  post_view = post1.post_views.find_or_initialize_by(user: user)
  post_view.view_count += 1
  post_view.save!
end

test 'direct - AR increment!' do
  post2.increment!(:view_count)
end

test 'indirect - AR increment!' do
  post_view = post2.post_views.find_or_create_by(user: user)
  post_view.increment!(:view_count)
end

test 'direct - raw' do
  Post.connection.execute(
    "UPDATE posts SET view_count = view_count + 1 WHERE id = #{post3.id}"
  )
end

test 'indirect - raw' do
  PostView.connection.execute(
    "insert into post_views (post_id, user_id, view_count) 
      values (#{post3.id}, #{user.id}, 1) 
      on conflict (post_id, user_id) do 
      update set view_count = post_views.view_count + 1")
end

test "find_by" do
  post = Post.find_by(user: user)
  post.user # Provoque un chargement de l'association
end

test "create through association" do
  post = user.posts.build
  post.user # OK
end

comment = Comment.create!(post: post1)
video_comment = VideoComment.create!(post: post1, video: Video.create!)
text_comment = TextComment.create!(post: post1)
video_comment2 = VideoComment.create!(post: post2, video: Video.create!)
text_comment2 = TextComment.create!(post: post2)
image1 = Image.create!(illustrable: post1)
image2 = Image.create!(illustrable: post2)
image3 = Image.create!(illustrable: comment)

$logger.info "\n=== polymorphism ===\n"

test "includes with polymorphic" do
  Image.includes(:illustrable).to_a
end

test "sub-includes with polymorphism" do
  Image.includes(illustrable: :comments).to_a
end

if $eager_loading
  test "eager_load with polymorphic" do
    Image.eager_load(:illustrable).to_a
  end

  test "sub-eager_load with polymorphism" do
    Image.eager_load(illustrable: :comments).to_a
  end
end

$logger.info "\n=== STI ===\n"

test "includes with STI" do
  Post.includes(:comments).to_a
end

test "sub-includes with STI" do
  Post.includes(comments: :video).to_a
end

test "preloader with STI" do
  posts = Post.includes(:comments).to_a
  ActiveRecord::Associations::Preloader.new(
    records: posts.flat_map { |post| post.comments.select { |c| c.is_a?(VideoComment) } },
    associations: :video
  ).call
end

if $eager_loading
  test "eager_load with STI" do
    Post.eager_load(:comments).to_a
  end

  test "sub-eager_load with STI" do
    Post.eager_load(comments: :video).to_a
  end
end