local queue = require "util.queue";
local uuid_gen = require "util.uuid".generate;
local main_util = module:require "util";
local ends_with = main_util.ends_with;
local is_healthcheck_room = main_util.is_healthcheck_room;

local QUEUE_MAX_SIZE = 100;

-- Module that generates a unique meetingId, attaches it to the room
-- and adds it to all disco info form data (when room is queried or in the
-- initial room owner config)

-- Hook to assign meetingId for new rooms
module:hook("muc-room-created", function(event)
    local room = event.room;

    if is_healthcheck_room(room.jid) then
        return;
    end

    room._data.meetingId = uuid_gen();

    module:log("debug", "Created meetingId:%s for %s",
        room._data.meetingId, room.jid);
end);

-- Returns the meeting config Id form data.
function getMeetingIdConfig(room)
    return {
        name = "muc#roominfo_meetingId";
        type = "text-single";
        label = "The meeting unique id.";
        value = room._data.meetingId or "";
    };
end

-- add meeting Id to the disco info requests to the room
module:hook("muc-disco#info", function(event)
    table.insert(event.form, getMeetingIdConfig(event.room));
end);

-- add the meeting Id in the default config we return to jicofo
module:hook("muc-config-form", function(event)
    table.insert(event.form, getMeetingIdConfig(event.room));
end, 90-3);

-- disabled few options for room config, to not mess with visitor logic
module:hook("muc-config-submitted/muc#roomconfig_moderatedroom", function()
    return true;
end, 99);
module:hook("muc-config-submitted/muc#roomconfig_presencebroadcast", function()
    return true;
end, 99);

--- Avoids any participant joining the room in the interval between creating the room
--- and jicofo entering the room
module:hook('muc-occupant-pre-join', function (event)
    local room, stanza = event.room, event.stanza;

    -- we skip processing only if jicofo_lock is set to false
    if room.jicofo_lock == false or is_healthcheck_room(stanza.attr.from) then
        return;
    end

    local occupant = event.occupant;
    if ends_with(occupant.nick, '/focus') then
        module:fire_event('jicofo-unlock-room', { room = room; });
    else
        room.jicofo_lock = true;
        if not room.pre_join_queue then
            room.pre_join_queue = queue.new(QUEUE_MAX_SIZE);
        end

        if not room.pre_join_queue:push(event) then
            module:log('error', 'Error enqueuing occupant event for: %s', occupant.nick);
            return true;
        end
        module:log('info', 'Occupant pushed to prejoin queue %s', occupant.nick);

        -- stop processing
        return true;
    end
end, 8); -- just after the rate limit

function handle_jicofo_unlock(event)
    local room = event.room;

    room.jicofo_lock = false;
    if not room.pre_join_queue then
        return;
    end

    -- and now let's handle all pre_join_queue events
    for _, ev in room.pre_join_queue:items() do
        module:log('info', 'Occupant processed from queue %s', ev.occupant.nick);
        room:handle_normal_presence(ev.origin, ev.stanza);
    end
    room.pre_join_queue = nil;
end

module:hook('jicofo-unlock-room', handle_jicofo_unlock);

-- make sure we remove nick if someone is sending it with a message to protect
-- forgery of display name
module:hook("muc-occupant-groupchat", function(event)
    event.stanza:remove_children('nick', 'http://jabber.org/protocol/nick');
end, 45); -- prosody check is prio 50, we want to run after it
