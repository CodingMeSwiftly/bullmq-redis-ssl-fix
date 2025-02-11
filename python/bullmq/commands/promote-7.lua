--[[
  Promotes a job that is currently "delayed" to the "waiting" state
    Input:
      KEYS[1] 'delayed'
      KEYS[2] 'wait'
      KEYS[3] 'paused'
      KEYS[4] 'meta'
      KEYS[5] 'prioritized'
      KEYS[6] 'pc' priority counter
      KEYS[7] 'event stream'
      ARGV[1]  queue.toKey('')
      ARGV[2]  jobId
    Output:
       0 - OK
      -3 - Job not in delayed zset.
    Events:
      'waiting'
]]
local rcall = redis.call
local jobId = ARGV[2]
-- Includes
--[[
  Function to add job considering priority.
]]
-- Includes
--[[
  Function priority marker to wait if needed
  in order to wake up our workers and to respect priority
  order as much as possible
]]
local function addPriorityMarkerIfNeeded(waitKey)
  local waitLen = rcall("LLEN", waitKey)
  if waitLen == 0 then
    rcall("LPUSH", waitKey, "0:0")
  end
end
local function addJobWithPriority(waitKey, prioritizedKey, priority, paused, jobId, priorityCounterKey)
  local prioCounter = rcall("INCR", priorityCounterKey)
  local score = priority * 0x100000000 + bit.band(prioCounter, 0xffffffffffff)
  rcall("ZADD", prioritizedKey, score, jobId)
  if not paused then
    addPriorityMarkerIfNeeded(waitKey)
  end
end
--[[
  Function to check for the meta.paused key to decide if we are paused or not
  (since an empty list and !EXISTS are not really the same).
]]
local function getTargetQueueList(queueMetaKey, waitKey, pausedKey)
  if rcall("HEXISTS", queueMetaKey, "paused") ~= 1 then
    return waitKey, false
  else
    return pausedKey, true
  end
end
if rcall("ZREM", KEYS[1], jobId) == 1 then
  local jobKey = ARGV[1] .. jobId
  local priority = tonumber(rcall("HGET", jobKey, "priority")) or 0
  local target, paused = getTargetQueueList(KEYS[4], KEYS[2], KEYS[3])
  -- Remove delayed "marker" from the wait list if there is any.
  -- Since we are adding a job we do not need the marker anymore.
  local marker = rcall("LINDEX", target, 0)
  if marker and string.sub(marker, 1, 2) == "0:" then
    rcall("LPOP", target)
  end
  if priority == 0 then
    -- LIFO or FIFO
    rcall("LPUSH", target, jobId)
  else
    addJobWithPriority(KEYS[2], KEYS[5], priority, paused, jobId, KEYS[6])
  end
  -- Emit waiting event (wait..ing@token)
  rcall("XADD", KEYS[7], "*", "event", "waiting", "jobId", jobId, "prev", "delayed");
  rcall("HSET", jobKey, "delay", 0)
  return 0
else
  return -3
end