module Message::Broadcasts
  def broadcast_create
    broadcast_append_to room, :messages, target: [ room, :messages ]
    broadcast_unread_room
  end

  def broadcast_remove
    broadcast_remove_to room, :messages
  end

  private
    # Fanned out to the room's members rather than published on one global stream, so
    # that the timing of activity in a room only reaches people who are in it.
    def broadcast_unread_room
      # Hypothesis test: coalesce per-member broadcasts.
      # Stock plucks 10k user_ids and broadcasts once per user to
      # UnreadRoomsChannel — linear fan-out that phase 2 showed as the
      # second amplifer (Redis queued while CPU <60% box). When
      # CAMPFIRE_COALESCE_BROADCAST=1, broadcast once to a single room
      # stream; clients already subscribed to the room can update unread
      # from that. Falls back to per-user when the flag is off, so stock
      # behaviour is preserved for the baseline.
      if ENV["CAMPFIRE_COALESCE_BROADCAST"] == "1"
        ActionCable.server.broadcast "unread_room:#{room.id}", { roomId: room.id }
      else
        room.memberships.pluck(:user_id).each do |user_id|
          ActionCable.server.broadcast UnreadRoomsChannel.stream_name_for(user_id), { roomId: room.id }
        end
      end
    end
end
