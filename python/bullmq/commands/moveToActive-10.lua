--[[
  Move next job to be processed to active, lock it and fetch its data. The job
  may be delayed, in that case we need to move it to the delayed set instead.
  This operation guarantees that the worker owns the job during the lock
  expiration time. The worker is responsible of keeping the lock fresh
  so that no other worker picks this job again.
  Input:
    KEYS[1] wait key
    KEYS[2] active key
    KEYS[3] prioritized key
    KEYS[4] stream events key
    KEYS[5] stalled key
    -- Rate limiting
    KEYS[6] rate limiter key
    KEYS[7] delayed key
    -- Promote delayed jobs
    KEYS[8] paused key
    KEYS[9] meta key
    KEYS[10] pc priority counter
    -- Arguments
    ARGV[1] key prefix
    ARGV[2] timestamp
    ARGV[3] optional job ID
    ARGV[4] opts
    opts - token - lock token
    opts - lockDuration
    opts - limiter
]]
local rcall = redis.call
local waitKey = KEYS[1]
local activeKey = KEYS[2]
local rateLimiterKey = KEYS[6]
local delayedKey = KEYS[7]
local opts = cmsgpack.unpack(ARGV[4])
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
local function getRateLimitTTL(maxJobs, rateLimiterKey)
  if maxJobs and maxJobs <= tonumber(rcall("GET", rateLimiterKey) or 0) then
    local pttl = rcall("PTTL", rateLimiterKey)
    if pttl == 0 then
      rcall("DEL", rateLimiterKey)
    end
    if pttl > 0 then
      return pttl
    end
  end
  return 0
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
  Function to move job from prioritized state to active.
]]
local function moveJobFromPriorityToActive(priorityKey, activeKey, priorityCounterKey)
  local prioritizedJob = rcall("ZPOPMIN", priorityKey)
  if #prioritizedJob > 0 then
    rcall("LPUSH", activeKey, prioritizedJob[1])
    return prioritizedJob[1]
  else
    rcall("DEL", priorityCounterKey)
  end
end
--[[
  Function to move job from wait state to active.
  Input:
    keys[1] wait key
    keys[2] active key
    keys[3] prioritized key
    keys[4] stream events key
    keys[5] stalled key
    -- Rate limiting
    keys[6] rate limiter key
    keys[7] delayed key
    keys[8] paused key
    keys[9] meta key
    keys[10] pc priority counter
    opts - token - lock token
    opts - lockDuration
    opts - limiter
]]
-- Includes
--[[
  Function to push back job considering priority in front of same prioritized jobs.
]]
local function pushBackJobWithPriority(prioritizedKey, priority, jobId)
  -- in order to put it at front of same prioritized jobs
  -- we consider prioritized counter as 0
  local score = priority * 0x100000000
  rcall("ZADD", prioritizedKey, score, jobId)
end
local function prepareJobForProcessing(keys, keyPrefix, targetKey, jobId, processedOn,
    maxJobs, expireTime, opts)
  local jobKey = keyPrefix .. jobId
  -- Check if we need to perform rate limiting.
  if maxJobs then
    local rateLimiterKey = keys[6];
    -- check if we exceeded rate limit, we need to remove the job and return expireTime
    if expireTime > 0 then
      -- remove from active queue and add back to the wait list
      rcall("LREM", keys[2], 1, jobId)
      local priority = tonumber(rcall("HGET", jobKey, "priority")) or 0
      if priority == 0 then
        rcall("RPUSH", targetKey, jobId)
      else
        pushBackJobWithPriority(keys[3], priority, jobId)
      end
      -- Return when we can process more jobs
      return {0, 0, expireTime, 0}
    end
    local jobCounter = tonumber(rcall("INCR", rateLimiterKey))
    if jobCounter == 1 then
      local limiterDuration = opts['limiter'] and opts['limiter']['duration']
      local integerDuration = math.floor(math.abs(limiterDuration))
      rcall("PEXPIRE", rateLimiterKey, integerDuration)
    end
  end
  local lockKey = jobKey .. ':lock'
  -- get a lock
  if opts['token'] ~= "0" then
    rcall("SET", lockKey, opts['token'], "PX", opts['lockDuration'])
  end
  rcall("XADD", keys[4], "*", "event", "active", "jobId", jobId, "prev", "waiting")
  rcall("HSET", jobKey, "processedOn", processedOn)
  rcall("HINCRBY", jobKey, "attemptsMade", 1)
  return {rcall("HGETALL", jobKey), jobId, 0, 0} -- get job data
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
local target, paused = getTargetQueueList(KEYS[9], waitKey, KEYS[8])
-- Check if there are delayed jobs that we can move to wait.
promoteDelayedJobs(delayedKey, waitKey, target, KEYS[3], KEYS[4], ARGV[1],
                   ARGV[2], paused, KEYS[10])
local maxJobs = tonumber(opts['limiter'] and opts['limiter']['max'])
local expireTime = getRateLimitTTL(maxJobs, rateLimiterKey)
local jobId = nil
if ARGV[3] ~= "" then
    jobId = ARGV[3]
    -- clean stalled key
    rcall("SREM", KEYS[5], jobId)
end
if not jobId or (jobId and string.sub(jobId, 1, 2) == "0:") then
    -- If jobId is special ID 0:delay, then there is no job to process
    if jobId then rcall("LREM", activeKey, 1, jobId) end
    -- Check if we are rate limited first.
    if expireTime > 0 then return {0, 0, expireTime, 0} end
    -- paused queue
    if paused then return {0, 0, 0, 0} end
    -- no job ID, try non-blocking move from wait to active
    jobId = rcall("RPOPLPUSH", waitKey, activeKey)
    -- Since it is possible that between a call to BRPOPLPUSH and moveToActive
    -- another script puts a new maker in wait, we need to check again.
    if jobId and string.sub(jobId, 1, 2) == "0:" then
        rcall("LREM", activeKey, 1, jobId)
        jobId = rcall("RPOPLPUSH", waitKey, activeKey)
    end
end
if jobId then
    return prepareJobForProcessing(KEYS, ARGV[1], target, jobId, ARGV[2],
                                   maxJobs, expireTime, opts)
else
    jobId = moveJobFromPriorityToActive(KEYS[3], activeKey, KEYS[10])
    if jobId then
        return prepareJobForProcessing(KEYS, ARGV[1], target, jobId, ARGV[2],
                                       maxJobs, expireTime, opts)
    end
end
-- Return the timestamp for the next delayed job if any.
local nextTimestamp = getNextDelayedTimestamp(delayedKey)
if (nextTimestamp ~= nil) then return {0, 0, 0, nextTimestamp} end
return {0, 0, 0, 0}
