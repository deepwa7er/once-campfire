class Room < ApplicationRecord
  has_many :memberships, dependent: :delete_all do
    def grant_to(users)
      room = proxy_association.owner
      Membership.insert_all(Array(users).collect { |user| { room_id: room.id, user_id: user.id, involvement: room.default_involvement } })
    end

    def revoke_from(users)
      destroy_by user: users
    end

    def revise(granted: [], revoked: [])
      transaction do
        grant_to(granted) if granted.present?
        revoke_from(revoked) if revoked.present?
      end
    end
  end

  has_many :users, through: :memberships
  has_many :messages, dependent: :destroy

  belongs_to :creator, class_name: "User", default: -> { Current.user }

  validate :direct_rooms_keep_their_type, on: :update

  scope :opens,           -> { where(type: "Rooms::Open") }
  scope :closeds,         -> { where(type: "Rooms::Closed") }
  scope :directs,         -> { where(type: "Rooms::Direct") }
  scope :without_directs, -> { where.not(type: "Rooms::Direct") }

  scope :ordered, -> { order("LOWER(name)") }

  class << self
    def create_for(attributes, users:)
      transaction do
        create!(attributes).tap do |room|
          room.memberships.grant_to users
        end
      end
    end

    def original
      order(:created_at).first
    end
  end

  def receive(message)
    unread_memberships(message)
    push_later(message)
  end

  def open?
    is_a?(Rooms::Open)
  end

  def closed?
    is_a?(Rooms::Closed)
  end

  def direct?
    is_a?(Rooms::Direct)
  end

  def default_involvement
    "mentions"
  end

  private
    # Open and closed rooms convert into each other freely. A direct room can't become
    # either: its participants agreed to a private conversation, not to one whose
    # audience someone else gets to widen afterwards.
    def direct_rooms_keep_their_type
      if type_changed? && type_was == "Rooms::Direct"
        errors.add :type, "can't be changed for a direct room"
      end
    end

    def unread_memberships(message)
      # Hypothesis test branch: coalesce the per-message 10k-row UPDATE.
      # Stock does update_all(unread_at) across every membership row on every
      # post — quadratic cost that phase 1 showed as the knee (WAL pinned,
      # delivery 0.7s→23s while CPU <60% box). This branch keeps the same
      # semantics but batches: only mark unread if the row was already read
      # longer ago than the debounce window, reducing writes on hot rooms.
      # Full lazy-unread (single stream) would be the next step if this moves
      # the knee; this is the minimal reversible patch to test the queue.
      if ENV["CAMPFIRE_BATCH_UNREAD"] == "1"
        # Debounce: don't rewrite rows already marked unread within 5s.
        # Hot room with 5 posts/s still does ~1 write/5s/row instead of 5/s.
        memberships.visible.disconnected
          .where.not(user: message.creator)
          .where("unread_at IS NULL OR unread_at < ?", 5.seconds.ago)
          .update_all(unread_at: message.created_at, updated_at: Time.current)
      else
        memberships.visible.disconnected.where.not(user: message.creator).update_all(unread_at: message.created_at, updated_at: Time.current)
      end
    end

    def push_later(message)
      Room::PushMessageJob.perform_later(self, message)
    end
end
