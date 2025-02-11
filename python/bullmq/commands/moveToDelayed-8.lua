--[[
  Moves job from active to delayed set.
  Input:
    KEYS[1] wait key
    KEYS[2] active key
    KEYS[3] prioritized key
    KEYS[4] delayed key
    KEYS[5] job key
    KEYS[6] events stream
    KEYS[7] paused key
    KEYS[8] meta key
    ARGV[1] key prefix
    ARGV[2] timestamp
    ARGV[3] delayedTimestamp
    ARGV[4] the id of the job
    ARGV[5] queue token
  Output:
    0 - OK
   -1 - Missing job.
   -3 - Job not in active set.
  Events:
    - delayed key.
]]
local rcall = redis.call
-- Includes
--[[
  Add delay marker if needed.
]]
-- Includes
--[[
  Function to return the next delayed job timestamp.
]] 
local function getNextDelayedTimestamp(delayedKey)
  local result = rcall("ZRANGE", delayedKey, 0, 0, "WITHSCORES")
  if #result then
    local nextTimestamp = tonumber(result[2])
    if (nextTimestamp ~= nil) then 
      nextTimestamp = nextTimestamp / 0x1000
    end
    return nextTimestamp
  end
end
local function addDelayMarkerIfNeeded(targetKey, delayedKey)
  if rcall("LLEN", targetKey) == 0 then
    local nextTimestamp = getNextDelayedTimestamp(delayedKey)
    if nextTimestamp ~= nil then
      rcall("LPUSH", targetKey, "0:" .. nextTimestamp)
    end
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
local jobKey = KEYS[5]
if rcall("EXISTS", jobKey) == 1 then
  local delayedKey = KEYS[4]
  if ARGV[5] ~= "0" then
    local lockKey = jobKey .. ':lock'
    if rcall("GET", lockKey) == ARGV[5] then
      rcall("DEL", lockKey)
    else
      return -2
    end
  end
  local jobId = ARGV[4]
  local score = tonumber(ARGV[3])
  local delayedTimestamp = (score / 0x1000)
  local numRemovedElements = rcall("LREM", KEYS[2], -1, jobId)
  if numRemovedElements < 1 then
    return -3
  end
  local maxEvents = rcall("HGET", KEYS[8], "opts.maxLenEvents") or 10000
  rcall("ZADD", delayedKey, score, jobId)
  rcall("XADD", KEYS[6], "MAXLEN", "~", maxEvents, "*", "event", "delayed",
    "jobId", jobId, "delay", delayedTimestamp)
  -- Check if we need to push a marker job to wake up sleeping workers.
  local target = getTargetQueueList(KEYS[8], KEYS[1], KEYS[7])
  addDelayMarkerIfNeeded(target, delayedKey)
  return 0
else
  return -1
end
