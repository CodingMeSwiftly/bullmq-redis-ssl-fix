--[[
  Retries a failed job by moving it back to the wait queue.
    Input:
      KEYS[1] 'active',
      KEYS[2] 'wait'
      KEYS[3] 'paused'
      KEYS[4] job key
      KEYS[5] 'meta'
      KEYS[6] events stream
      KEYS[7] delayed key
      KEYS[8] prioritized key
      KEYS[9] 'pc' priority counter
      ARGV[1]  key prefix
      ARGV[2]  timestamp
      ARGV[3]  pushCmd
      ARGV[4]  jobId
      ARGV[5]  token
    Events:
      'waiting'
    Output:
     0  - OK
     -1 - Missing key
     -2 - Missing lock
]]
local rcall = redis.call
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
--[[
  Updates the delay set, by moving delayed jobs that should
  be processed now to "wait".
     Events:
      'waiting'
]]
-- Includes
-- Try to get as much as 1000 jobs at once
local function promoteDelayedJobs(delayedKey, waitKey, targetKey, prioritizedKey,
                                  eventStreamKey, prefix, timestamp, paused, priorityCounterKey)
    local jobs = rcall("ZRANGEBYSCORE", delayedKey, 0, (timestamp + 1) * 0x1000, "LIMIT", 0, 1000)
    if (#jobs > 0) then
        rcall("ZREM", delayedKey, unpack(jobs))
        for _, jobId in ipairs(jobs) do
            local jobKey = prefix .. jobId
            local priority =
                tonumber(rcall("HGET", jobKey, "priority")) or 0
            if priority == 0 then
                -- LIFO or FIFO
                rcall("LPUSH", targetKey, jobId)
            else
                addJobWithPriority(waitKey, prioritizedKey, priority, paused,
                  jobId, priorityCounterKey)
            end
            -- Emit waiting event
            rcall("XADD", eventStreamKey, "*", "event", "waiting", "jobId",
                  jobId, "prev", "delayed")
            rcall("HSET", jobKey, "delay", 0)
        end
    end
end
local target, paused = getTargetQueueList(KEYS[5], KEYS[2], KEYS[3])
-- Check if there are delayed jobs that we can move to wait.
-- test example: when there are delayed jobs between retries
promoteDelayedJobs(KEYS[7], KEYS[2], target, KEYS[8], KEYS[6], ARGV[1], ARGV[2], paused, KEYS[9])
if rcall("EXISTS", KEYS[4]) == 1 then
  if ARGV[5] ~= "0" then
    local lockKey = KEYS[4] .. ':lock'
    if rcall("GET", lockKey) == ARGV[5] then
      rcall("DEL", lockKey)
    else
      return -2
    end
  end
  rcall("LREM", KEYS[1], 0, ARGV[4])
  local priority = tonumber(rcall("HGET", KEYS[4], "priority")) or 0
  -- Standard or priority add
  if priority == 0 then
    rcall(ARGV[3], target, ARGV[4])
  else
    addJobWithPriority(KEYS[2], KEYS[8], priority, paused, ARGV[4], KEYS[9])
  end
  local maxEvents = rcall("HGET", KEYS[5], "opts.maxLenEvents") or 10000
  -- Emit waiting event
  rcall("XADD", KEYS[6], "MAXLEN", "~", maxEvents, "*", "event", "waiting",
    "jobId", ARGV[4], "prev", "failed")
  return 0
else
  return -1
end
